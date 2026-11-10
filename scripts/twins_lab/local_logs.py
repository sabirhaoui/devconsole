"""Collect local Compose and Angular output in the shared JSONL format."""
import json
import logging
import subprocess

from production_logs import ArchiveHandler, collect_stream, manage_collector, now
from project_run import compose_command


def local_directory(lab, engine):
    return lab.parents[1].parent / "logs" / "project_twins" / "local" / engine


def local_logs(args, root, lab):
    root = root.resolve()
    directory = local_directory(lab, args.engine)

    def command(since):
        logs = compose_command(root, args.engine) + ["logs", "--follow", "--no-color", "--timestamps"]
        logs += ["--since", since] if since else ["--tail", str(args.tail)]
        return logs + args.services

    def run():
        collect_stream(args, directory, {"host": "localhost"}, "local", command,
                       "compose.log", project=str(root))

    manage_collector(args, lab, directory, "local", ["--engine", args.engine], run,
                     lambda: compose_command(root, args.engine))


def run_angular(command, cwd, env, directory, port):
    directory.mkdir(parents=True, exist_ok=True)
    handler = ArchiveHandler(directory / f"angular.{port}.jsonl", maxBytes=20 * 1024 * 1024,
                             backupCount=0, encoding="utf-8")
    try:
        with subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                              errors="replace") as process:
            try:
                for line in process.stdout:
                    print(line, end="", flush=True)
                    message = line.rstrip("\r\n")
                    timestamp = now()
                    event = {"schema_version": 1, "received_at": timestamp, "timestamp": timestamp,
                             "target": "local", "host": "localhost", "service": f"angular:{port}",
                             "message": message, "raw": message}
                    handler.handle(logging.LogRecord("angular", logging.INFO, "", 0,
                                                     json.dumps(event, ensure_ascii=False), (), None))
                return process.wait()
            finally:
                if process.poll() is None:
                    process.terminate()
    finally:
        handler.close()
