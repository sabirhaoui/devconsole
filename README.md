# DevConsole

Interface PowerShell pour faciliter les opÃ©rations de dÃ©veloppement sous Windows.

## PrÃ©requis

- Windows 10 ou Windows 11
- Windows PowerShell 5.1 ou PowerShell 7
- Les outils externes sont facultatifs et dÃ©tectÃ©s via le `PATH`

## Commandes

Depuis la racine du projet :

```powershell
.\dev.ps1 help
.\dev.ps1 version
.\dev.ps1 status
.\dev.ps1 config
.\dev.ps1 aliases
.\dev.ps1 history
.\dev.ps1 init
.\dev.ps1 run git --version
```

## Tests

```powershell
.\tests\Run-Tests.ps1
```

## Inventaire

```powershell
.\scripts\Initialize-DevConsole.ps1 -Workspace 'C:\workspace'
```

Le rapport est Ã©crit dans `reports\init-report.json`. L'inventaire ne
tente pas d'installer les outils manquants.

## DÃ©marrage du terminal

```powershell
.\Start-DevConsole.ps1
```

Pour un raccourci Windows, cible recommandÃ©e :

```text
C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "C:\workspace\DevConsole\Start-DevConsole.ps1"
```

DÃ©finir Â« DÃ©marrer dans Â» sur `C:\workspace`.

## Reconstruction

Depuis `C:\workspace` :

```powershell
.\Rebuild-DevConsole.ps1 -WhatIf
.\Rebuild-DevConsole.ps1
```

Pour remplacer les fichiers gÃ©nÃ©rÃ©s existants, utiliser explicitement `-Force`.