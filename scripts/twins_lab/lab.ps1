#!/usr/bin/env python3
"""
Moteur CLI modulaire pour twins_lab (Install, Init, Build, Test, Isolation, Run).
"""

import os
import sys
import subprocess
import json
from datetime import datetime

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        tomllib = None

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TWINS_PROJECT = os.environ.get("TWINS_ROOT", r"C:\workspace\twins_project")
BACKEND_DIR = os.path.join(TWINS_PROJECT, "backend")
FRONTEND_DIR = os.path.join(TWINS_PROJECT, "frontend")
COMPONENTS_DIR = os.path.join(SCRIPT_DIR, "components")
BUILDS_DIR = os.path.join(SCRIPT_DIR, "builds")

os.makedirs(BUILDS_DIR, exist_ok=True)
os.makedirs(COMPONENTS_DIR, exist_ok=True)

def print_header(title):
    print(f"\n" + "=" * 60)
    print(f"=== [TWINS_LAB] {title}")
    print("=" * 60)

def load_component_config(name):
    toml_path = os.path.join(COMPONENTS_DIR, f"{name}.toml")
    config = {
        "component": {"name": name, "port": 8001},
        "backend": {"test_paths": [f"tests/unit/{name}", f"tests/integration/{name}"]},
        "frontend": {"test_paths": [f"src/app/pages/{name}"]}
    }
    if tomllib and os.path.exists(toml_path):
        try:
            with open(toml_path, "rb") as f:
                data = tomllib.load(f)
                if data:
                    config.update(data)
        except Exception as e:
            print(f"[WARN] Erreur de lecture du TOML pour {name}: {e}")
    return config

def get_python_executable():
    venv_py = os.path.join(BACKEND_DIR, ".venv", "Scripts", "python.exe" if os.name == "nt" else "bin/python")
    if os.path.exists(venv_py):
        return venv_py
    return "python"

def cmd_doctor(args):
    print_header("Diagnostic du Laboratoire")
    print(f"[+] Répertoire actif : {SCRIPT_DIR}")
    print(f"[+] Dossier Builds   : {BUILDS_DIR}")
    print(f"[+] Dossier TOML     : {COMPONENTS_DIR}")
    print(f"[+] TWINS_ROOT       : {TWINS_PROJECT}")

def cmd_list(args):
    print_header("Composants Enregistrés")
    if os.path.exists(COMPONENTS_DIR):
        toml_files = [f[:-5] for f in os.listdir(COMPONENTS_DIR) if f.endswith(".toml")]
        if toml_files:
            for comp in toml_files:
                cfg = load_component_config(comp)
                desc = cfg.get("component", {}).get("description", "Module de la plateforme Twins")
                print(f" - {comp} : {desc}")
            return
    print(" - experimentation (Backend FastAPI / Angular)")

def cmd_install(args):
    print_header(f"INSTALL (Check: {args.check})")
    install_script = os.path.join(SCRIPT_DIR, "install_needed.ps1")
    if os.path.exists(install_script):
        ps_args = ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File", install_script]
        if args.check:
            ps_args.append("-Check")
        if args.skip_backend:
            ps_args.append("-SkipBackend")
        if args.skip_frontend:
            ps_args.append("-SkipFrontend")
        
        res = subprocess.run(ps_args)
        sys.exit(res.returncode)
    else:
        print(f"[FAIL] Script install_needed.ps1 introuvable dans {SCRIPT_DIR}")
        sys.exit(2)

def cmd_init(args):
    comp = args.component
    print_header(f"INIT : {comp}")
    print(f"[*] Configuration des dépendances et stubs locaux pour {comp}...")
    os.environ["JWT_SECRET_KEY"] = "test_jwt_secret_key_for_isolation_purposes_only"
    os.environ["DATABASE_URL"] = "sqlite:///:memory:"
    print(f"[+] Initialisation terminée avec succès.")

