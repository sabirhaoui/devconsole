"""Download remote snapshots and optionally restore into an isolated local Compose project."""
from __future__ import annotations

import hashlib
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


def remote_neo4j_script(compose, service, database):
    """A one-off container shares the stopped service's volumes and exact image/config."""
    c = quote_command(compose)
    s = shlex.quote(service)
    dump = quote_command(compose + ["run", "--rm", "--no-deps", "-T", "--entrypoint",
                                   "neo4j-admin", service, "database", "dump", database, "--to-stdout"])
    return (
        "set -eu\n"
        f'test -n "$({c} ps --status running -q {s})" || '
        '{ echo "Neo4j must initially be running" >&2; exit 1; }\n'
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


def fetch_databases(args, cfg, lab):
    try:
        remote = connection(cfg.get("ubuntu", {}), args.ubuntu_target)
        settings = remote.get("database_sync", {})
        if bool(args.neo4j_dump) == bool(args.stop_remote_neo4j):
            raise ValueError("Choisissez --neo4j-dump /chemin/neo4j.dump OU --stop-remote-neo4j")
        if args.restore and not all(settings.get(key) for key in ("postgres_image", "neo4j_image")):
            raise ValueError("Renseignez database_sync.postgres_image et neo4j_image (versions serveur) avant --restore")
        database = settings.get("neo4j_database", "neo4j")
        # Community restore targets its default database; system is intentionally never copied.
        if database != "neo4j":
            raise ValueError("Cette commande prend en charge la base Neo4j 'neo4j' uniquement")
        compose = ["docker", "compose", "--project-directory", settings.get("remote_project", "/workspace/twins_project")]
        if settings.get("remote_compose_file"):
            compose += ["-f", settings["remote_compose_file"]]
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
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Échec fetch-db : {error}. Les fichiers déjà téléchargés sont conservés.") from error
