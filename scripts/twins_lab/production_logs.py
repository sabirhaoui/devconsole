"""Local background collector for production Compose logs (stdlib only)."""
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone

from database_sync import connection, quote_command, remote_compose


class ArchiveHandler(RotatingFileHandler):
    """With backups=0, keep every completed segment for downstream consumers."""
    def doRollover(self):
        if self.backupCount:
            return super().doRollover()
        if self.stream:
            self.stream.close()
            self.stream = None
        source = Path(self.baseFilename)
        source.rename(source.with_name(f"events.{time.time_ns()}.jsonl"))
        self.stream = self._open()


def now():
    return datetime.now(timezone.utc).isoformat()


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)


def read_state(directory):
    try:
        return json.loads((directory / "status.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def pid_is_running(pid):
    """Check process existence without sending a signal on Windows."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.GetExitCodeProcess.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False if ctypes.get_last_error() == 87 else None
        try:
            code = wintypes.DWORD()
            if not kernel.GetExitCodeProcess(handle, ctypes.byref(code)):
                return None
            return code.value == 259  # STILL_ACTIVE
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return None


def collector_status(directory, locked):
    state = read_state(directory)
    state.update(pid_running=pid_is_running(state.get("pid")),
                 running=locked, directory=str(directory))
    if not locked:
        state["recorded_status"] = state.get("status")
        state["status"] = "stopped"
    # The lock identifies the collector; an existing PID alone may have been reused.
    state["collector_verified"] = locked and state["pid_running"] is True
    return state


def lock(directory):
    handle = (directory / "collector.lock").open("a+b")
    handle.seek(0)
    if os.name == "nt":
        import msvcrt
        try:
            if os.fstat(handle.fileno()).st_size == 0:
                handle.write(b"0")
                handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            handle.close()
            return None
    else:
        import fcntl
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            handle.close()
            return None
    return handle


def ssh_command(remote, settings, services, since, tail):
    command = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
               "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
               "-p", str(int(remote.get("port", 22)))]
    if remote.get("ssh_key"):
        command += ["-i", os.path.expanduser(remote["ssh_key"])]
    logs = remote_compose(settings) + ["logs", "--follow", "--no-color", "--timestamps"]
    logs += ["--since", since] if since else ["--tail", str(tail)]
    logs += services
    return command + [f"{remote['user']}@{remote['host']}", quote_command(logs)]


def record(line, remote, target):
    service, separator, message = line.rstrip("\r\n").partition("|")
    if not separator:
        message, service = service, None
    else:
        service = service.strip()
    match = re.match(r"\s*(\d{4}-\d\d-\d\dT\S+)\s(.*)", message)
    timestamp = match[1] if match else None
    return {"schema_version": 1, "received_at": now(), "timestamp": timestamp,
            "target": target or "default", "host": remote["host"],
            "service": service, "message": match[2] if match else message,
            "raw": line.rstrip("\r\n")}


def resume_since(timestamp):
    # Docker timestamps have nanoseconds; datetime needs only microseconds.
    timestamp = re.sub(r"(\.\d{6})\d+", r"\1", timestamp)
    return (datetime.fromisoformat(timestamp.replace("Z", "+00:00")) - timedelta(seconds=5)).isoformat()


def reader(stream, output, stopped):
    try:
        for line in stream:
            while not stopped.is_set():
                try:
                    output.put(line, timeout=1)
                    break
                except queue.Full:
                    pass
            if stopped.is_set():
                break
    finally:
        while not stopped.is_set():
            try:
                output.put(None, timeout=1)
                break
            except queue.Full:
                pass


def collect(args, cfg, directory):
    remote = connection(cfg.get("ubuntu", {}), args.target)
    settings = {**remote.get("database_sync", {}), **remote.get("production_logs", {})}
    for service in args.services:
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", service):
            raise ValueError(f"Service invalide : {service}")
    handler = ArchiveHandler(directory / "events.jsonl", maxBytes=args.max_mb * 1024 * 1024,
                                  backupCount=args.backups, encoding="utf-8")
    logger = logging.getLogger("production_logs")
    logger.setLevel(logging.INFO)
    logger.propagate = False
    logger.addHandler(handler)
    state = read_state(directory)
    cursor = state.get("cursor")
    state = {"pid": os.getpid(), "target": args.target, "host": remote["host"],
             "services": args.services, "started_at": now(), "cursor": cursor}
    process = None
    def update(status, **values):
        state.update(status=status, updated_at=now(), cursor=cursor, **values)
        save(directory / "status.json", state)
    try:
        while not (directory / "stop").exists():
            update("connecting")
            try:
                with (directory / "ssh.log").open("ab") as errors:
                    process = subprocess.Popen(
                        ssh_command(remote, settings, args.services,
                                    resume_since(cursor) if cursor else None, args.tail),
                        stdout=subprocess.PIPE, stderr=errors, text=True, encoding="utf-8", errors="replace",
                        **({"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}))
                    output = queue.Queue(maxsize=10000)
                    stopped = threading.Event()
                    worker = threading.Thread(target=reader, args=(process.stdout, output, stopped), daemon=True)
                    worker.start()
                    update("streaming")
                    heartbeat = time.monotonic()
                    while not (directory / "stop").exists():
                        try:
                            line = output.get(timeout=1)
                        except queue.Empty:
                            line = ""
                        if line is None:
                            break
                        if line:
                            event = record(line, remote, args.target)
                            logger.info(json.dumps(event, ensure_ascii=False))
                            if event["timestamp"]:
                                try:
                                    resume_since(event["timestamp"])
                                    if not cursor or event["timestamp"] > cursor:
                                        cursor = event["timestamp"]
                                except ValueError:
                                    pass
                        if time.monotonic() - heartbeat > 5:
                            update("streaming")
                            heartbeat = time.monotonic()
                    stopped.set()
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                    worker.join(timeout=5)
                    process.stdout.close()
                    update("reconnecting", last_exit_code=process.returncode)
            except (OSError, subprocess.SubprocessError) as error:
                update("reconnecting", error=str(error))
            for _ in range(5):
                if (directory / "stop").exists():
                    break
                time.sleep(1)
    finally:
        if process and process.poll() is None:
            process.kill()
            process.wait()
        update("stopped")
        logger.removeHandler(handler)
        handler.close()


def production_logs(args, cfg, lab):
    name = args.target or "default"
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", name) or name in (".", ".."):
        raise SystemExit("Nom de cible invalide")
    output = Path(args.output).expanduser().resolve() if args.output else lab.parents[1].parent / "logs" / "project_twins"
    directory = output / name
    directory.mkdir(parents=True, exist_ok=True)
    guard = lock(directory)
    if args.production_action == "status":
        try:
            print(json.dumps(collector_status(directory, guard is None), ensure_ascii=False, indent=2))
        finally:
            if guard:
                guard.close()
        return
    if args.production_action == "stop":
        if guard:
            guard.close()
            print("Collecteur déjà arrêté.")
            return
        (directory / "stop").touch()
        for _ in range(30):
            time.sleep(0.5)
            guard = lock(directory)
            if guard:
                guard.close()
                print("Collecteur arrêté.")
                return
        raise SystemExit("Arrêt demandé ; vérifier le status dans quelques secondes.")
    if not guard:
        if args.production_action == "run":
            raise SystemExit("Collecteur déjà actif.")
        print("Collecteur déjà actif.")
        return
    try:
        connection(cfg.get("ubuntu", {}), args.target)
        (directory / "stop").unlink(missing_ok=True)
        if args.production_action == "run":
            collect(args, cfg, directory)
            return
        command = [sys.executable, str(lab / "lab.py"), "project_twin", "trail", "production", "run",
                   "--output", str(output), "--tail", str(args.tail),
                   "--max-mb", str(args.max_mb), "--backups", str(args.backups)]
        if args.target:
            command += ["--target", args.target]
        if args.services:
            command += ["--services", *args.services]
        guard.close()
        guard = None
        launched_at = now()
        with (directory / "collector.log").open("ab") as output:
            options = {"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output, stderr=output, **options)
        for _ in range(40):
            time.sleep(0.25)
            if process.poll() is not None:
                raise SystemExit(f"Le collecteur n’a pas démarré : consulter {directory / 'collector.log'}")
            state = read_state(directory)
            # Windows venv launchers may spawn Python with a different PID.
            if state.get("started_at", "") >= launched_at and state.get("status") != "stopped":
                print(f"Collecteur démarré (PID {state['pid']}). Logs : {directory / 'events.jsonl'}")
                return
        raise SystemExit(f"Démarrage en attente ; consulter le status et {directory / 'collector.log'}")
    except (OSError, ValueError) as error:
        raise SystemExit(f"Échec collecte production : {error}") from error
    finally:
        if guard:
            guard.close()
