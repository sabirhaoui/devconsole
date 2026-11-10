"""Launch the development Compose stack and Angular from the configured Twins checkout."""
import json
import errno
import os
from pathlib import Path
import shutil
import socket
import subprocess


def compose_command(root, engine_name):
    compose_file = next((root / name for name in (
        "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"
    ) if (root / name).is_file()), None)
    if not compose_file:
        raise ValueError(f"Fichier Compose introuvable dans {root}")
    engine = shutil.which(engine_name)
    if not engine:
        raise ValueError(f"{engine_name} introuvable dans le PATH")
    return [engine, "compose", "-f", str(compose_file)]


def trail_logs(args, root: Path):
    """Stream existing Compose services without starting or stopping the project."""
    try:
        root = root.resolve()
        command = compose_command(root, args.engine) + ["logs",
                   "--tail", str(args.tail), "--timestamps"]
        if not args.no_follow:
            command.append("--follow")
        command.extend(args.services)
        raise SystemExit(subprocess.run(command, cwd=root).returncode)
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (OSError, ValueError) as error:
        raise SystemExit(f"Échec trail logs : {error}") from error


def project_frontend_is_running(frontend, port):
    """Only reuse a listener whose command belongs to this checkout's Angular CLI."""
    if os.name != "nt":
        return False
    script = (
        f"Get-NetTCPConnection -LocalPort {int(port)} -State Listen -ErrorAction Stop | "
        "ForEach-Object { (Get-CimInstance Win32_Process -Filter "
        "('ProcessId = ' + $_.OwningProcess)).CommandLine } | ConvertTo-Json -Compress"
    )
    try:
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                                capture_output=True, text=True, check=True, timeout=15)
        commands = json.loads(result.stdout)
        if isinstance(commands, str):
            commands = [commands]
        expected = str(frontend / "node_modules" / "@angular" / "cli" / "bin" / "ng.js").replace("\\", "/").lower()
        return any(expected in command.replace("\\", "/").lower() and " serve " in command
                   for command in (commands or []) if isinstance(command, str))
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def run_project(args, root: Path, generated: Path):
    try:
        root = root.resolve()
        compose = compose_command(root, args.engine)
        if args.action != "up":
            result = subprocess.run(compose + (["stop"] if args.action == "stop" else ["ps"]), cwd=root)
            raise SystemExit(result.returncode)
        if not (root / ".env").is_file():
            raise ValueError("Configuration .env absente : préparez le projet avec 'lab project_twin assemble build'.")
        frontend = root / "frontend"
        # Run the already installed CLI directly: never download dependencies during run.
        angular = frontend / "node_modules" / "@angular" / "cli" / "bin" / "ng.js"
        node = shutil.which("node")
        if not node or not angular.is_file():
            raise ValueError("Node ou Angular CLI local absent : installez les dépendances frontend avec npm ci.")
        if not 1024 <= args.port <= 65535:
            raise ValueError("Le port frontend doit être compris entre 1024 et 65535")
        reuse_frontend = False
        try:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", args.port))
        except OSError as error:
            if error.errno != errno.EADDRINUSE and getattr(error, "winerror", None) != 10048:
                raise
            reuse_frontend = project_frontend_is_running(frontend, args.port)
            if not reuse_frontend:
                raise ValueError(f"Le port {args.port} est déjà utilisé par un autre processus. "
                                 f"Choisissez un autre port : lab project_twin run all --port {args.port + 1}") from error
            if args.extra:
                raise ValueError("Angular est déjà actif ; arrêtez cette instance avant de modifier ses arguments")
        generated.mkdir(parents=True, exist_ok=True)
        proxy_path = (generated / "proxy.project.json").resolve()
        existing_proxy = frontend / "proxy.conf.json"
        proxy = json.loads(existing_proxy.read_text(encoding="utf-8")) if existing_proxy.is_file() else {}
        proxy["/api"] = {"target": "http://127.0.0.1:8001", "secure": False,
                         "changeOrigin": True, "timeout": 600000, "proxyTimeout": 600000}
        if not reuse_frontend:
            proxy_path.write_text(json.dumps(proxy, indent=2), encoding="utf-8")
        # Match the current Compose topology; exclude the one-shot seed-db service.
        result = subprocess.run(compose + ["config", "--services"], cwd=root, capture_output=True, text=True, check=True)
        services = [service.strip() for service in result.stdout.splitlines() if service.strip() != "seed-db" and service.strip()]
        if "backend" not in services:
            raise ValueError("Le projet Compose doit déclarer le service backend")
        print(f"Démarrage des images existantes avec {args.engine} (sans rebuild)...", flush=True)
        subprocess.run(compose + ["up", "-d", "--no-build", *services], cwd=root, check=True)
        if reuse_frontend:
            print(f"Angular est déjà actif pour ce projet : http://localhost:{args.port}", flush=True)
            print("Services locaux démarrés. API : http://localhost:8001/docs", flush=True)
            raise SystemExit(0)
        print(f"Démarrage Angular : http://localhost:{args.port}", flush=True)
        print("API : http://localhost:8001/docs", flush=True)
        print(f"Ctrl+C arrête Angular. Arrêt des conteneurs : lab project_twin run all --engine {args.engine} --action stop", flush=True)
        environment = os.environ.copy()
        environment["NG_CLI_ANALYTICS"] = "false"
        from local_logs import local_directory, run_angular
        directory = local_directory(generated.parent, args.engine)
        raise SystemExit(run_angular(
            [node, str(angular), "serve", "--host", "127.0.0.1", "--port", str(args.port),
             "--proxy-config", str(proxy_path), *args.extra],
            frontend, environment, directory, args.port))
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Échec run all : {error}") from error
