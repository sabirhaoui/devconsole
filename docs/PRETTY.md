# Apparence DevConsole

## Branche Git et themes

L'invite affiche le nom de la branche du depot courant, y compris dans ses
sous-dossiers. Hors depot, aucune branche n'est affichee. Sans Oh My Posh,
une invite native coloree assure ce comportement ; en HEAD detache, elle
affiche `detached:<commit>`.

```powershell
dev theme list
dev theme set ocean
dev theme set forest
dev theme set sunset
dev theme set mono
```

Le changement est immediat et memorise dans `data/appearance.json`.
Les palettes sont definies dans `config/themes.json` et utilisees pour
generer le theme Oh My Posh dans `data/`. Avec l'invite native, elles changent
la couleur du chemin et de la branche.

Dans PowerShell 7, depuis la racine du depot :

```powershell
.\Set-DevConsolePretty.ps1 -Install
```

Installe Oh My Posh via WinGet si absent. Verifie dans HKCU et HKLM
la famille exacte `3270 Nerd Font Cond (TrueType)` et le fichier associe.
Si elle manque, installer `3270NerdFont-Condensed.ttf`, puis recommencer.
Configure le profil Terminal `PowerShell` avec `3270 Nerd Font Cond`, taille 11.
Une sauvegarde `.bak` est creee avant modification ; la recopier vers
settings.json pour restaurer. Les commentaires et la mise en forme JSON sont
normalises. `-WhatIf` affiche les modifications prevues.
Pour un autre Terminal ou profil : `-SettingsPath <fichier> -ProfileName <nom>`.
Sans `-Install`, aucun logiciel n'est installe.

Fermer toutes les fenetres Terminal, relancer PowerShell et verifier le rendu :
le controle registre/JSON ne garantit pas la resolution visuelle de la police.

```powershell
.\Start-DevConsole.ps1 -SkipTests -SkipInventory
```

Le theme local affiche dossier, branche Git, modifications, duree des commandes
longues et code d'erreur. PSReadLine configure l'edition Windows et les suggestions
d'historique si disponibles. Le demarrage n'installe rien et conserve l'invite
native si Oh My Posh est absent. `-NoPretty` desactive cette initialisation.
Le module ne modifie pas le profil PowerShell utilisateur.

References : [Oh My Posh](https://ohmyposh.dev/docs/installation/prompt),
[WinGet](https://learn.microsoft.com/windows/package-manager/winget/#install-winget).