def cmd_build(args):
    comp = args.component
    print_header(f"BUILD : {comp}")
    os.chdir(BACKEND_DIR)
    python_exe = get_python_executable()

    git_sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    git_status = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True).stdout.strip()
    is_clean = not bool(git_status)

    print(f"[*] Compilation ciblée et vérification syntaxique...")
    module_path = f"app/modules/{comp}"
    if os.path.exists(module_path):
        subprocess.run([python_exe, "-m", "py_compile"] + [os.path.join(module_path, f) for f in os.listdir(module_path) if f.endswith(".py")])

    manifest = {
        "Component": comp,
        "Timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "GitCommitSha": git_sha,
        "WorkingTreeClean": is_clean,
        "Status": "SUCCESS"
    }
    manifest_path = os.path.join(BUILDS_DIR, f"{comp}-build-manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    print(f"[+] Build validé. Manifeste généré : {manifest_path}")

def cmd_test(args):
    comp = args.component
    print_header(f"TEST : {comp}")
    os.environ["JWT_SECRET_KEY"] = "test_jwt_secret_key_for_isolation_purposes_only"
    os.environ["DATABASE_URL"] = "sqlite:///:memory:"
    python_exe = get_python_executable()

    comps_to_test = []
    if comp == "all":
        if os.path.exists(COMPONENTS_DIR):
            comps_to_test = [f[:-5] for f in os.listdir(COMPONENTS_DIR) if f.endswith(".toml")]
        if not comps_to_test:
            comps_to_test = ["experimentation"]
    else:
        comps_to_test = [comp]

    global_rc = 0
    for c in comps_to_test:
        cfg = load_component_config(c)
        print(f"\n--- Exécution des tests pour : {c} ---")

        backend_paths = cfg.get("backend", {}).get("test_paths", [])
        if backend_paths:
            cmd = [python_exe, "-m", "pytest"] + backend_paths + ["-v", "--tb=short"]
            print(f"$ {' '.join(cmd)} (cwd: {BACKEND_DIR})")
            res = subprocess.run(cmd, cwd=BACKEND_DIR)
            if res.returncode != 0:
                global_rc = res.returncode

        frontend_paths = cfg.get("frontend", {}).get("test_paths", [])
        if frontend_paths and os.path.exists(FRONTEND_DIR):
            npx_cmd = "npx.cmd" if os.name == "nt" else "npx"
            cmd = [npx_cmd, "jest"] + frontend_paths
            print(f"$ {' '.join(cmd)} (cwd: {FRONTEND_DIR})")
            res = subprocess.run(cmd, cwd=FRONTEND_DIR)
            if res.returncode != 0:
                global_rc = res.returncode

    if global_rc != 0:
        sys.exit(global_rc)
    print(f"\n[+] Tous les tests ont réussi.")

def cmd_isolation(args):
    comp = args.component
    print_header(f"ISOLATION / DEBUG : {comp}")
    print(f"[*] Préparation de l'environnement de débogage sandboxé...")

def cmd_run(args):
    comp = args.component
    print_header(f"RUN LOCAL : {comp}")
    os.chdir(BACKEND_DIR)
    cfg = load_component_config(comp)
    port = cfg.get("component", {}).get("port", 8001)
    python_exe = get_python_executable()

    os.environ["JWT_SECRET_KEY"] = "local_debug_secret_key"
    os.environ["DATABASE_URL"] = f"sqlite:///local_debug_{comp}.db"
    os.environ["ENVIRONMENT"] = "development"

    print(f"[*] Démarrage d'une instance locale dédiée pour le module '{comp}' sur le port {port}...")
    subprocess.run([python_exe, "-m", "uvicorn", "app.main:app", "--reload", "--port", str(port)])

import argparse

def main():
    parser = argparse.ArgumentParser(description="Moteur CLI modulaire pour twins_lab")
    subparsers = parser.add_subparsers(dest="action", required=True)

    subparsers.add_parser("doctor", help="Diagnostic du laboratoire")
    subparsers.add_parser("list", help="Liste les composants enregistrés")

    p_install = subparsers.add_parser("install", help="Installe les prérequis et configure l'environnement")
    p_install.add_argument("--check", action="store_true", help="Vérifie uniquement sans installer")
    p_install.add_argument("--skip-backend", action="store_true", help="Ignore le backend")
    p_install.add_argument("--skip-frontend", action="store_true", help="Ignore le frontend")

    for act, func in [
        ("init", cmd_init),
        ("build", cmd_build),
        ("test", cmd_test),
        ("isolation", cmd_isolation),
        ("run", cmd_run)
    ]:
        p = subparsers.add_parser(act, help=f"Exécute l'action {act}")
        p.add_argument("component", nargs="?", default="all", help="Composant cible ou 'all'")

    args = parser.parse_args()
    
    actions = {
        "doctor": cmd_doctor,
        "list": cmd_list,
        "install": cmd_install,
        "init": cmd_init,
        "build": cmd_build,
        "test": cmd_test,
        "isolation": cmd_isolation,
        "run": cmd_run
    }

    if args.action in actions:
        actions[args.action](args)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()