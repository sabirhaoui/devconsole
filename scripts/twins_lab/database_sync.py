"""Download remote snapshots and optionally restore into an isolated local Compose project."""
from __future__ import annotations

import hashlib
import inspect
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
from datetime import datetime, timezone


def quote_command(argv):
    return shlex.join([str(value) for value in argv])


def remote_compose(settings):
    command = (["sudo", "-n"] if settings.get("remote_sudo", False) else []) + ["docker", "compose"]
    if settings.get("remote_env_file"):
        command += ["--env-file", settings["remote_env_file"]]
    if settings.get("remote_compose_project"):
        command += ["-p", settings["remote_compose_project"]]
    command += ["--project-directory", settings.get("remote_project", "/workspace/twins_project")]
    if settings.get("remote_compose_file"):
        command += ["-f", settings["remote_compose_file"]]
    return command


def validate_local_versions(root, engine, settings):
    root = Path(root).expanduser().resolve()
    compose_file = next((root / name for name in (
        "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"
    ) if (root / name).is_file()), None)
    if not compose_file:
        raise ValueError(f"Fichier Compose local introuvable dans {root}")
    for service, tool, image_key in (("postgres", "pg_dump", "postgres_image"),
                                      ("neo4j", "neo4j", "neo4j_image")):
        image = settings.get(image_key, "")
        expected = re.search(r":(\d+(?:\.\d+)*)", image)
        if not expected:
            raise ValueError(f"Renseignez {image_key} avec une version serveur pour vérifier la compatibilité locale")
        result = subprocess.run([engine, "compose", "-f", str(compose_file), "exec", "-T", service,
                                 tool, "--version"], cwd=root, capture_output=True, text=True, check=True)
        found = re.search(r"\b(\d+(?:\.\d+)+)\b", result.stdout + result.stderr)
        required = tuple(int(part) for part in expected.group(1).split("."))
        actual = tuple(int(part) for part in found.group(1).split(".")) if found else ()
        compatible = (actual[:1] == required[:1] if service == "postgres" else
                      actual[:2] == required[:2] and actual >= required)
        if not compatible:
            raise ValueError(f"Version {service} locale incompatible : {'.'.join(map(str, actual)) or 'inconnue'} ; "
                             f"image serveur configurée {image}. Mettez à niveau les bases locales avant l'injection")


def connection(config, target):
    result = {key: value for key, value in config.items() if key != "targets"}
    if target:
        if target not in config.get("targets", {}):
            raise ValueError(f"Cible Ubuntu inconnue : {target}")
        override = config["targets"][target]
        result.update(override)
        result["database_sync"] = {**config.get("database_sync", {}), **override.get("database_sync", {})}
    for key in ("host", "user"):
        value = str(result.get(key, ""))
        if not re.fullmatch(r"[a-zA-Z0-9_.:@-]+", value) or value.startswith("-"):
            raise ValueError(f"Configuration SSH invalide : {key}")
    return result


def download(ssh, remote_command, destination):
    """Keep binary dumps out of PowerShell/text decoding; publish only successful transfers."""
    partial = destination.with_suffix(destination.suffix + ".partial")
    try:
        with partial.open("xb") as stream:
            subprocess.run(ssh + [remote_command], stdout=stream, check=True)
        if partial.stat().st_size == 0:
            raise ValueError(f"Dump vide : {destination.name}")
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)


def shared_data_users(containers, target):
    selected = next(item for item in containers if item["Id"].startswith(target))
    sources = {mount["Source"] for mount in selected.get("Mounts", []) if mount["Destination"] == "/data"}
    if not sources:
        raise ValueError("Impossible d'identifier le volume /data de Neo4j")
    return [item.get("Name", item["Id"]) for item in containers if item["Id"] != selected["Id"]
            and any(mount["Source"] in sources for mount in item.get("Mounts", []))]


