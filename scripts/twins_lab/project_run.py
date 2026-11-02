"""Launch the development Compose stack and Angular from the configured Twins checkout."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess


def run_project(args, root: Path, generated: Path):
    try:
        root = root.resolve()
        compose_file = next((root / name for name in (
            "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"
        ) if (root / name).is_file()), None)
        if not compose_file:
            raise ValueError(f"Fichier Compose introuvable dans {root}")
        engine = shutil.which(args.engine)
        if not engine:
            raise ValueError(f"{args.engine} introuvable dans le PATH")
        compose = [engine, "compose", "-f", str(compose_file)]
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
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", args.port))
        generated.mkdir(parents=True, exist_ok=True)
        proxy_path = (generated / "proxy.project.json").resolve()
        existing_proxy = frontend / "proxy.conf.json"
        proxy = json.loads(existing_proxy.read_text(encoding="utf-8")) if existing_proxy.is_file() else {}
        proxy["/api"] = {"target": "http://127.0.0.1:8001", "secure": False,
                         "changeOrigin": True, "timeout": 600000, "proxyTimeout": 600000}
        proxy_path.write_text(json.dumps(proxy, indent=2), encoding="utf-8")
        # Match the current Compose topology; exclude the one-shot seed-db service.
        result = subprocess.run(compose + ["config", "--services"], cwd=root, capture_output=True, text=True, check=True)
        services = [service.strip() for service in result.stdout.splitlines() if service.strip() != "seed-db" and service.strip()]
        if "backend" not in services:
            raise ValueError("Le projet Compose doit déclarer le service backend")
        print(f"Démarrage des images existantes avec {args.engine} (sans rebuild)...", flush=True)
        subprocess.run(compose + ["up", "-d", "--no-build", *services], cwd=root, check=True)
        print(f"Démarrage Angular : http://localhost:{args.port}", flush=True)
        print("API : http://localhost:8001/docs", flush=True)
        print(f"Ctrl+C arrête Angular. Arrêt des conteneurs : lab project_twin run all --engine {args.engine} --action stop", flush=True)
        environment = os.environ.copy()
        environment["NG_CLI_ANALYTICS"] = "false"
        result = subprocess.run([node, str(angular), "serve", "--host", "127.0.0.1",
                                 "--port", str(args.port), "--proxy-config", str(proxy_path), *args.extra],
                                cwd=frontend, env=environment)
        raise SystemExit(result.returncode)
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Échec run all : {error}") from error
