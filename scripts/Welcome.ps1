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
        @('ubuntu <action> [arguments]', 'Authentification et operations distantes'),
        @('trail logs [service]', 'Afficher et suivre les journaux Compose'),
        @('trail local start | status | stop', 'Piloter la collecte locale en JSONL'),
        @('trail production start | status | stop', 'Piloter la collecte des logs de production via SSH')
    )) {
        Write-Host ('  {0,-38} {1}' -f $row[0], $row[1]) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  AVEVA  /  lab aveva <action>' -ForegroundColor Cyan
    foreach ($row in @(
        @('doctor', 'Verifier le dossier et les lanceurs'),
        @('run', 'Ouvrir AVEVA Unified Engineering'),
        @('status | stop', 'Consulter ou arreter AVEVA'),
        @('logs', 'Consulter les journaux via le lanceur configure'),
        @('log [--lines N] [--follow]', 'Lire le journal de demarrage Unified Engineering')
    )) {
        Write-Host ('  {0,-56} {1}' -f ("lab aveva " + $row[0]), $row[1]) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  A2 CONNECTOR  /  lab a2-connector <action>' -ForegroundColor Cyan
    foreach ($row in @(
        @('doctor', 'Verifier le dossier et les lanceurs'),
        @('restore | build | lint', 'Restaurer les dependances, compiler ou verifier le code'),
        @('test | smoke', 'Executer les tests ou verifier les echanges'),
        @('test-integrity', 'Verifier l''integrite IFC'),
        @('inspect-ifc ''--'' <fichier.ifc>', 'Afficher la taille et le SHA-256 du fichier IFC'),
        @('test-api', 'Tester l''API IFC, la concurrence et la reprise'),
        @('publish | test-published', 'Publier le connecteur ou tester le livrable'),
        @('run | run-published', 'Demarrer le connecteur ou le livrable publie'),
        @('status | health | logs | stop', 'Consulter l''etat, la sante, les journaux ou arreter')
    )) {
        Write-Host ('  {0,-56} {1}' -f ("lab a2-connector " + $row[0]), $row[1]) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  ARAS  /  lab aras <action>' -ForegroundColor Cyan
    foreach ($row in @(
        @('doctor', 'Verifier le dossier et les lanceurs'),
        @('build', 'Preparer le package Aras'),
        @('run', 'Demarrer Aras'),
        @('test | status | logs | stop', 'Tester ou piloter l''environnement Aras')
    )) {
        Write-Host ('  {0,-56} {1}' -f ("lab aras " + $row[0]), $row[1]) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  Toutes les options : lab <projet> <action> --help' -ForegroundColor DarkGray
    Write-Host '  Effacer l''ecran : cls  |  Reafficher ce menu : dev help' -ForegroundColor DarkGray
    Write-Host ''
}