def remote_neo4j_script(compose, service, database):
    """A one-off container shares the stopped service's volumes and exact image/config."""
    c = quote_command(compose)
    s = shlex.quote(service)
    engine = compose[:compose.index("compose")]
    # A second deployment sharing /data can steal its lock as soon as the target stops.
    guard = (
        "import json, subprocess, sys\n" + inspect.getsource(shared_data_users)
        + f"\nengine = {engine!r}\n"
        "ids = subprocess.check_output(engine + ['ps', '-q'], text=True).split()\n"
        "items = json.loads(subprocess.check_output(engine + ['inspect'] + ids))\n"
        "duplicates = shared_data_users(items, sys.argv[1])\n"
        "if duplicates: raise SystemExit('Neo4j /data partagé avec un autre conteneur actif : ' + ', '.join(duplicates))\n"
    )
    dump = quote_command(compose + ["run", "--rm", "--no-deps", "-T", "--entrypoint",
                                   "neo4j-admin", service, "database", "dump", database, "--to-stdout"])
    return (
        "set -eu\n"
        f'test -n "$({c} ps --status running -q {s})" || '
        '{ echo "Neo4j must initially be running" >&2; exit 1; }\n'
        f"python3 -c {shlex.quote(guard)} \"$({c} ps --status running -q {s})\"\n"
        f"restart() {{ {c} start {s} >&2; }}\n"
        "trap restart EXIT\ntrap 'exit 130' INT\ntrap 'exit 143' TERM\n"
        f"{c} stop {s} >&2\n{dump}\n"
    )


def restore_local(directory, settings, database):
    """Fresh unique project/volumes; existing developer databases are never overwritten."""
    pg_password = secrets.token_hex(24)
    neo_password = secrets.token_hex(24)
    project = "twins-snapshot-" + secrets.token_hex(5)
    pg_port = int(settings.get("local_postgres_port", 55432))
    neo_port = int(settings.get("local_neo4j_port", 57687))
    http_port = int(settings.get("local_neo4j_http_port", 57474))
    if any(not 1024 <= port <= 65535 for port in (pg_port, neo_port, http_port)):
        raise ValueError("Les ports locaux doivent être compris entre 1024 et 65535")
    compose = {
        "name": project,
        "services": {
            "postgres": {
                "image": settings["postgres_image"],
                "environment": {"POSTGRES_USER": "twins", "POSTGRES_DB": "twins",
                                "POSTGRES_PASSWORD": pg_password},
                "ports": [f"127.0.0.1:{pg_port}:5432"],
                "volumes": ["pgdata:/var/lib/postgresql"],
                "healthcheck": {"test": ["CMD-SHELL", "pg_isready -U twins -d twins"],
                                "interval": "2s", "timeout": "5s", "retries": 60},
            },
            "neo4j": {
                "image": settings["neo4j_image"],
                "environment": {"NEO4J_AUTH": f"neo4j/{neo_password}"},
                "ports": [f"127.0.0.1:{neo_port}:7687", f"127.0.0.1:{http_port}:7474"],
                "volumes": ["neo4jdata:/data", "./:/backups:ro"],
                "healthcheck": {"test": ["CMD-SHELL", "wget -q --spider http://localhost:7474 || exit 1"],
                                "interval": "5s", "timeout": "5s", "retries": 60},
            },
        },
        "volumes": {"pgdata": {}, "neo4jdata": {}},
    }
    # PGDATA for both pre-18 and 18+ images, without relying on image mount defaults.
    compose["services"]["postgres"]["environment"]["PGDATA"] = "/var/lib/postgresql/snapshot"
    compose_path = directory / "compose.local.json"
    compose_path.write_text(json.dumps(compose, indent=2), encoding="utf-8")
    env_path = directory / "backend.local.env"
    env_path.write_text(
        f"DATABASE_URL=postgresql://twins:{pg_password}@127.0.0.1:{pg_port}/twins\n"
        f"NEO4J_URI=bolt://127.0.0.1:{neo_port}\nNEO4J_USER=neo4j\n"
        f"NEO4J_PASSWORD={neo_password}\nNEO4J_DATABASE={database}\n", encoding="utf-8")
    docker = ["docker", "compose", "-f", str(compose_path)]
    def run(extra, **kwargs):
        subprocess.run(docker + extra, cwd=directory, check=True, **kwargs)
    run(["run", "--rm", "--no-deps", "-T", "--entrypoint", "neo4j-admin", "neo4j",
         "database", "load", database, "--from-path=/backups"])
    run(["up", "-d", "--wait", "--wait-timeout", "180", "postgres"])
    with (directory / "postgres.dump").open("rb") as dump:
        run(["exec", "-T", "postgres", "pg_restore", "-U", "twins", "-d", "twins",
             "--no-owner", "--no-privileges", "--exit-on-error", "--single-transaction"], stdin=dump)
    run(["up", "-d", "--wait", "--wait-timeout", "300", "neo4j"])
    print(f"Bases locales démarrées. Configuration backend : {env_path}")
    print(f"Arrêt : docker compose -f \"{compose_path}\" stop")


