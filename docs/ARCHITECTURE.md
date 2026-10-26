# Architecture DevConsole

## Objectif

DevConsole fournit une entrÃ©e PowerShell unifiÃ©e pour les commandes de
dÃ©veloppement, un inventaire local et des tests de cohÃ©rence.

## Structure

- `dev.ps1` : interface en ligne de commande.
- `Start-DevConsole.ps1` : sÃ©quence de dÃ©marrage du terminal.
- `config/config.example.json` : configuration et alias documentÃ©s.
- `scripts/Initialize-DevConsole.ps1` : inventaire en lecture seule.
- `tests/Run-Tests.ps1` : contrÃ´les de structure, JSON et syntaxe.
- `reports/` : rapports gÃ©nÃ©rÃ©s.
- `data/` : historique JSONL.

## SÃ©curitÃ©

- Aucun outil n'est installÃ© automatiquement.
- Aucun secret n'est stockÃ© dans la configuration.
- Les scripts d'installation et de dÃ©sinstallation sont sÃ©parÃ©s.
- La dÃ©sinstallation ne doit Ãªtre lancÃ©e qu'aprÃ¨s vÃ©rification du chemin cible.
- L'inventaire n'effectue aucune modification systÃ¨me.

## CompatibilitÃ©

Les scripts ciblent Windows PowerShell 5.1 et PowerShell 7 lorsque
les commandes utilisÃ©es sont disponibles dans les deux environnements.