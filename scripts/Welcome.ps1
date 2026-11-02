function Show-DevConsoleWelcome {
    param([string]$ProjectRoot, [string]$Workspace)
    Write-Host ''
    Write-Host '  DEVCONSOLE  /  DEVELOPPEMENT' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host "  Projet     $ProjectRoot" -ForegroundColor Gray
    Write-Host "  Workspace  $Workspace" -ForegroundColor Gray
    Write-Host ''
    Write-Host '  COMMANDES DEVCONSOLE' -ForegroundColor Cyan
    foreach ($row in @(
        @('dev help', 'Afficher cette aide'),
        @('dev version', 'Version de DevConsole'),
        @('dev status', 'Environnement et outils'),
        @('dev config', 'Configuration'),
        @('dev aliases', 'Alias documentes'),
        @('dev history', 'Historique des commandes'),
        @('dev init', 'Inventaire des outils'),
        @('dev pretty -Install', 'Installer Oh My Posh et configurer Terminal'),
        @('dev theme list', 'Lister les themes disponibles'),
        @('dev theme set <nom>', 'Activer et memoriser un theme'),
        @('dev run <commande> [arguments]', 'Executer une commande externe'),
        @('dev db-dump', 'Telecharger le dump distant configure'),
        @('dev lab <projet> <action>', 'Acceder au laboratoire')
    )) {
        Write-Host ('  {0,-38} {1}' -f $row[0], $row[1]) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  TWINS LAB  /  lab project_twin <action>' -ForegroundColor Cyan
    foreach ($row in @(
        @('list', 'Lister les composants'),
        @('scan component', 'Decouvrir les composants'),
        @('doctor', 'Diagnostiquer outils et services'),
        @('install --check', 'Verifier les prerequis'),
        @('install all', 'Installer les prerequis'),
        @('init <composant>', 'Initialiser un composant'),
        @('build <composant>', 'Compiler un composant'),
        @('inspect <composant>', 'Analyser les dependances'),
        @('up <composant>', 'Demarrer les services necessaires'),
        @('down <composant>', 'Arreter les services necessaires'),
        @('test all | <composant>', 'Executer les tests'),
        @('assemble build', 'Construire la solution complete'),
        @('run all | <composant> <cote>', 'Lancer le projet ou un composant'),
        @('ubuntu <action> [arguments]', 'Authentification et operations distantes')
    )) {
        Write-Host ('  {0,-38} {1}' -f $row[0], $row[1]) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  Toutes les options : lab project_twin <action> --help' -ForegroundColor DarkGray
    Write-Host '  Effacer l''ecran : cls  |  Reafficher ce menu : dev help' -ForegroundColor DarkGray
    Write-Host ''
}