def restore_project(directory, root, engine, replace_local):
    """Replace the checkout's databases, saving both originals before the first write."""
    if not replace_local:
        raise ValueError("--restore-project exige --replace-local : les données locales seront remplacées")
    root = Path(root).expanduser().resolve()
    compose_file = next((root / name for name in (
        "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"
    ) if (root / name).is_file()), None)
    if not compose_file:
        raise ValueError(f"Fichier Compose local introuvable dans {root}")
    compose = [engine, "compose", "-f", str(compose_file)]

    def run(extra, **kwargs):
        return subprocess.run(compose + extra, cwd=root, check=True, **kwargs)

    # Capture resolved credentials without displaying the Compose configuration.
    config = json.loads(run(["config", "--format", "json"], capture_output=True, text=True).stdout)
    services = config.get("services", {})
    if not {"postgres", "neo4j"}.issubset(services):
        raise ValueError("Le Compose local doit déclarer postgres et neo4j")
    env = services["postgres"].get("environment", {})
    user = env.get("POSTGRES_USER", "postgres")
    database = env.get("POSTGRES_DB", user)
    if not user or not database or database in ("postgres", "template0", "template1"):
        raise ValueError("Base PostgreSQL locale invalide ou réservée")
    running = run(["ps", "--services", "--status", "running"], capture_output=True, text=True).stdout.split()
    if not {"postgres", "neo4j"}.issubset(running):
        raise ValueError("Démarrez les bases locales postgres et neo4j avant l'injection")
    # Check that the local PostgreSQL client can read the downloaded archive before stopping anything.
    with (directory / "postgres.dump").open("rb") as stream:
        run(["exec", "-T", "postgres", "pg_restore", "--list"], stdin=stream, stdout=subprocess.DEVNULL)
    backup = directory / "local-before-restore"
    backup.mkdir(exist_ok=False)
    apps = [service for service in running if service not in ("postgres", "neo4j")]
    stopped = []
    changed = False
    recovered = False

    def neo_command(action):
        return ["run", "--rm", "--no-deps", "-T", "--entrypoint", "neo4j-admin", "neo4j",
                "database", action, "neo4j"]

    def load_pg(path):
        run(["exec", "-T", "postgres", "dropdb", "-U", user, "--force", "--if-exists", "--", database])
        run(["exec", "-T", "postgres", "createdb", "-U", user, "--owner", user, "--", database])
        with path.open("rb") as stream:
            run(["exec", "-T", "postgres", "pg_restore", "-U", user, "-d", database,
                 "--no-owner", "--no-privileges", "--exit-on-error", "--single-transaction"], stdin=stream)

    def load_neo(path):
        with path.open("rb") as stream:
            run(neo_command("load") + ["--from-stdin", "--overwrite-destination=true"], stdin=stream)

    try:
        if apps:
            stopped.extend(apps)
            run(["stop", *apps])
        with (backup / "postgres.dump").open("xb") as stream:
            run(["exec", "-T", "postgres", "pg_dump", "-U", user, "-d", database,
                 "--format=custom", "--no-owner", "--no-privileges"], stdout=stream)
        stopped.append("neo4j")
        run(["stop", "neo4j"])
        with (backup / "neo4j.dump").open("xb") as stream:
            run(neo_command("dump") + ["--to-stdout"], stdout=stream)
        if any((backup / name).stat().st_size == 0 for name in ("postgres.dump", "neo4j.dump")):
            raise ValueError("Sauvegarde locale vide : injection annulée")
        print(f"Sauvegarde des bases locales : {backup}", flush=True)
        changed = True
        load_neo(directory / "neo4j.dump")
        load_pg(directory / "postgres.dump")
        recovered = True
    except (OSError, ValueError, subprocess.CalledProcessError):
        if changed:
            print("Échec de l'injection : restauration des sauvegardes locales...", flush=True)
            try:
                load_neo(backup / "neo4j.dump")
                load_pg(backup / "postgres.dump")
                recovered = True
            except (OSError, subprocess.CalledProcessError) as rollback_error:
                raise ValueError(f"Récupération automatique échouée. Services arrêtés ; sauvegardes : {backup}") from rollback_error
        raise
    finally:
        if not changed or recovered:
            if "neo4j" in stopped:
                run(["start", "neo4j"])
            if apps and stopped:
                run(["start", *apps])
    print("Bases serveur injectées dans le projet local. Le .env et les comptes techniques des bases restent locaux.")


