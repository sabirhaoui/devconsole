"""
Runner FastAPI autonome et générique pour les modules backend du twins_project.
Instancie un serveur uvicorn isolé ne chargeant QUE le router du module ciblé,
avec court-circuitage de la base de données (SQL/Neo4j) et de l'authentification réelle.
"""

import argparse
import os
import sys
import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# Ajouter le chemin backend au sys.path
BACKEND_DIR = r"C:\workspace\twins_project\backend"
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

# Registre des modules backend connus et de leurs routeurs dans app.modules
MODULE_ROUTERS = {
    "experimentation": "app.modules.experimentation.router:router",
    "alerts": "app.modules.alerts.router:router",
    "assystan": "app.modules.assystan.router:router",
    "connectors": "app.modules.connectors.router:router",
    "dashboards": "app.modules.dashboards.router:router",
    "diff": "app.modules.diff.router:router",
    "document_graph": "app.modules.document_graph.router:router",
    "entity_mappings": "app.modules.entity_mappings.router:router",
    "identity": "app.modules.identity.router:router",
    "packages": "app.modules.packages.router:router",
    "quality": "app.modules.quality.router:router",
    "retrieval": "app.modules.retrieval.router:router",
    "risk_hub": "app.modules.risk_hub.router:router",
    "studio": "app.modules.studio.router:router",
    "studio_v2": "app.modules.studio_v2.router:router",
    "twin_builders": "app.modules.twin_builders.router:router",
    "twin_canonical": "app.modules.twin_canonical.router:router",
    "twin_health": "app.modules.twin_health.router:router",
    "unifier_package": "app.modules.unifier_package.router:router",
}

def create_isolated_app(module_name: str) -> FastAPI:
    """Crée une instance FastAPI épurée pour un module spécifique."""
    app = FastAPI(
        title=f"TWINS Lab — Standalone Backend [{module_name.upper()}]",
        description=f"Instance locale isolée et de débogage pour le module {module_name}.",
        version="0.2.0-standalone",
    )

    # CORS souple pour le laboratoire et le frontend autonome (Angular)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # Surcharge des dépendances d'authentification pour débogage local
    try:
        from app.modules.identity.dependencies import require_any_permission
        app.dependency_overrides[require_any_permission] = lambda *args, **kwargs: lambda: {"sub": "standalone-dev", "role": "admin"}
    except Exception:
        pass

    # Dynamic import du router ciblé
    if module_name not in MODULE_ROUTERS:
        raise ValueError(f"Module inconnu '{module_name}'. Modules supportés : {list(MODULE_ROUTERS.keys())}")

    router_path = MODULE_ROUTERS[module_name]
    module_path, router_var = router_path.split(":")
    
    import importlib
    mod = importlib.import_module(module_path)
    router = getattr(mod, router_var)

    # Montage du routeur sous /api/v1/{module_name}
    prefix = f"/api/v1/{module_name}"
    app.include_router(router, prefix=prefix)

    @app.get("/api/health")
    def health():
        return {
            "status": "isolated",
            "module": module_name,
            "mounted_prefix": prefix,
            "isolation": "SQL and Neo4j connections bypassed"
        }

    return app

def main():
    parser = argparse.ArgumentParser(description="Runner Standalone de Module FastAPI")
    parser.add_argument("--module", required=True, help="Nom du module (ex: experimentation, studio, assystan, alerts...)")
    parser.add_argument("--port", type=int, default=8000, help="Port d'écoute HTTP")
    parser.add_argument("--host", default="127.0.0.1", help="Hôte d'écoute")
    args = parser.parse_args()

    print(f"============================================================")
    print(f"  TWINS LAB STANDALONE BACKEND : {args.module.upper()}")
    print(f"============================================================")
    print(f" - URL d'accès : http://{args.host}:{args.port}")
    print(f" - Swagger Docs: http://{args.host}:{args.port}/docs")
    print(f" - Mode       : Isolé & Debug")
    print(f"============================================================\n")

    app = create_isolated_app(args.module)
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")

if __name__ == "__main__":
    main()