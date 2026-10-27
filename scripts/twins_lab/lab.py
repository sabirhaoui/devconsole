#!/usr/bin/env python3
"""twins_lab - isolate, inspect, test, build, init and launch ONE component of twins_project.

Commands
  list                          components declared in components/*.toml
  doctor                        check the toolchain and the repo path
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
    cfg = tomllib.loads((LAB / "lab.toml").read_text(encoding="utf-8"))
    root = Path(os.environ.get("TWINS_ROOT") or cfg["project"]["root"]).expanduser()
    return cfg, root


def manifests() -> dict[str, Path]:
    return {p.stem: p for p in sorted((LAB / "components").glob("*.toml"))}


def load_component(name: str) -> tuple[dict, Path]:
    ms = manifests()
    if name not in ms:
        sys.exit(f"Unknown component '{name}'. Known: {', '.join(ms) or '(none)'}")
    return tomllib.loads(ms[name].read_text(encoding="utf-8")), ms[name]

def python_exe(cfg: dict) -> str:
    # Priorité absolue à l'environnement virtuel du backend s'il existe
    root = Path(os.environ.get("TWINS_ROOT") or cfg["project"]["root"]).expanduser()
    venv_py = root / "backend" / ".venv" / "Scripts" / "python.exe"
    if venv_py.exists():
        return str(venv_py)
    return cfg["project"].get("python") or sys.executable


def sh(cmd: list[str], cwd: Path, env: dict | None = None) -> int:
    print(f"\n$ {' '.join(map(str, cmd))}\n  (cwd: {cwd})\n")
    try:
        return subprocess.call(cmd, cwd=cwd, env=env)
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
    for name, path in manifests().items():
        m = tomllib.loads(path.read_text(encoding="utf-8"))
        sides = [s for s in ("backend", "frontend") if s in m]
        print(f"{name:<20} [{'+'.join(sides)}]    {m.get('description', '')}")


def cmd_doctor(args, cfg, root):
    def check(label, ok, hint=""):
        print(f"    [{'OK' if ok else '!!'}] {label}" + ("" if ok else f"    -> {hint}"))

    print(f"project root: {root}")
    check("repo found", (root / "backend").is_dir() and (root / "frontend").is_dir(), "set project.root in lab.toml or $env:TWINS_ROOT")
    check(f"python {sys.version.split()[0]}", sys.version_info >= (3, 11), "need >= 3.11")
    py = python_exe(cfg)
    for mod in ("fastapi", "uvicorn", "pytest"):
        r = subprocess.run([py, "-c", f"import {mod}"], capture_output=True)
        check(f"{mod} importable with '{py}'", r.returncode == 0, f"point project.python at the backend venv ({root}\\backend\\.venv\\Scripts\\python.exe)")
    check("docker", shutil.which("docker") is not None, "needed only for `up`/integration tests")
    check("node/npx", shutil.which("npx") is not None, "needed only for the frontend side")
    check("frontend/node_modules", (root / "frontend" / "node_modules").is_dir(), "run `npm ci` in frontend/")


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
    
    # Compilation syntaxique ciblée et sécurisée (évite l'erreur d'argument invalide wildcard)
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
    
    # Copie du manifeste également à la racine des builds pour un accès rapide
    root_manifest_copy = BUILDS_DIR / f"{args.component}-build-manifest.json"
    root_manifest_copy.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    print(f"[SUCCESS] Build manifest generated at: {manifest_file}")
    print(f"          Build ID: {build_id} | Commit: {short_sha} | Clean: {working_tree_clean}")


def cmd_inspect(args, cfg, root):
    m, _ = load_component(args.component)
    if args.side in (None, "backend") and "backend" in m:
        out, inb = analyze_backend(root, m["backend"])
        show(f"[{m['name']}] backend -> depends on (outbound)", out)
        show(f"[{m['name']}] backend <- used by (inbound)", inb)
        print("\n    Tip: every outbound line is something to stub, mock or provide in the lab.")
    if args.side in (None, "frontend") and "frontend" in m:
        show(f"[{m['name']}] frontend -> depends on (outbound)", analyze_frontend(root, m["frontend"]))


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


def cmd_test(args, cfg, root):
    comps = list(manifests().keys()) if args.component == "all" else [args.component]
    global_rc = 0

    for comp_name in comps:
        print(f"\n========================================================")
        print(f" Executing tests for component: {comp_name}")
        print(f"========================================================")
        
        # Charge le composant courant
        try:
            m, _ = load_component(comp_name)
        except SystemExit:
            print(f"Skipping unknown or invalid component: {comp_name}")
            continue

        rc = 0
        if args.side in (None, "backend") and "backend" in m:
            tests = m["backend"]["tests"]
            if args.unit:
                tests = [t for t in tests if "integration" not in t]
            if tests:
                rc |= sh([python_exe(cfg), "-m", "pytest", *tests, *args.extra], root / "backend", backend_env(m))
            else:
                print(f"  (No backend tests defined for {comp_name})")
                
        if args.side in (None, "frontend") and "frontend" in m:
            if "dir" in m["frontend"]:
                npx = shutil.which("npx") or "npx"
                rel = Path(m["frontend"]["dir"]).relative_to("frontend").as_posix()
                rc |= sh([npx, "jest", rel, *args.extra], root / "frontend")
        
        global_rc |= rc

    if args.component == "all":
        print(f"\n========================================================")
        print(f" Global test execution finished with exit code: {global_rc}")
        print(f"========================================================")
    
    sys.exit(global_rc)

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
    proxy = GEN / f"proxy.{m['name']}.json"
    proxy.write_text(json.dumps({"/api": {"target": f"http://localhost:{port}", "secure": False, "changeOrigin": True}}, indent=2))
    fport = str(fe.get("port", 4300))
    print(f"Frontend: http://localhost:{fport}{fe.get('route', '')}    (API proxied to :{port})")
    npx = shutil.which("npx") or "npx"
    sys.exit(sh([npx, "ng", "serve", "--proxy-config", str(proxy), "--port", fport, *args.extra], root / "frontend"))


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(prog="lab", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    sub.add_parser("doctor").set_defaults(fn=cmd_doctor)
    
    p_init = sub.add_parser("init")
    p_init.add_argument("component")
    p_init.set_defaults(fn=cmd_init)

    p_build = sub.add_parser("build")
    p_build.add_argument("component")
    p_build.add_argument("--standalone", action="store_true", help="build in isolated standalone mode")
    p_build.set_defaults(fn=cmd_build)

    for name, fn in (("inspect", cmd_inspect), ("test", cmd_test), ("up", cmd_up), ("down", cmd_down)):
            p = sub.add_parser(name)
            if name == "test":
                p.add_argument("component", nargs="?", default="all", help="Component name or 'all' for everything")
            else:
                p.add_argument("component")
                
            if name in ("inspect", "test"):
                p.add_argument("--side", choices=["backend", "frontend"])
            if name == "test":
                p.add_argument("--unit", action="store_true", help="skip integration tests (no DB needed)")
            p.set_defaults(fn=fn)
            
    p = sub.add_parser("run")
    p.add_argument("component")
    p.add_argument("side", choices=["backend", "frontend"])
    p.set_defaults(fn=cmd_run)

    args, extra = ap.parse_known_args()
    args.extra = [e for e in extra if e != "--"]
    cfg, root = load_cfg()
    args.fn(args, cfg, root)


if __name__ == "__main__":
    main()