"""Dispatch development actions in the sibling Aras, AVEVA and A2 workspaces."""

import argparse
from collections import deque
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from time import sleep
import tomllib


PROJECTS = {
    "aveva": ("environnement AVEVA", "AVEVA_ROOT", ("run", "status", "stop", "logs")),
    "aras": ("environnement Aras", "ARAS_ROOT", ("build", "run", "status", "stop", "logs", "test")),
    "a2-connector": (
        "connecteur AVEVA ↔ Aras", "A2_CONNECTOR_ROOT",
        ("restore", "build", "run", "status", "stop", "logs", "test", "lint", "smoke",
         "test-integrity", "inspect-ifc", "test-api", "publish", "test-published", "run-published", "health"),
    ),
}

HELP = {
    "test-integrity": "vérifier l’intégrité IFC",
    "inspect-ifc": "afficher la taille et le SHA-256 d’un IFC",
    "test-api": "vérifier l’API IFC, la concurrence et la reprise",
    "publish": "publier le connecteur",
    "test-published": "vérifier le livrable publié",
    "run-published": "démarrer le livrable publié",
    "health": "interroger GET /health/live",
    "restore": "restaurer les dépendances",
    "build": "compiler ou préparer le package",
    "run": "démarrer le projet",
    "status": "consulter l’état du service",
    "stop": "arrêter le service",
    "logs": "consulter les journaux",
    "test": "exécuter les tests",
    "lint": "vérifier le code",
    "smoke": "vérifier les échanges avec des données de test",
}


def _line_count(value):
    count = int(value)
    if not 0 <= count <= sys.maxsize:
        raise argparse.ArgumentTypeError("utiliser un nombre de lignes positif ou nul")
    return count


def register_projects(parsers):
    for name, (description, env_var, actions) in PROJECTS.items():
        parser = parsers.add_parser(name, help=description)
        parser.add_argument("--root", type=Path, help=f"remplacer {env_var} et la racine configurée")
        commands = parser.add_subparsers(dest="cmd", required=True)
        commands.add_parser("doctor", help="vérifier le dossier et les lanceurs sans les exécuter")
        if name == "aveva":
            log = commands.add_parser("log", help="lire le journal de démarrage Unified Engineering")
            log.add_argument("--lines", type=_line_count, default=80, help="nombre de lignes (défaut : 80)")
            log.add_argument("--follow", action="store_true", help="suivre les nouvelles lignes jusqu’à Ctrl+C")
        for action in actions:
            command = commands.add_parser(action, help=HELP[action])
            command.add_argument("--dry-run", action="store_true", help="afficher la commande sans l’exécuter")
            command.add_argument("extra", nargs=argparse.REMAINDER, help="arguments transmis après --")


def _settings(config_file, project):
    def read(path):
        if not path.exists():
            return {}
        with path.open("rb") as stream:
            return tomllib.load(stream).get("workspace_projects", {}).get(project, {})

    defaults = read(config_file)
    commands = defaults.get("commands", {})
    for action, command in commands.items():
        if isinstance(command, list):
            commands[action] = [
                str(config_file.resolve().with_name("a2-connector.ps1")) if arg == "{a2_launcher}" else arg
                for arg in command
            ]
    local = read(config_file.with_name("lab.local.toml"))
    return (
        local.get("root", defaults.get("root")),
        {**commands, **local.get("commands", {})},
    )


def _validate(command):
    if not isinstance(command, list) or not command or not all(isinstance(arg, str) and arg for arg in command):
        raise ValueError("une commande doit être une liste TOML de chaînes non vides")


def _command(root, command):
    _validate(command)
    executable = Path(command[0]).expanduser()
    if executable.is_absolute() or "/" in command[0] or "\\" in command[0]:
        executable = root / executable
        if not executable.is_file():
            raise ValueError(f"lanceur introuvable : {executable}")
    else:
        executable = shutil.which(command[0])
        if not executable:
            raise ValueError(f"lanceur absent du PATH : {command[0]}")
    if Path(executable).suffix.lower() in {".bat", ".cmd", ".ps1"}:
        raise ValueError("utiliser un exécutable natif ou PowerShell avec -File pour un script .ps1")
    return [str(executable), *command[1:]]


def _show_aveva_log(lines, follow):
    local_appdata = os.environ.get("LOCALAPPDATA")
    if not local_appdata:
        raise ValueError("LOCALAPPDATA est introuvable dans l’environnement")
    path = (Path(local_appdata) / "Aveva" / "AVEVA Unified Engineering_init.log").resolve()
    try:
        with path.open("r", encoding="utf-8-sig", errors="replace") as journal:
            modified = datetime.fromtimestamp(os.fstat(journal.fileno()).st_mtime).astimezone()
            recent_lines = deque(journal, maxlen=lines)
            print(f"Journal : {path}")
            print(f"Dernière modification : {modified.isoformat(sep=' ', timespec='seconds')}")
            sys.stdout.writelines(recent_lines)
            sys.stdout.flush()
            while follow:
                sleep(0.25)
                sys.stdout.writelines(journal)
                sys.stdout.flush()
    except FileNotFoundError:
        raise ValueError(f"journal introuvable : {path}") from None
    except OSError as exc:
        raise ValueError(f"impossible de lire le journal {path} : {exc.strerror}") from exc
    return 0


def run_action(args, config_file):
    _, env_var, actions = PROJECTS[args.project]
    try:
        if args.project == "aveva" and args.cmd == "log":
            return _show_aveva_log(args.lines, args.follow)
        root_setting, commands = _settings(config_file, args.project)
        default_root = config_file.resolve().parents[3] / args.project
        root = Path(args.root or os.environ.get(env_var) or root_setting or default_root).expanduser().resolve()
        if args.cmd == "doctor":
            print(f"{args.project} : {root}")
            print("Dossier : " + ("OK" if root.is_dir() else "introuvable"))
            ready = root.is_dir()
            for action in actions:
                try:
                    if action not in commands:
                        raise ValueError("à configurer dans lab.local.toml")
                    _command(root, commands[action])
                    print(f"  {action}: lanceur disponible")
                except ValueError as exc:
                    print(f"  {action}: {exc}")
                    ready = False
            return 0 if ready else 1
        if args.cmd not in commands:
            raise ValueError(f"action {args.cmd} à configurer dans {config_file.with_name('lab.local.toml')}")
        extra = args.extra[1:] if args.extra[:1] == ["--"] else args.extra
        if args.dry_run:
            _validate(commands[args.cmd])
            print(json.dumps({"cwd": str(root), "argv": [*commands[args.cmd], *extra]}, ensure_ascii=False))
            return 0
        if not root.is_dir():
            raise ValueError(f"dossier introuvable : {root} (renseigner {env_var} ou --root)")
        command = _command(root, commands[args.cmd])
        return subprocess.run([*command, *extra], cwd=root, check=False).returncode
    except (OSError, TypeError, ValueError) as exc:
        print(f"[{args.project}] {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