def fetch_databases(args, cfg, lab):
    try:
        remote = connection(cfg.get("ubuntu", {}), args.ubuntu_target)
        settings = remote.get("database_sync", {})
        inject = getattr(args, "restore_project", False)
        if inject and args.restore:
            raise ValueError("Choisissez --restore-project ou --restore, pas les deux")
        if inject and not getattr(args, "replace_local", False):
            raise ValueError("Ajoutez --replace-local pour autoriser le remplacement des données locales (sauvegarde automatique)")
        if inject:
            root = os.environ.get("TWINS_ROOT") or cfg.get("project", {}).get("root", "C:/workspace/twins_project")
            validate_local_versions(root, args.engine, settings)
        if bool(args.neo4j_dump) == bool(args.stop_remote_neo4j):
            raise ValueError("Choisissez --neo4j-dump /chemin/neo4j.dump OU --stop-remote-neo4j")
        if args.restore and not all(settings.get(key) for key in ("postgres_image", "neo4j_image")):
            raise ValueError("Renseignez database_sync.postgres_image et neo4j_image (versions serveur) avant --restore")
        database = settings.get("neo4j_database", "neo4j")
        # Community restore targets its default database; system is intentionally never copied.
        if database != "neo4j":
            raise ValueError("Cette commande prend en charge la base Neo4j 'neo4j' uniquement")
        compose = remote_compose(settings)
        pg_service = settings.get("postgres_service", "postgres")
        neo_service = settings.get("neo4j_service", "neo4j")
        if any(not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", s) for s in (pg_service, neo_service)):
            raise ValueError("Nom de service Compose invalide")
        pg = ["pg_dump", "--format=custom", "--no-owner", "--no-privileges", "--no-password",
              "-U", remote.get("remote_db_user", "postgres"), "-d", remote.get("remote_db_name", "twins_db")]
        mode = settings.get("postgres_mode", "native")
        if mode not in ("native", "compose"):
            raise ValueError("postgres_mode doit être native ou compose")
        if mode == "compose":
            pg = compose + ["exec", "-T", pg_service] + pg
        ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-p", str(int(remote.get("port", 22)))]
        if remote.get("ssh_key"):
            ssh += ["-i", os.path.expanduser(remote["ssh_key"])]
        ssh += [f"{remote['user']}@{remote['host']}"]
        neo = ("cat -- " + shlex.quote(args.neo4j_dump) if args.neo4j_dump else
               "sh -c " + shlex.quote(remote_neo4j_script(compose, neo_service, database)))
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        directory = (Path(args.output).expanduser() if args.output else
                     lab.parent.parent / "data" / "db-snapshots" / timestamp).resolve()
        directory.mkdir(parents=True, exist_ok=False)
        # Keep credentials/dumps untracked even with a custom output location.
        (directory / ".gitignore").write_text("*\n", encoding="utf-8")
        print(f"Téléchargement PostgreSQL vers {directory}", flush=True)
        download(ssh, quote_command(pg), directory / "postgres.dump")
        print("Téléchargement Neo4j" + (" (arrêt temporaire distant autorisé)" if args.stop_remote_neo4j else ""), flush=True)
        download(ssh, neo, directory / "neo4j.dump")
        manifest = {"created_at": timestamp, "host": remote["host"],
                    "target": args.ubuntu_target, "postgres_database": remote.get("remote_db_name", "twins_db"),
                    "neo4j_database": database, "sha256": {}}
        for name in ("postgres.dump", "neo4j.dump"):
            with (directory / name).open("rb") as stream:
                manifest["sha256"][name] = hashlib.file_digest(stream, "sha256").hexdigest()
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        print(f"Dumps téléchargés : {directory}")
        if args.restore:
            restore_local(directory, settings, database)
        if inject:
            root = os.environ.get("TWINS_ROOT") or cfg.get("project", {}).get("root", "C:/workspace/twins_project")
            restore_project(directory, root, args.engine, args.replace_local)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Échec fetch-db : {error}. Les fichiers déjà téléchargés sont conservés.") from error
