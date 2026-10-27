import argparse
import sys
import os
import json
from http.server import HTTPServer, SimpleHTTPRequestHandler

def run_module_server(module_name, port):
    print(f"[HARNESS] Démarrage du serveur mock/standalone pour le module '{module_name}' sur http://localhost:{port}")
    print("[HARNESS] Isolation active : Aucune connexion SQL ou Neo4j requise.")
    
    class IsolatedHandler(SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/api/health":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "isolated", "module": module_name}).encode("utf-8"))
            else:
                super().do_GET()

    server_address = ("", port)
    httpd = HTTPServer(server_address, IsolatedHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[HARNESS] Arrêt de l'instance locale.")
        httpd.server_close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["init", "build", "test", "run", "list", "inspect", "doctor"])
    parser.add_argument("--module", default="experimentation")
    parser.add_argument("--port", type=int, default=8080)
    
    args = parser.parse_args()
    
    if args.action == "run":
        run_module_server(args.module, args.port)
    elif args.action == "init":
        print(f"[HARNESS] Initialisation des stubs et fixtures pour {args.module}...")
    elif args.action == "build":
        print(f"[HARNESS] Génération du manifeste de build pour {args.module}...")
    else:
        print(f"[HARNESS] Action {args.action} exécutée.")