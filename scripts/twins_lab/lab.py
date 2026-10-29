#!/usr/bin/env python3
"""twins_lab - isolate, inspect, test, build, init and launch ONE component of twins_project.

Commands
  list                          components declared in components/*.toml
  scan component                scan backend/app/modules/ to auto-discover and register components
  doctor                        check toolchain, dependencies, databases and runtime
  install --check               verify lab prerequisites without installing
  install --dashboard           generate and open the prerequisite dashboard
  install all                   install system tools and project dependencies
  init <comp>                   initialize local fixtures, stubs, and isolated environment for a component
  build <comp> [--standalone]   build and generate a traceability manifest with Git SCM info
  inspect <comp> [--side ..]    what the component imports from / is imported by the rest of the app
  up|down <comp>                start/stop only the docker services the component needs
  test <comp> [--side ..]       run only the component's tests    (extra args after --)
  run <comp> backend|frontend   launch the component alone        (extra args after --)

Stdlib only. Requires Python >= 3.11 (tomllib).
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tomllib
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent
GEN = LAB / ".generated"
BUILDS_DIR = LAB / "builds"


# --------------------------------------------------------------------------- config
def load_cfg() -> tuple[dict, Path]:
    cfg_file = LAB / "lab.toml"
    cfg = tomllib.loads(cfg_file.read_text(encoding="utf-8")) if cfg_file.exists() else {"project": {}}
    root = Path(os.environ.get("TWINS_ROOT") or cfg.get("project", {}).get("root", "C:/workspace/twins_project")).expanduser()
    return cfg, root


def manifests() -> dict[str, Path]:
    comp_dir = LAB / "components"
    if not comp_dir.exists():
        comp_dir.mkdir(parents=True, exist_ok=True)
    return {p.stem: p for p in sorted(comp_dir.glob("*.toml"))}


def load_component(name: str) -> tuple[dict, Path]:
    ms = manifests()
    if name not in ms:
        known = ", ".join(ms.keys()) if ms else "(aucun composant déclaré dans components/)"
        sys.exit(
            f"[-] Erreur : Composant '{name}' inconnu.\n"
            f"[+] Composants connus : {known}\n"
            f"[+] Astuce : Lancez 'lab scan component' pour découvrir les modules ou 'lab list' pour afficher les composants."
        )
    return tomllib.loads(ms[name].read_text(encoding="utf-8")), ms[name]


def component_name(m: dict, fallback: str) -> str:
    return m.get("component", {}).get("name", m.get("name", fallback))


def python_exe(cfg: dict) -> str:
    root = Path(os.environ.get("TWINS_ROOT") or cfg.get("project", {}).get("root", "")).expanduser()
    venv_bin = "Scripts/python.exe" if os.name == "nt" else "bin/python"
    venv_py = root / "backend" / ".venv" / Path(venv_bin)
    if venv_py.exists():
        return str(venv_py)
    return sys.executable


def npx_exe() -> str:
    executable = shutil.which("npx")
    if sys.platform.startswith("win"):
        return executable or shutil.which("npx.CMD") or shutil.which("npx.cmd") or "npx.CMD"
    return executable or "npx"


def sh(cmd: list[str], cwd: Path, env: dict | None = None) -> int:
    print(f"\n$ {' '.join(map(str, cmd))}\n  (cwd: {cwd})\n")
    try:
        use_shell = os.name == "nt"
        return subprocess.call(cmd, cwd=cwd, env=env, shell=use_shell)
    except KeyboardInterrupt:
        return 130


# ------------------------------------------------------------------ static analysis
def bucket(mod: str) -> str:
    """Group a dotted module path: app.modules.<name> / app.<pkg>."""
    p = mod.split(".")
    return ".".join(p[:3] if p[:2] == ["app", "modules"] else p[:2])


def py_imports(path: Path, backend_root: Path):
    parts = list(path.relative_to(backend_root).with_suffix("").parts)
    is_pkg = parts[-1] == "__init__"
    if is_pkg:
        parts = parts[:-1]
    pkg = parts if is_pkg else parts[:-1]
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError as exc:
        print(f"  ! skipped {path.name}: {exc}")
        return
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                yield a.name, []
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                keep = len(pkg) - (node.level - 1)
                if keep < 0:
                    continue
                mod = ".".join(pkg[:keep] + (node.module.split(".") if node.module else []))
            else:
                mod = node.module or ""
            yield mod, [a.name for a in node.names]


def analyze_backend(root: Path, b: dict):
    broot = root / "backend"
    comp_dir = root / b["dir"]
    package = b["package"]
    outbound: dict[str, dict] = defaultdict(lambda: {"symbols": set(), "files": set()})
    for f in comp_dir.rglob("*.py"):
        for mod, names in py_imports(f, broot):
            if mod == package or mod.startswith(package + "."):
                continue
            if mod == "app" or mod.startswith("app."):
                e = outbound[bucket(mod)]
                e["symbols"].update(names or [mod.split(".")[-1]])
                e["files"].add(f.name)
    inbound: dict[str, set] = defaultdict(set)
    for f in (broot / "app").rglob("*.py"):
        if comp_dir in f.parents:
            continue
        for mod, names in py_imports(f, broot):
            if mod == package or mod.startswith(package + "."):
                owner = bucket(".".join(f.relative_to(broot).with_suffix("").parts))
                inbound[owner].update(names or [mod.split(".")[-1]])
    return outbound, inbound


_TS_IMPORT = re.compile(r"""(?:from|import)\s*\(?\s*['"]([^'"]+)['"]""")


def analyze_frontend(root: Path, fe: dict):
    app_root = root / "frontend" / "src" / "app"
    comp_dir = root / fe["dir"]
    outbound: dict[str, dict] = defaultdict(lambda: {"symbols": set(), "files": set()})
    for f in comp_dir.rglob("*.ts"):
        if f.name.endswith(".spec.ts"):
            continue
        for spec in _TS_IMPORT.findall(f.read_text(encoding="utf-8")):
            if spec.startswith("."):
                target = (f.parent / spec).resolve()
                if comp_dir.resolve() in [target, *target.parents]:
                    continue
                try:
                    rel = target.relative_to(app_root.resolve())
                except ValueError:
                    key = f"(outside src/app) {spec}"
                else:
                    key = "/".join(rel.parts[:2])
            elif spec.startswith("@/") or spec.startswith("src/"):
                key = "/".join(spec.replace("@/", "").split("/")[:2]) + "  [alias]"
            else:
                key = "npm:" + ("/".join(spec.split("/")[:2]) if spec.startswith("@") else spec.split("/")[0])
            outbound[key]["files"].add(f.name)
            outbound[key]["symbols"].add(spec.rsplit("/", 1)[-1])
    return outbound


def show(title: str, rows: dict, with_files: bool = True):
    print(f"\n== {title}")
    if not rows:
        print("    (none)")
        return
    for key in sorted(rows):
        v = rows[key]
        if isinstance(v, dict):
            syms = ", ".join(sorted(v["symbols"]))[:110]
            print(f"    {key:<42} {len(v['files']):>3} file(s)   {syms}")
        else:
            print(f"    {key:<42} {', '.join(sorted(v))[:110]}")


# ----------------------------------------------------------------------- commands
def cmd_list(args, cfg, root):
    ms = manifests()
    print("=== [TWINS_LAB] Liste des Composants Déclarés ===")
    if not ms:
        print("  (aucun fichier .toml trouvé dans scripts/twins_lab/components/)\n")
        print("  Astuce : Exécutez 'lab scan component' pour découvrir automatiquement les composants.")
        return

    print(f"{'COMPOSANT':<20} {'CÔTÉS (SIDES)':<18} {'DESCRIPTION'}")
    print("-" * 65)
    for name, path in ms.items():
        try:
            m = tomllib.loads(path.read_text(encoding="utf-8"))
            sides = [s for s in ("backend", "frontend") if s in m]
            sides_str = " + ".join(sides) if sides else "aucun"
            desc = m.get("component", {}).get("description", m.get("description", "(pas de description)"))
            print(f"{name:<20} [{sides_str:<15}] {desc}")
        except Exception as exc:
            print(f"{name:<20} [erreur fichier]     Erreur de lecture: {exc}")
    print("-" * 65)

def cmd_scan(args, cfg, root):
    print("=== [TWINS_LAB] SCAN : Découverte automatique (Backend & Frontend) ===")
    backend_modules = root / "backend" / "app" / "modules"
    if not backend_modules.is_dir():
        print(f"[-] Dossier introuvable : {backend_modules}")
        return

    comp_dir = LAB / "components"
    comp_dir.mkdir(parents=True, exist_ok=True)

    discovered = 0
    updated = 0
    for item in sorted(backend_modules.iterdir()):
        if item.is_dir() and not item.name.startswith("_"):
            comp_name = item.name
            toml_path = comp_dir / f"{comp_name}.toml"
            
            # Chemins de tests backend
            test_paths = []
            for test_sub in [root / "backend" / "tests" / "unit" / comp_name, root / "backend" / "tests" / "integration" / comp_name]:
                if test_sub.is_dir():
                    test_paths.append(test_sub.relative_to(root / "backend").as_posix())
            if not test_paths:
                test_paths = [f"tests/unit/{comp_name}"]

            # Recherche d'un dossier frontend associé dans l'application Angular
            fe_candidates = [
                root / "frontend" / "src" / "app" / "pages" / comp_name,
                root / "frontend" / "src" / "app" / "features" / comp_name,
                root / "frontend" / "src" / "app" / comp_name
            ]
            fe_dir = next((c for c in fe_candidates if c.is_dir()), None)
            has_frontend = fe_dir is not None
            fe_rel_path = fe_dir.relative_to(root / "frontend").as_posix() if has_frontend else f"src/app/pages/{comp_name}"

            if not toml_path.exists():
                toml_content = f"""name = "{comp_name}"
description = "Composant découvert automatiquement par le lab scan"

[backend]
dir = "backend/app/modules/{comp_name}"
package = "app.modules.{comp_name}"
test_paths = {json.dumps(test_paths)}
"""
                if has_frontend:
                    toml_content += f"""
[frontend]
dir = "{fe_rel_path}"
test_paths = ["{fe_rel_path}"]
"""
                toml_path.write_text(toml_content, encoding="utf-8")
                print(f"[+] Composant créé{' avec frontend' if has_frontend else ''} : {comp_name}")
                discovered += 1
            else:
                # Met à jour le TOML existant si un frontend est détecté mais absent du fichier
                content = toml_path.read_text(encoding="utf-8")
                if has_frontend and "[frontend]" not in content:
                    content += f"""
[frontend]
dir = "{fe_rel_path}"
test_paths = ["{fe_rel_path}"]
"""
                    toml_path.write_text(content, encoding="utf-8")
                    print(f"[+] Section [frontend] ajoutée au composant : {comp_name}")
                    updated += 1
                else:
                    print(f"[=] Composant déjà à jour : {comp_name}")

    print(f"\n[SUCCESS] Scan terminé. {discovered} créé(s), {updated} mis à jour.")
    print("[+] Exécutez 'lab list' pour vérifier les côtés détectés.")
def check_python_requirements(python: str, requirements: Path) -> tuple[bool, str]:
    script = """
import sys
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.version import Version

missing = []
visited = set()
def inspect_file(path):
    path = path.resolve()
    if path in visited:
        return
    visited.add(path)
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith(("-r ", "--requirement ")):
            inspect_file(path.parent / line.split(None, 1)[1])
            continue
        if line.startswith("-"):
            continue
        try:
            requirement = Requirement(line)
        except ValueError as exc:
            missing.append(f"cannot verify requirement {line!r}: {exc}")
            continue
        if requirement.marker and not requirement.marker.evaluate():
            continue
        try:
            installed = Version(version(requirement.name))
        except PackageNotFoundError:
            missing.append(f"{requirement.name}{requirement.specifier} is not installed")
            continue
        if requirement.specifier and not requirement.specifier.contains(installed, prereleases=True):
            missing.append(f"{requirement.name}: installed {installed}, required {requirement.specifier}")

inspect_file(Path(sys.argv[1]))
if missing:
    print("\\n".join(missing))
    sys.exit(1)
print("All active requirements are installed at compatible versions.")
"""
    try:
        result = subprocess.run(
            [python, "-c", script, str(requirements)],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)
    return result.returncode == 0, (result.stdout or result.stderr).strip()


def cmd_doctor(args, cfg, root):
    failures = 0
    phase = getattr(args, "phase", "all")
    checks = []

    def check(label, ok, hint="", required=True, stage="build"):
        nonlocal failures
        if phase == "build" and stage == "run":
            return
        status = "OK" if ok else ("FAIL" if required else "WARN")
        checks.append({
            "label": label,
            "status": status,
            "required": required,
            "stage": stage,
            "details": "" if ok else hint,
        })
        if not getattr(args, "json", False):
            scope = "RUN" if stage == "run" else "BUILD"
            print(f"    [{status}] [{scope}] {label}" + ("" if ok or not hint else f" -> {hint}"))
        if not ok and required:
            failures += 1

    def run_version(command, cwd=None, timeout=15, env=None):
        try:
            result = subprocess.run(
                command,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=env,
                shell=os.name == "nt" and Path(command[0]).suffix.lower() in {".bat", ".cmd"},
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return None, str(exc)
        output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
        return (output if result.returncode == 0 else None), output

    if not getattr(args, "json", False):
        print(f"\nTWINS LAB - verification des prerequis\nproject root: {root}")
    check("Répertoire backend", (root / "backend").is_dir(), "Définir TWINS_ROOT ou project.root dans lab.toml.")
    check("Répertoire frontend", (root / "frontend").is_dir(), "Définir TWINS_ROOT ou project.root dans lab.toml.")
    check("Python >= 3.11", sys.version_info >= (3, 11),
          f"Version actuelle : {sys.version.split()[0]}. Installer Python 3.11 ou plus récent.")

    py = python_exe(cfg)
    if Path(py).exists() or shutil.which(py):
        backend_venv = root / "backend" / ".venv"
        check("Environnement virtuel Python backend",
              (backend_venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")).is_file(),
              f"Exécuter lab install all pour créer {backend_venv}.")
        requirements = root / "backend" / "requirements.txt"
        check("Manifeste backend/requirements.txt", requirements.is_file(),
              "Restaurer le manifeste des dépendances backend.")
        if requirements.is_file():
            requirements_ok, requirements_output = check_python_requirements(py, requirements)
            check(f"Dépendances Python installées ({py})", requirements_ok,
                  requirements_output or f"Exécuter {py} -m pip install -r {requirements}.")
        pip_result, pip_error = run_version([py, "-m", "pip", "--version"])
        check("pip disponible dans l'environnement backend", pip_result is not None,
              pip_error or f"Exécuter {py} -m ensurepip.")
        pip_result, pip_error = run_version([py, "-m", "pip", "check"])
        check("Cohérence des dépendances Python", pip_result is not None,
              pip_error or f"Exécuter {py} -m pip check.")
    else:
        check("Interpréteur Python backend", False, f"Introuvable : {py}. Exécuter lab install all.")

    node_path = shutil.which("node")
    node_script = (
        "const semver=require('semver');"
        "const range=require('./node_modules/@angular/cli/package.json').engines.node;"
        "console.log(`Node ${process.version}; Angular CLI requires ${range}`);"
        "if(!semver.satisfies(process.version,range)) process.exit(1);"
    )
    node_version, node_error = (
        run_version([node_path, "-e", node_script], cwd=root / "frontend")
        if node_path and (root / "frontend" / "node_modules" / "@angular" / "cli" / "package.json").is_file()
        else (None, "")
    )
    check("Version Node.js compatible avec Angular CLI", node_version is not None,
          node_error or "Installer Node.js 22+ et les dépendances npm du frontend.")

    npm_path = shutil.which("npm")
    npm_version, npm_error = run_version([npm_path, "--version"]) if npm_path else (None, "")
    check("npm", npm_version is not None, npm_error or "Installer Node.js LTS, qui inclut npm.")

    npx_path = shutil.which("npx") or shutil.which("npx.CMD") or shutil.which("npx.cmd")
    npx_version, npx_error = run_version([npx_path, "--version"]) if npx_path else (None, "")
    check("npx", npx_version is not None, npx_error or "Installer Node.js LTS, qui inclut npx.")

    frontend = root / "frontend"
    check("Manifeste frontend/package.json", (frontend / "package.json").is_file(),
          "Restaurer le manifeste du frontend.")
    lockfile = frontend / "package-lock.json"
    check("Lockfile frontend/package-lock.json", lockfile.is_file(),
          "Restaurer le lockfile npm du frontend.")
    if npm_path and (frontend / "package.json").is_file() and lockfile.is_file():
        npm_ci, npm_ci_error = run_version(
            [npm_path, "ci", "--engine-strict", "--dry-run", "--ignore-scripts", "--no-audit", "--no-fund"],
            cwd=frontend,
            timeout=180,
        )
        check("Résolution reproductible de npm ci", npm_ci is not None,
              (f"{npm_ci_error[-1500:]}\nCorriger package.json/package-lock.json puis relancer lab install all."
               if npm_ci_error else
               "npm ci --dry-run a échoué. Corriger package.json/package-lock.json puis relancer lab install all.")
              if npm_ci is None else "")
        npm_ls, npm_error = run_version([npm_path, "ls", "--json"], cwd=frontend, timeout=120)
        check("Dépendances npm installées dans node_modules", npm_ls is not None,
              npm_error[:1000] or "Exécuter npm ci dans le répertoire frontend.")
    else:
        check("Résolution reproductible de npm ci", False,
              "Installer npm et restaurer package.json/package-lock.json dans frontend.")
        check("Dépendances npm installées dans node_modules", False,
              "Exécuter npm ci dans le répertoire frontend.")

    component_files = manifests()
    check("configuration des composants presente", bool(component_files), "executer 'lab scan component' ou ajouter un fichier components/<nom>.toml")
    component_config_errors = []
    test_config_warnings = []
    for name, manifest in component_files.items():
        try:
            component = tomllib.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            component_config_errors.append(f"{name}: {exc}")
            continue
        for side in ("backend", "frontend"):
            if side not in component:
                continue
            test_paths = component[side].get("test_paths")
            valid_paths = isinstance(test_paths, list) and all(
                isinstance(path, str) and path.strip() for path in test_paths
            )
            if not valid_paths or not test_paths:
                test_config_warnings.append(f"{name}: {side}.test_paths")
                continue
            side_root = root / side
            for test_path in test_paths:
                if not (side_root / test_path).exists():
                    test_config_warnings.append(f"{name}: {side}/{test_path}")
    check("fichiers TOML des composants valides", not component_config_errors,
          "; ".join(component_config_errors[:3]) or f"{len(component_config_errors)} fichier(s) TOML invalide(s)")
    check("chemins de tests des composants", not test_config_warnings,
          f"{len(test_config_warnings)} chemin(s) manquant(s), ex.: {', '.join(test_config_warnings[:3])}",
          required=False)

    compose_file = root / "docker-compose.yml"
    try:
        compose_text = compose_file.read_text(encoding="utf-8")
    except OSError:
        compose_text = ""
    services_match = re.search(r"(?ms)^services:\s*\r?\n(.*?)(?=^[^\s#]|\Z)", compose_text)
    services_block = services_match.group(1) if services_match else ""
    compose_services = set(re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", services_block))
    required_services = {
        "nginx", "postgres", "neo4j", "redis", "backend", "mailpit",
        "celery-worker", "celery-beat", "flower", "seed-db",
    }
    check("Services requis déclarés dans docker-compose.yml",
          compose_file.is_file() and required_services.issubset(compose_services),
          "Le Compose doit déclarer PostgreSQL, Neo4j, Redis, Mailpit, backend, worker, beat, Flower, Nginx et seed-db.")

    required_env = {
        "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB",
        "NEO4J_USER", "NEO4J_PASSWORD", "JWT_SECRET_KEY",
    }
    configured_env = {key for key, value in os.environ.items() if value.strip()}
    env_file = root / ".env"
    env_values = {}
    if env_file.is_file():
        for raw in env_file.read_text(encoding="utf-8", errors="replace").splitlines():
            entry = raw.strip()
            if entry and not entry.startswith("#") and "=" in entry:
                key, value = entry.split("=", 1)
                key = key.strip().removeprefix("export ").strip()
                env_values[key] = value.strip()
                if value.strip():
                    configured_env.add(key)
    missing_env = sorted(required_env - configured_env)
    check("Configuration .env pour PostgreSQL, Neo4j et JWT",
          not missing_env,
          f"Créer {env_file} depuis .env.example et renseigner : {', '.join(missing_env)}.")
    openai_key = os.environ.get("OPENAI_API_KEY", "").strip() or env_values.get("OPENAI_API_KEY", "")
    check("Clé OpenAI (fonctionnalités Assystan/LLM)", bool(openai_key),
          "Renseigner OPENAI_API_KEY dans .env pour utiliser les fonctionnalités LLM.",
          required=False)

    docker_path = shutil.which("docker")
    if not docker_path and os.name == "nt":
        default_docker = Path(r"C:\Program Files\Docker\Docker\resources\bin\docker.exe")
        if default_docker.is_file():
            docker_path = str(default_docker)
    docker_version, docker_error = (
        run_version([docker_path, "--version"]) if docker_path else (None, "")
    )
    check("Docker CLI (Docker Desktop)", docker_version is not None,
          docker_error or "Installer Docker Desktop avec lab install all.")
    compose_version, compose_error = (
        run_version([docker_path, "compose", "version", "--short"])
        if docker_path and docker_version is not None else (None, "")
    )
    check("Docker Compose v2", compose_version is not None,
          compose_error or "Installer ou mettre à jour Docker Desktop (plugin Compose v2).")

    compose_config_valid = False
    compose_config_error = ""
    if docker_path and compose_version is not None:
        config_result, compose_config_error = run_version(
            [docker_path, "compose", "-f", str(compose_file), "config", "--quiet"],
            cwd=root,
        )
        compose_config_valid = config_result is not None
    check("Configuration Docker Compose valide", compose_config_valid,
          compose_config_error[:1000] or "Vérifier docker-compose.yml, .env et Docker Compose v2.")

    postgres_candidates = [shutil.which("postgres")]
    if os.name == "nt":
        for program_root in (
            os.environ.get("ProgramFiles"),
            os.environ.get("ProgramFiles(x86)"),
        ):
            if program_root:
                postgres_candidates.append(
                    str(Path(program_root) / "PostgreSQL" / "15" / "bin" / "postgres.exe")
                )
    postgres_path = None
    postgres_version = None
    postgres_version_error = ""
    for candidate in postgres_candidates:
        if not candidate or not Path(candidate).is_file():
            continue
        candidate_version, candidate_error = run_version([candidate, "--version"])
        if postgres_path is None:
            postgres_path = candidate
            postgres_version = candidate_version
            postgres_version_error = candidate_error
        candidate_major = re.search(
            r"PostgreSQL\)?\s+(\d+)", candidate_version or "", re.IGNORECASE
        )
        if candidate_major and candidate_major.group(1) == "15":
            postgres_path = candidate
            postgres_version = candidate_version
            postgres_version_error = candidate_error
            break
    postgres_major = re.search(r"PostgreSQL\)?\s+(\d+)", postgres_version or "", re.IGNORECASE)
    check("Serveur PostgreSQL natif 15 installé",
          postgres_major is not None and postgres_major.group(1) == "15",
          postgres_version_error or "Exécuter lab install all pour installer PostgreSQL 15.",
          stage="run")

    java_candidates = []
    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        java_candidates.append(
            str(Path(java_home) / "bin" / ("java.exe" if os.name == "nt" else "java"))
        )
    java_candidates.append(shutil.which("java"))
    if os.name == "nt":
        for program_root in (
            os.environ.get("ProgramFiles"),
            os.environ.get("ProgramFiles(x86)"),
            os.environ.get("LOCALAPPDATA"),
        ):
            if not program_root:
                continue
            for pattern in (
                "Eclipse Adoptium/jdk-17*/bin/java.exe",
                "Eclipse Adoptium/jdk-21*/bin/java.exe",
                "Programs/Eclipse Adoptium/jdk-17*/bin/java.exe",
                "Programs/Eclipse Adoptium/jdk-21*/bin/java.exe",
                "Java/jdk-17*/bin/java.exe",
                "Java/jdk-21*/bin/java.exe",
            ):
                java_candidates.extend(
                    str(path) for path in Path(program_root).glob(pattern)
                )
    java_path = None
    java_version = None
    java_error = ""
    java_major = None
    for candidate in java_candidates:
        if not candidate or not Path(candidate).is_file():
            continue
        candidate_version, candidate_error = run_version([candidate, "-version"])
        candidate_major = re.search(
            r'version\s+"(?:1\.)?(\d+)', candidate_version or "", re.IGNORECASE
        )
        if java_path is None:
            java_path = candidate
            java_version = candidate_version
            java_error = candidate_error
            java_major = candidate_major
        if candidate_major and candidate_major.group(1) in {"17", "21"}:
            java_path = candidate
            java_version = candidate_version
            java_error = candidate_error
            java_major = candidate_major
            break
    check("JDK Java 17 ou 21 (Neo4j natif)",
          java_major is not None and java_major.group(1) in {"17", "21"},
          java_error or "Exécuter lab install all pour installer Temurin JDK 17.",
          stage="run")

    neo4j_candidates = []
    neo4j_home = os.environ.get("NEO4J_HOME")
    if neo4j_home:
        neo4j_candidates.append(Path(neo4j_home) / "bin" / ("neo4j.bat" if os.name == "nt" else "neo4j"))
    if os.name == "nt" and os.environ.get("LOCALAPPDATA"):
        neo4j_candidates.append(
            Path(os.environ["LOCALAPPDATA"]) / "Programs" / "Neo4j" /
            "neo4j-community-5.21.0" / "bin" / "neo4j.bat"
        )
    neo4j_path = next((candidate for candidate in neo4j_candidates if candidate.is_file()), None)
    neo4j_admin = (
        neo4j_path.with_name("neo4j-admin.bat" if os.name == "nt" else "neo4j-admin")
        if neo4j_path else None
    )
    neo4j_env = os.environ.copy()
    if java_path and java_major and java_major.group(1) in {"17", "21"}:
        neo4j_env["JAVA_HOME"] = str(Path(java_path).parent.parent)
    neo4j_version, neo4j_version_error = (
        run_version([str(neo4j_admin), "--version"], env=neo4j_env)
        if neo4j_admin else (None, "")
    )
    check("Serveur Neo4j natif 5.21 installé",
          neo4j_version is not None and re.search(r"\b5\.21(?:\.0)?\b", neo4j_version) is not None,
          neo4j_version_error or "Exécuter lab install all pour installer Neo4j Community 5.21.0.",
          stage="run")

    if phase != "build":
        pg_isready = (
            Path(postgres_path).with_name("pg_isready.exe" if os.name == "nt" else "pg_isready")
            if postgres_path else None
        )
        native_pg_ready, native_pg_error = (
            run_version([str(pg_isready), "-h", "127.0.0.1", "-p", "5432"])
            if pg_isready and pg_isready.is_file() else (None, "")
        )
        check("PostgreSQL natif prêt sur localhost:5432 (pg_isready)",
              native_pg_ready is not None,
              native_pg_error or "Démarrer le service PostgreSQL 15 depuis Services Windows.",
              stage="run")

        for label, port, action in (
            ("Neo4j natif Bolt accessible sur localhost:7688", 7688,
             "Démarrer Neo4j : lancer bin\\neo4j.bat console dans son répertoire d'installation."),
        ):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=1.5):
                    available = True
            except OSError:
                available = False
            check(label, available, f"Vérifier le service natif et le port {port} ; action : {action}.", stage="run")

        docker_result, docker_error = (
            run_version([docker_path, "info", "--format", "{{.ServerVersion}}"])
            if docker_path and compose_version is not None else (None, "")
        )
        docker_available = docker_result is not None
        check("Docker Engine démarré", docker_available,
              docker_error or "Démarrer Docker Desktop puis relancer le diagnostic.", stage="run")

        running_services = set()
        running_error = ""
        if docker_available and compose_config_valid:
            running, running_error = run_version(
                [docker_path, "compose", "-f", str(compose_file), "ps", "--services", "--status", "running"],
                cwd=root,
            )
            running_services = set(running.splitlines()) if running else set()

        runtime_services = {
            "nginx", "postgres", "neo4j", "redis", "backend", "mailpit",
            "celery-worker", "celery-beat", "flower",
        }
        for service in sorted(runtime_services):
            check(f"Service Docker Compose : {service}",
                  service in running_services,
                  (f"Exécuter docker compose up --build -d {service} depuis {root}."
                   if not running_error else running_error[:1000]),
                  stage="run")

        postgres_ready, postgres_error = (
            run_version(
                [docker_path, "compose", "-f", str(compose_file), "exec", "-T", "postgres", "pg_isready"],
                cwd=root,
            )
            if docker_available and compose_config_valid and "postgres" in running_services
            else (None, "")
        )
        check("PostgreSQL accepte les connexions (pg_isready)",
              postgres_ready is not None,
              postgres_error or "Démarrer PostgreSQL : docker compose up -d postgres.",
              stage="run")

        tcp_checks = (
            ("PostgreSQL exposé sur localhost:5433", 5433, "docker compose up -d postgres"),
            ("Neo4j Bolt exposé sur localhost:7687", 7687, "docker compose up -d neo4j"),
            ("Redis exposé sur localhost:6379", 6379, "docker compose up -d redis"),
            ("API backend exposée sur localhost:8001", 8001, "docker compose up --build -d backend"),
            ("Mailpit Web exposé sur localhost:8025", 8025, "docker compose up -d mailpit"),
            ("Mailpit SMTP exposé sur localhost:1025", 1025, "docker compose up -d mailpit"),
            ("Flower exposé sur localhost:5555", 5555, "docker compose up --build -d flower"),
            ("Nginx exposé sur localhost:3000", 3000, "docker compose up -d nginx"),
            ("Serveur Angular exposé sur localhost:4200", 4200, "Exécuter npm start dans frontend"),
        )
        for label, port, action in tcp_checks:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=1.5):
                    available = True
            except OSError:
                available = False
            check(label, available, f"Vérifier le service et le port {port} ; action : {action}.", stage="run")

    git_path = shutil.which("git")
    check("Git (métadonnées de build twins_lab)", git_path is not None,
          "Installer Git pour générer les métadonnées de build.")
    if (root / "Makefile").is_file():
        make_path = shutil.which("make") or shutil.which("make.exe")
        check("GNU Make (commandes Makefile du projet)", make_path is not None,
              "Installer GNU Make (winget install ezwinports.make).")

    run_failures = sum(
        item["status"] == "FAIL" and item["required"] and item["stage"] == "run"
        for item in checks
    )
    build_failures = sum(
        item["status"] == "FAIL" and item["required"] and item["stage"] == "build"
        for item in checks
    )
    if getattr(args, "json", False):
        print(json.dumps({
            "project_root": str(root),
            "phase": phase,
            "checks": checks,
            "failures": failures,
            "build_failures": build_failures,
            "run_failures": run_failures,
        }, ensure_ascii=False))
    elif failures:
        print(
            f"\n[FAIL] {failures} prérequis obligatoire(s) manquant(s) ({phase})"
            f" : build={build_failures}, run={run_failures}."
        )
    else:
        print(f"\n[OK] Les prérequis obligatoires de twins_lab sont satisfaits ({phase}).")

    if failures:
        raise SystemExit(1)


def cmd_install(args, cfg, root):
    dashboard = LAB / "diagnos_dashboard.py"
    if args.dashboard and (args.target != "all" or args.check):
        if not dashboard.is_file():
            print(f"[FAIL] Script de diagnostic introuvable : {dashboard}")
            raise SystemExit(2)
        raise SystemExit(subprocess.call([sys.executable, str(dashboard), "--open"], cwd=LAB))

    if args.check:
        cmd_doctor(args, cfg, root)
        return

    if args.target != "all":
        print("Usage: lab install --check | lab install all")
        raise SystemExit(2)

    installer = LAB / "install_needed.ps1"
    if not installer.is_file():
        print(f"[FAIL] Script d'installation introuvable : {installer}")
        raise SystemExit(2)
    powershell = shutil.which("powershell.exe") or shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        print("[FAIL] PowerShell est requis pour lancer install_needed.ps1.")
        raise SystemExit(2)
    command = [
        powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(installer),
        "-TwinsRoot", str(root), "-InstallDocker", "-InstallDevTools",
    ]
    if args.skip_backend:
        command.append("-SkipBackend")
    if args.skip_frontend:
        command.append("-SkipFrontend")
    install_result = subprocess.call(command, cwd=LAB)
    if args.dashboard:
        if not dashboard.is_file():
            print(f"[FAIL] Script de diagnostic introuvable : {dashboard}")
            raise SystemExit(2)
        dashboard_result = subprocess.call([sys.executable, str(dashboard), "--open"], cwd=LAB)
        raise SystemExit(install_result or dashboard_result)
    raise SystemExit(install_result)


def cmd_init(args, cfg, root):
    m, mpath = load_component(args.component)
    print(f"[LAB] Initializing isolated environment for component '{args.component}'...")
    mod_dir = LAB / "modules" / args.component
    mod_dir.mkdir(parents=True, exist_ok=True)
    (mod_dir / "fixtures").mkdir(exist_ok=True)
    (mod_dir / "mocks").mkdir(exist_ok=True)
    
    fix_file = mod_dir / "fixtures" / "default.json"
    if not fix_file.exists():
        fix_file.write_text(json.dumps({"module": args.component, "status": "synthetic", "items": []}, indent=2), encoding="utf-8")
    
    print(f"[SUCCESS] Component '{args.component}' initialized successfully at {mod_dir}")


def cmd_build(args, cfg, root):
    m, mpath = load_component(args.component)
    print(f"[LAB] Building traceability manifest for component '{args.component}'...")
    
    backend_dir = root / "backend"
    module_backend_dir = backend_dir / m.get("backend", {}).get("dir", f"app/modules/{args.component}")
    if module_backend_dir.is_dir():
        py_exe = python_exe(cfg)
        py_files = list(module_backend_dir.rglob("*.py"))
        if py_files:
            print(f"[*] Vérification syntaxique de {len(py_files)} fichiers Python...")
            subprocess.run([py_exe, "-m", "py_compile", *[str(f) for f in py_files]], capture_output=True)

    try:
        commit_sha1 = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        branch = subprocess.run(["git", "-C", str(root), "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        status_output = subprocess.run(["git", "-C", str(root), "status", "--porcelain"], capture_output=True, text=True, check=True).stdout.strip()
        working_tree_clean = not bool(status_output)
    except Exception as e:
        print(f"  ! Warning: Git info could not be fully captured: {e}")
        commit_sha1 = "unknown"
        branch = "unknown"
        working_tree_clean = False
        status_output = ""

    timestamp_utc = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    short_sha = commit_sha1[:7] if commit_sha1 != "unknown" else "0000000"
    build_id = f"{args.component}-standalone-{timestamp_utc}-{short_sha}"
    
    BUILDS_DIR.mkdir(parents=True, exist_ok=True)
    build_dir = BUILDS_DIR / build_id
    build_dir.mkdir(parents=True, exist_ok=True)

    manifest = {
        "buildId": build_id,
        "component": args.component,
        "buildMode": "standalone-isolated",
        "commitSha1": commit_sha1,
        "branch": branch,
        "workingTreeClean": working_tree_clean,
        "modifiedFiles": status_output.splitlines() if status_output else [],
        "buildTimestampUtc": timestamp_utc,
        "pythonVersion": sys.version.split()[0],
        "manifestPath": str(mpath),
        "standalone": getattr(args, "standalone", False)
    }

    manifest_file = build_dir / "manifest.json"
    manifest_file.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    
    root_manifest_copy = BUILDS_DIR / f"{args.component}-build-manifest.json"
    root_manifest_copy.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    print(f"[SUCCESS] Build manifest generated at: {manifest_file}")
    print(f"          Build ID: {build_id} | Commit: {short_sha} | Clean: {working_tree_clean}")


def cmd_inspect(args, cfg, root):
    m, _ = load_component(args.component)
    name = component_name(m, args.component)
    if args.side in (None, "backend") and "backend" in m:
        out, inb = analyze_backend(root, m["backend"])
        show(f"[{name}] backend -> depends on (outbound)", out)
        show(f"[{name}] backend <- used by (inbound)", inb)
        print("\n    Tip: every outbound line is something to stub, mock or provide in the lab.")
    if args.side in (None, "frontend") and "frontend" in m:
        show(f"[{name}] frontend -> depends on (outbound)", analyze_frontend(root, m["frontend"]))


def compose_file(root: Path) -> Path:
    return root / "docker-compose.yml"


def cmd_up(args, cfg, root):
    m, _ = load_component(args.component)
    svcs = m.get("backend", {}).get("services", [])
    if not svcs:
        return print("No docker services declared for this component.")
    sys.exit(sh(["docker", "compose", "-f", str(compose_file(root)), "up", "-d", *svcs], root))


def cmd_down(args, cfg, root):
    m, _ = load_component(args.component)
    svcs = m.get("backend", {}).get("services", [])
    sys.exit(sh(["docker", "compose", "-f", str(compose_file(root)), "stop", *svcs], root))


def backend_env(m: dict) -> dict:
    env = os.environ.copy()
    env.update({k: str(v) for k, v in m.get("backend", {}).get("env", {}).items()})
    return env


def _extra_args(args) -> list[str]:
    """Arguments passés à pytest/jest ; retire le '--' de tête laissé par argparse.REMAINDER."""
    extra = list(args.extra or [])
    return extra[1:] if extra and extra[0] == "--" else extra


def _suite_env(cfg: dict) -> dict:
    """Environnement de la suite complète : [backend.env] de tous les composants + [tests.env] de lab.toml."""
    env = os.environ.copy()
    for path in manifests().values():
        m = tomllib.loads(path.read_text(encoding="utf-8"))
        env.update({k: str(v) for k, v in m.get("backend", {}).get("env", {}).items()})
    env.update({k: str(v) for k, v in cfg.get("tests", {}).get("env", {}).items()})
    return env


def backend_suite(cfg: dict, root: Path, unit: bool) -> tuple[list[str], list[str]]:
    """Chemins pytest de TOUTE la suite backend (indépendants des composants scannés).

    Ordre de résolution : lab.toml [tests] backend_paths, puis testpaths de
    backend/pyproject.toml, puis "tests". Avec --unit, les dossiers integration/ sont ignorés.
    """
    backend = root / "backend"
    paths = list(cfg.get("tests", {}).get("backend_paths", []))
    if not paths:
        pyproject = backend / "pyproject.toml"
        if pyproject.exists():
            try:
                ini = tomllib.loads(pyproject.read_text(encoding="utf-8")).get("tool", {}).get("pytest", {}).get("ini_options", {})
                declared = ini.get("testpaths", [])
                paths = declared.split() if isinstance(declared, str) else list(declared)
            except tomllib.TOMLDecodeError:
                pass
    if not paths:
        paths = ["tests"]
    paths = [t for t in paths if (backend / t).exists()]
    ignores = [f"--ignore={t}/integration" for t in paths if unit and (backend / t / "integration").is_dir()]
    return paths, ignores


def _test_all(args, cfg, root, extra: list[str]):
    """Une seule session pytest sur tout le backend + une seule session jest sur tout le frontend."""
    print("\n========================================================")
    print(" Executing the FULL test suite (backend + frontend)")
    print("========================================================")
    results: dict[str, int | None] = {}

    if args.side in (None, "backend"):
        paths, ignores = backend_suite(cfg, root, args.unit)
        if paths:
            rc = sh([python_exe(cfg), "-m", "pytest", *paths, *ignores, *extra], root / "backend", _suite_env(cfg))
            results["backend"] = 0 if rc == 5 else rc  # 5 = aucun test collecté
        else:
            print(f"  (Aucun dossier de tests backend trouvé dans {root / 'backend'})")
            results["backend"] = None

    if args.side in (None, "frontend"):
        if (root / "frontend").is_dir():
            results["frontend"] = sh([npx_exe(), "jest", "--passWithNoTests", *extra], root / "frontend")
        else:
            print(f"  (Dossier frontend introuvable : {root / 'frontend'})")
            results["frontend"] = None

    # Information : composants dont le dossier de tests déclaré n'existe pas (couverts quand même ci-dessus).
    unmapped = []
    for name, path in manifests().items():
        b = tomllib.loads(path.read_text(encoding="utf-8")).get("backend", {})
        if b and not any((root / "backend" / t).exists() for t in b.get("test_paths", [])):
            unmapped.append(name)

    print("\n========================================================")
    print(" Test summary")
    for side, rc in results.items():
        label = "skipped (nothing found)" if rc is None else ("OK" if rc == 0 else f"FAILED (exit code {rc})")
        print(f"   {side:<9} {label}")
    if unmapped and args.side in (None, "backend"):
        print(f" Composants sans dossier de tests dédié (inclus dans la suite globale) : {', '.join(unmapped)}")
    print("========================================================")
    sys.exit(next((rc for rc in results.values() if rc), 0))


def cmd_test(args, cfg, root):
    extra = _extra_args(args)
    if args.component == "all":
        return _test_all(args, cfg, root, extra)

    m, _ = load_component(args.component)
    print("\n========================================================")
    print(f" Executing tests for component: {args.component}")
    print("========================================================")
    rc = 0

    if args.side in (None, "backend") and "backend" in m:
        tests = m["backend"].get("test_paths", [])
        if args.unit:
            tests = [t for t in tests if "integration" not in t]
        existing = [t for t in tests if (root / "backend" / t).exists()]
        if existing:
            rc = sh([python_exe(cfg), "-m", "pytest", *existing, *extra], root / "backend", backend_env(m))
        else:
            print(f"  (No existing backend test paths found for {args.component})")

    if args.side in (None, "frontend") and "frontend" in m:
        tests = m["frontend"].get("test_paths", [])
        if tests:
            rc_front = sh([npx_exe(), "jest", "--passWithNoTests", *tests, *extra], root / "frontend")
            rc = rc or rc_front
        else:
            print(f"  (No frontend tests defined for {args.component})")

    sys.exit(0 if rc == 5 else rc)


def cmd_run(args, cfg, root):
    m, mpath = load_component(args.component)
    if args.side == "backend":
        b = m["backend"]
        env = backend_env(m)
        env["LAB_MANIFEST"] = str(mpath)
        env["PYTHONPATH"] = os.pathsep.join([str(root / "backend"), str(LAB), env.get("PYTHONPATH", "")])
        port = str(b.get("port", 8100))
        print(f"Lab API (Isolated): http://localhost:{port}/docs    routes: /__lab/routes")
        sys.exit(sh([python_exe(cfg), "-m", "uvicorn", "lab_harness:app", "--port", port, "--reload",
                    "--reload-dir", str(root / "backend" / "app"), "--reload-dir", str(LAB), *args.extra], root / "backend", env))
    
    fe = m["frontend"]
    port = str(m.get("backend", {}).get("port", 8100))
    GEN.mkdir(exist_ok=True)
    proxy = GEN / f"proxy.{component_name(m, args.component)}.json"
    proxy.write_text(json.dumps({"/api": {"target": f"http://localhost:{port}", "secure": False, "changeOrigin": True}}, indent=2))
    fport = str(fe.get("port", 4300))
    print(f"Frontend: http://localhost:{fport}{fe.get('route', '')}    (API proxied to :{port})")
    sys.exit(sh([npx_exe(), "ng", "serve", "--proxy-config", str(proxy), "--port", fport, *args.extra], root / "frontend"))


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(prog="lab", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="components declared in components/*.toml")
    
    p_scan = sub.add_parser("scan", help="scan backend/app/modules/ to auto-discover and register components")
    p_scan.add_argument("target", nargs="?", default="component")

    p_doctor = sub.add_parser("doctor", help="check tools, dependencies and runtime services")
    p_doctor.add_argument("--json", action="store_true", help="emit diagnostic results as JSON")
    p_doctor.add_argument("--phase", choices=["all", "build"], default="all",
                          help="check build prerequisites only, or include all runtime services")

    p_install = sub.add_parser("install", help="install prerequisites or verify the Twins Lab environment")
    p_install.add_argument("target", nargs="?", choices=["all"],
                           help="install all system tools and project dependencies")
    p_install.add_argument("--check", action="store_true", help="verify lab prerequisites without installing")
    p_install.add_argument("--dashboard", "--dahsboard", dest="dashboard", action="store_true",
                           help="generate and open the prerequisite dashboard")
    p_install.add_argument("--skip-backend", action="store_true")
    p_install.add_argument("--skip-frontend", action="store_true")

    p_init = sub.add_parser("init", help="initialize local fixtures, stubs, and isolated environment for a component")
    p_init.add_argument("component")

    p_build = sub.add_parser("build", help="build and generate a traceability manifest with Git SCM info")
    p_build.add_argument("component")
    p_build.add_argument("--standalone", action="store_true")

    p_inspect = sub.add_parser("inspect", help="what the component imports from / is imported by the rest of the app")
    p_inspect.add_argument("component")
    p_inspect.add_argument("--side", choices=["backend", "frontend"])

    p_up = sub.add_parser("up", help="start only the docker services the component needs")
    p_up.add_argument("component")

    p_down = sub.add_parser("down", help="stop only the docker services the component needs")
    p_down.add_argument("component")

    p_test = sub.add_parser("test", help="run only the component's tests")
    p_test.add_argument("component", default="all", nargs="?")
    p_test.add_argument("--side", choices=["backend", "frontend"])
    p_test.add_argument("--unit", action="store_true")

    p_run = sub.add_parser("run", help="launch the component alone")
    p_run.add_argument("component")
    p_run.add_argument("side", choices=["backend", "frontend"])

    cfg, root = load_cfg()
    # Tout ce qui suit "--" est transmis tel quel à pytest/jest/uvicorn/ng. On le sépare avant argparse :
    # argparse.REMAINDER avalerait sinon --side/--unit placés après le nom du composant.
    argv = sys.argv[1:]
    extra: list[str] = []
    if "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]
    args = ap.parse_args(argv)
    args.extra = extra
    
    cmds = {
        "list": cmd_list,
        "scan": cmd_scan,
        "doctor": cmd_doctor,
        "install": cmd_install,
        "init": cmd_init,
        "build": cmd_build,
        "inspect": cmd_inspect,
        "up": cmd_up,
        "down": cmd_down,
        "test": cmd_test,
        "run": cmd_run,
    }
    
    if args.cmd in cmds:
        cmds[args.cmd](args, cfg, root)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()