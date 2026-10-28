#!/usr/bin/env python3
"""Generate a standalone HTML dashboard from the Twins Lab prerequisite checks."""

from __future__ import annotations

import argparse
import html
import json
import subprocess
import sys
import webbrowser
from datetime import datetime
from pathlib import Path

LAB = Path(__file__).resolve().parent
LAB_SCRIPT = LAB / "lab.py"


def load_diagnostics() -> dict:
    try:
        result = subprocess.run(
            [sys.executable, str(LAB_SCRIPT), "doctor", "--json"],
            cwd=LAB,
            capture_output=True,
            text=True,
            timeout=420,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Unable to run the Twins Lab diagnostic: {exc}") from exc

    if result.returncode not in (0, 1):
        message = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"Diagnostic command failed ({result.returncode}): {message}")

    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Diagnostic returned invalid JSON: {exc}") from exc
    if not isinstance(report, dict) or not isinstance(report.get("checks"), list):
        raise RuntimeError("Diagnostic JSON is missing its checks list.")
    return report


def dashboard_html(report: dict) -> str:
    checks = report["checks"]
    passed = sum(check["status"] == "OK" for check in checks)
    failed = sum(check["status"] == "FAIL" and check["required"] for check in checks)
    warnings = sum(check["status"] == "WARN" or (check["status"] == "FAIL" and not check["required"])
                   for check in checks)
    build_failed = report.get("build_failures", failed)
    run_failed = report.get("run_failures", 0)
    readiness = "Prêt pour le build et le run" if failed == 0 else "Bloqué : prérequis manquants"
    readiness_class = "ready" if failed == 0 else "blocked"

    rows = []
    for check in checks:
        status = check["status"]
        details = check.get("details") or ("Disponible" if status == "OK" else "")
        stage = "Build" if check.get("stage", "build") == "build" else "Run"
        rows.append(
            "<tr>"
            f"<td>{html.escape(str(check['label']))}</td>"
            f"<td><span class=\"status {status.lower()}\">{html.escape(status)}</span></td>"
            f"<td>{stage}</td>"
            f"<td>{'Required' if check['required'] else 'Optional'}</td>"
            f"<td>{html.escape(str(details))}</td>"
            "</tr>"
        )

    return f"""<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Diagnostic des prérequis Twins Lab</title>
  <style>
    :root {{ color-scheme: light; font-family: "Segoe UI", sans-serif; color: #172033; background: #f3f6fb; }}
    body {{ margin: 0; padding: 2rem; }}
    main {{ max-width: 1200px; margin: auto; }}
    header, .card, .table-wrap {{ background: white; border: 1px solid #dce3ed; border-radius: 12px; }}
    header {{ padding: 1.5rem 1.75rem; }}
    h1 {{ margin: 0 0 .4rem; font-size: 1.6rem; }}
    .root {{ color: #596579; overflow-wrap: anywhere; }}
    .readiness {{ display: inline-block; margin-top: 1rem; padding: .5rem .8rem; border-radius: 999px; font-weight: 700; }}
    .ready {{ color: #11643a; background: #dff5e8; }}
    .blocked {{ color: #982c2c; background: #fde6e6; }}
    .summary {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 1rem; margin: 1rem 0; }}
    .card {{ padding: 1rem 1.2rem; }}
    .card strong {{ display: block; font-size: 1.5rem; }}
    .card span {{ color: #596579; }}
    .table-wrap {{ overflow-x: auto; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ padding: .85rem 1rem; text-align: left; vertical-align: top; border-bottom: 1px solid #e8edf4; }}
    th {{ background: #f8faff; font-size: .85rem; }}
    tr:last-child td {{ border-bottom: 0; }}
    .status {{ display: inline-block; min-width: 3.5rem; text-align: center; padding: .25rem .45rem; border-radius: 6px; font-weight: 700; }}
    .status.ok {{ color: #11643a; background: #dff5e8; }}
    .status.fail {{ color: #982c2c; background: #fde6e6; }}
    .status.warn {{ color: #775300; background: #fff1c2; }}
    footer {{ margin-top: 1rem; color: #596579; font-size: .9rem; }}
    @media (max-width: 700px) {{ body {{ padding: 1rem; }} .summary {{ grid-template-columns: 1fr; }} }}
  </style>
</head>
<body>
  <main>
    <header>
      <h1>Diagnostic des prérequis Twins Lab</h1>
      <div class="root">Projet : {html.escape(str(report.get("project_root", "Inconnu")))}</div>
      <div class="readiness {readiness_class}">{readiness}</div>
    </header>
    <section class="summary" aria-label="Résumé du diagnostic">
      <div class="card"><strong>{passed}</strong><span>Contrôles réussis</span></div>
      <div class="card"><strong>{build_failed}</strong><span>Prérequis de build manquants</span></div>
      <div class="card"><strong>{run_failed}</strong><span>Prérequis de run manquants</span></div>
      <div class="card"><strong>{warnings}</strong><span>Avertissements facultatifs</span></div>
    </section>
    <section class="table-wrap">
      <table>
        <thead><tr><th>Prérequis / service</th><th>Statut</th><th>Étape</th><th>Importance</th><th>Détail / action</th></tr></thead>
        <tbody>{''.join(rows)}</tbody>
      </table>
    </section>
    <footer>Généré le {datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")}. Relancer le diagnostic pour actualiser.</footer>
  </main>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path.cwd() / "twins-lab-prerequisites.html",
        help="HTML report path (default: ./twins-lab-prerequisites.html)",
    )
    parser.add_argument("--open", action="store_true", help="open the generated dashboard in a browser")
    args = parser.parse_args()

    try:
        report = load_diagnostics()
        page = dashboard_html(report)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(page, encoding="utf-8")
    except (OSError, RuntimeError) as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 2

    failed = int(report.get("failures", 0))
    print(f"Dashboard saved to: {args.output.resolve()}")
    print(f"État : {'bloqué' if failed else 'prêt'} ; {failed} prérequis obligatoire(s) manquant(s).")
    if args.open:
        webbrowser.open(args.output.resolve().as_uri())
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
