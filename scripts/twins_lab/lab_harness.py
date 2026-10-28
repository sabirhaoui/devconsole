"""FastAPI harness that mounts one component router from its TOML manifest."""
from __future__ import annotations

import importlib
import os
import tomllib
from pathlib import Path
from typing import Any

from fastapi import FastAPI

def _load_symbol(reference: str) -> Any:
    try:
        module_name, symbol_name = reference.split(":", 1)
    except ValueError as exc:
        raise ValueError(f"Expected 'module:attribute', got {reference!r}") from exc
    module = importlib.import_module(module_name)
    try:
        return getattr(module, symbol_name)
    except AttributeError as exc:
        raise ImportError(f"{reference!r} does not exist") from exc


def _apply_patches(patches: dict[str, str]) -> None:
    for original_ref, replacement_ref in patches.items():
        try:
            module_name, attribute = original_ref.split(":", 1)
        except ValueError as exc:
            raise ValueError(f"Expected 'module:attribute' in patch target, got {original_ref!r}") from exc
        module = importlib.import_module(module_name)
        replacement = _load_symbol(replacement_ref)
        if not hasattr(module, attribute):
            raise ImportError(f"Patch target {original_ref!r} does not exist")
        setattr(module, attribute, replacement)


def _load_manifest() -> tuple[dict[str, Any], Path]:
    manifest_path = os.environ.get("LAB_MANIFEST")
    if not manifest_path:
        raise RuntimeError("LAB_MANIFEST is required; start this server with `lab run <component> backend`.")
    path = Path(manifest_path).expanduser().resolve()
    try:
        manifest = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise RuntimeError(f"Unable to load component manifest {path}: {exc}") from exc
    if not isinstance(manifest.get("backend"), dict):
        raise RuntimeError(f"Component manifest {path} has no [backend] section.")
    return manifest, path


def create_app() -> FastAPI:
    manifest, manifest_path = _load_manifest()
    backend = manifest["backend"]
    component = manifest.get("component", {}).get("name", manifest_path.stem)
    router_ref = backend.get("router")
    if not router_ref:
        package = backend.get("package")
        if not package:
            raise RuntimeError(f"Component {component!r} must declare backend.router or backend.package.")
        router_ref = f"{package}.router:router"

    _apply_patches(backend.get("patches", {}))
    router = _load_symbol(router_ref)
    app = FastAPI(
        title=f"Twins Lab - {component}",
        description="Isolated component API; shared application startup hooks are not executed.",
        version="lab",
    )
    app.include_router(router)

    from lab_stubs import fake_user

    try:
        get_current_user = _load_symbol("app.modules.identity.dependencies:get_current_user")
    except (ImportError, AttributeError):
        get_current_user = None

    if get_current_user is not None:
        app.dependency_overrides[get_current_user] = fake_user

    for original_ref, replacement_ref in backend.get("overrides", {}).items():
        original = _load_symbol(original_ref)
        replacement = _load_symbol(replacement_ref)
        app.dependency_overrides[original] = replacement

    @app.get("/health", tags=["Lab"])
    @app.get("/api/health", tags=["Lab"], include_in_schema=False)
    def health() -> dict[str, str]:
        return {"status": "isolated", "component": component}

    @app.get("/__lab/routes", tags=["Lab"])
    def routes() -> list[dict[str, Any]]:
        result = []
        for path, operations in app.openapi()["paths"].items():
            for method, operation in operations.items():
                result.append(
                    {
                        "path": path,
                        "methods": [method.upper()],
                        "name": operation.get("operationId", ""),
                    }
                )
        return result

    print(f"[LAB] Loaded component: {component} ({router_ref})")
    print(f"[LAB] Manifest: {manifest_path}")
    operation_methods = {"get", "post", "put", "patch", "delete", "options", "head", "trace"}
    component_operations = sum(
        sum(method in operation_methods for method in operations)
        for path, operations in app.openapi()["paths"].items()
        if path not in {"/health", "/api/health", "/__lab/routes"}
    )
    print(f"[LAB] Mounted {component_operations} component operations.")
    print("[LAB] Shared application startup hooks are disabled.")
    return app


app = create_app()
