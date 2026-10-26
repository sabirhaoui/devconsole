
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Workspace = 'C:\workspace',
    [string]$ProjectName = 'DevConsole',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Join-Path $Workspace $ProjectName
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

$Directories = @(
    'config',
    'scripts',
    'tests',
    'docs',
    'reports',
    'data'
)

# ---------------------------------------------------------------------------
# Fichiers du projet
# ---------------------------------------------------------------------------

$Files = [ordered]@{}

$Files['config\config.example.json'] = @'
{
  "name": "DevConsole",
  "version": "1.0.0",
  "workspace": "C:\\workspace",
  "history": {
    "enabled": true,
    "file": "data\\history.jsonl",
    "maxEntries": 1000
  },
  "aliases": {
    "gs": "git status",
    "gl": "git log --oneline -10",
    "py": "python",
    "ll": "Get-ChildItem"
  },
  "tools": {
    "git": "git",
    "python": "python",
    "node": "node",
    "npm": "npm",
    "podman": "podman",
    "docker": "docker",
    "kubectl": "kubectl",
    "terraform": "terraform"
  }
}
'@

$Files['dev.ps1'] = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config\config.example.json'
$HistoryPath = Join-Path $Root 'data\history.jsonl'

function Write-DevInfo {
    param([string]$Message)
    Write-Host "[DevConsole] $Message" -ForegroundColor Cyan
}

function Write-DevError {
    param([string]$Message)
    Write-Host "[Erreur] $Message" -ForegroundColor Red
}

function Get-DevConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration introuvable : $ConfigPath"
    }
    Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}

function Add-DevHistory {
    param([string]$Text)

    try {
        $config = Get-DevConfig
        if (-not $config.history.enabled) { return }

        $parent = Split-Path -Parent $HistoryPath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force |
                Out-Null
        }

        $entry = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            command   = $Text
            directory = (Get-Location).Path
        }

        $json = $entry | ConvertTo-Json -Compress
        Add-Content -LiteralPath $HistoryPath -Value $json -Encoding UTF8
    }
    catch {
        Write-Verbose "Historique indisponible : $($_.Exception.Message)"
    }
}

function Show-DevHelp {
    @'
DevConsole - aide
-----------------
dev help                 Affiche cette aide
dev version              Affiche la version
dev status               Affiche l'environnement
dev config               Affiche la configuration
dev aliases              Affiche les alias documentés
dev history              Affiche les dernières commandes DevConsole
dev init                 Lance l'inventaire des outils
dev run <commande>       Exécute une commande externe

Exemples :
  .\dev.ps1 status
  .\dev.ps1 run git --version
  .\dev.ps1 run python --version

Le script ne modifie pas automatiquement les installations de logiciels.
'@ | Write-Host
}

function Show-DevStatus {
    Write-Host "Projet       : DevConsole"
    Write-Host "Version      : 1.0.0"
    Write-Host "Répertoire   : $Root"
    Write-Host "PowerShell   : $($PSVersionTable.PSVersion)"
    Write-Host "Exécutable   : $((Get-Process -Id $PID).Path)"
    Write-Host "Répertoire courant : $((Get-Location).Path)"

    foreach ($tool in @('git', 'python', 'node', 'npm', 'podman', 'docker')) {
        $found = Get-Command $tool -ErrorAction SilentlyContinue
        if ($found) {
            Write-Host ("{0,-12}: {1}" -f $tool, $found.Source)
        }
        else {
            Write-Host ("{0,-12}: absent du PATH" -f $tool)
        }
    }
}

function Invoke-DevExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [string[]]$Args = @()
    )

    $resolved = Get-Command $Executable -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Write-DevError "Commande introuvable : $Executable"
        return 127
    }

    Add-DevHistory (($Executable + ' ' + ($Args -join ' ')).Trim())

    & $resolved.Source @Args
    if ($null -ne $LASTEXITCODE) {
        return [int]$LASTEXITCODE
    }
    return 0
}

switch ($Command.ToLowerInvariant()) {
    'help' {
        Show-DevHelp
        break
    }
    '--help' {
        Show-DevHelp
        break
    }
    '-h' {
        Show-DevHelp
        break
    }
    'version' {
        Write-Host 'DevConsole 1.0.0'
        break
    }
    'status' {
        Show-DevStatus
        break
    }
    'config' {
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            Write-Host
        break
    }
    'aliases' {
        $config = Get-DevConfig
        $config.aliases.PSObject.Properties |
            ForEach-Object {
                Write-Host ("{0,-12} -> {1}" -f $_.Name, $_.Value)
            }
        break
    }
    'history' {
        if (Test-Path -LiteralPath $HistoryPath) {
            Get-Content -LiteralPath $HistoryPath -Tail 20 |
                ForEach-Object { Write-Host $_ }
        }
        else {
            Write-Host 'Aucun historique disponible.'
        }
        break
    }
    'init' {
        & (Join-Path $Root 'scripts\Initialize-DevConsole.ps1')
        break
    }
    'run' {
        if ($Arguments.Count -lt 1) {
            Write-DevError 'Usage : dev run <commande> [arguments...]'
            break
        }
        $exitCode = Invoke-DevExternalCommand `
            -Executable $Arguments[0] `
            -Args @($Arguments | Select-Object -Skip 1)
        exit $exitCode
    }
    default {
        Write-DevError "Sous-commande inconnue : $Command"
        Write-Host 'Utilise : .\dev.ps1 help'
        exit 2
    }
}
'@

$Files['Start-DevConsole.ps1'] = @'
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$SkipInventory
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Workspace = Split-Path -Parent $Root

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '             DEVCONSOLE' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Projet : $Root"
Write-Host "Workspace : $Workspace"
Write-Host ''

if (-not $SkipTests) {
    $testScript = Join-Path $Root 'tests\Run-Tests.ps1'
    if (Test-Path -LiteralPath $testScript) {
        Write-Host '[1/2] Tests du projet' -ForegroundColor Yellow
        & $testScript
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Warning 'Les tests ont signalé une erreur.'
        }
    }
}

if (-not $SkipInventory) {
    $inventoryScript = Join-Path $Root 'scripts\Initialize-DevConsole.ps1'
    if (Test-Path -LiteralPath $inventoryScript) {
        Write-Host ''
        Write-Host '[2/2] Inventaire de l’environnement' -ForegroundColor Yellow
        & $inventoryScript -Workspace $Workspace
    }
}

Set-Location -LiteralPath $Workspace

Write-Host ''
Write-Host 'DevConsole est prêt. Invite PowerShell native activée.' -ForegroundColor Green
Write-Host "Tape : & '$Root\dev.ps1' help"
Write-Host ''
# Ne pas lancer de boucle Read-Host : le terminal reste interactif
# grâce à -NoExit dans le raccourci.
'@

$Files['install.ps1'] = @'
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'DevConsole')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Source = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path -LiteralPath $Source)) {
    throw "Source introuvable : $Source"
}

if ($PSCmdlet.ShouldProcess($InstallDirectory, 'Installer DevConsole')) {
    New-Item -ItemType Directory -Path $InstallDirectory -Force |
        Out-Null

    Copy-Item -Path (Join-Path $Source '*') `
        -Destination $InstallDirectory -Recurse -Force

    Write-Host "DevConsole installé dans : $InstallDirectory" -ForegroundColor Green
    Write-Host 'Pour le lancer :'
    Write-Host "  & '$InstallDirectory\dev.ps1' help"
}
'@

$Files['uninstall.ps1'] = @'
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'DevConsole')
)

Write-Warning "Cette opération supprime uniquement le répertoire d'installation indiqué."
Write-Warning 'Elle ne supprime ni les outils externes ni le projet source.'

if (-not (Test-Path -LiteralPath $InstallDirectory)) {
    Write-Host "Rien à supprimer : $InstallDirectory"
    return
}

if ($PSCmdlet.ShouldProcess($InstallDirectory, 'Supprimer l’installation DevConsole')) {
    Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
    Write-Host 'Installation supprimée.' -ForegroundColor Green
}
'@

$Files['scripts\Initialize-DevConsole.ps1'] = @'
[CmdletBinding()]
param(
    [string]$Workspace = 'C:\workspace'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$Root = Split-Path -Parent $PSScriptRoot
$ReportDirectory = Join-Path $Root 'reports'
$ReportPath = Join-Path $ReportDirectory 'init-report.json'

New-Item -ItemType Directory -Path $ReportDirectory -Force |
    Out-Null

$ToolNames = @(
    'pwsh', 'powershell', 'git', 'gh', 'ssh', 'curl', 'jq',
    'python', 'py', 'pip', 'uv', 'poetry', 'pipx',
    'java', 'javac', 'mvn', 'gradle',
    'node', 'npm', 'pnpm', 'yarn', 'tsc', 'ng',
    'docker', 'podman', 'kubectl', 'helm', 'kind', 'minikube',
    'gitlab-runner', 'terraform', 'ansible', 'make', 'cmake',
    'dotnet', 'go', 'cargo', 'code'
)

$Tools = foreach ($name in $ToolNames) {
    $command = Get-Command $name -ErrorAction SilentlyContinue |
        Select-Object -First 1

    [pscustomobject]@{
        Name      = $name
        Installed = [bool]$command
        Path      = if ($command) { $command.Source } else { $null }
        Version   = $null
    }
}

$Markers = @(
    '.git',
    '.gitlab-ci.yml',
    'Dockerfile',
    'compose.yaml',
    'docker-compose.yml',
    'pyproject.toml',
    'requirements.txt',
    'package.json',
    'pom.xml',
    'build.gradle',
    'build.gradle.kts'
)

$ProjectMarkers = foreach ($marker in $Markers) {
    $path = Join-Path $Workspace $marker
    [pscustomobject]@{
        Marker  = $marker
        Present = Test-Path -LiteralPath $path
        Path    = $path
    }
}

$report = [ordered]@{
    generatedAt   = (Get-Date).ToString('o')
    computerName  = $env:COMPUTERNAME
    userName      = $env:USERNAME
    workspace     = $Workspace
    powershell    = $PSVersionTable.PSVersion.ToString()
    tools         = @($Tools)
    projectMarkers = @($ProjectMarkers)
    note          = 'Inventaire en lecture seule : aucun logiciel installé ou supprimé.'
}

$report | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $ReportPath -Encoding UTF8

$installedCount = @($Tools | Where-Object Installed).Count
$missingCount = @($Tools | Where-Object { -not $_.Installed }).Count
$markerCount = @($ProjectMarkers | Where-Object Present).Count

Write-Host ''
Write-Host '===== INVENTAIRE DEVCONSOLE =====' -ForegroundColor Cyan
Write-Host "Workspace            : $Workspace"
Write-Host "Outils détectés      : $installedCount"
Write-Host "Outils absents       : $missingCount"
Write-Host "Marqueurs de projet  : $markerCount / $($Markers.Count)"
Write-Host "Rapport JSON         : $ReportPath"
Write-Host ''
Write-Host 'Outils présents :' -ForegroundColor Green

$Tools |
    Where-Object Installed |
    ForEach-Object {
        Write-Host ("  + {0} : {1}" -f $_.Name, $_.Path)
    }

Write-Host ''
Write-Host 'Outils absents du PATH :' -ForegroundColor Yellow

$Tools |
    Where-Object { -not $_.Installed } |
    ForEach-Object {
        Write-Host ("  - {0}" -f $_.Name)
    }

Write-Host ''
Write-Host 'Aucune installation ni suppression effectuée.'
'@

$Files['tests\Run-Tests.ps1'] = @'
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Failures = 0

function Assert-Condition {
    param(
        [string]$Name,
        [bool]$Condition
    )

    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        $script:Failures++
    }
}

$RequiredFiles = @(
    'dev.ps1',
    'Start-DevConsole.ps1',
    'install.ps1',
    'uninstall.ps1',
    'config\config.example.json',
    'scripts\Initialize-DevConsole.ps1',
    'README.md',
    'docs\ARCHITECTURE.md'
)

foreach ($relativePath in $RequiredFiles) {
    Assert-Condition $relativePath (
        Test-Path -LiteralPath (Join-Path $Root $relativePath)
    )
}

$configPath = Join-Path $Root 'config\config.example.json'
try {
    $null = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-Condition 'JSON de configuration valide' $true
}
catch {
    Assert-Condition 'JSON de configuration valide' $false
}

$PowerShellFiles = @(
    'dev.ps1',
    'Start-DevConsole.ps1',
    'install.ps1',
    'uninstall.ps1',
    'scripts\Initialize-DevConsole.ps1',
    'tests\Run-Tests.ps1'
)

foreach ($relativePath in $PowerShellFiles) {
    $path = Join-Path $Root $relativePath
    if (-not (Test-Path -LiteralPath $path)) { continue }

    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    )

    Assert-Condition "Syntaxe PowerShell : $relativePath" ($errors.Count -eq 0)

    foreach ($parseError in $errors) {
        Write-Host ("  Ligne {0}: {1}" -f
            $parseError.Extent.StartLineNumber,
            $parseError.Message) -ForegroundColor Red
    }
}

Write-Host ''
if ($Failures -eq 0) {
    Write-Host 'Tous les tests sont passés.' -ForegroundColor Green
    exit 0
}

Write-Host "$Failures test(s) en échec." -ForegroundColor Red
exit 1
'@

$Files['docs\ARCHITECTURE.md'] = @'
# Architecture DevConsole

## Objectif

DevConsole fournit une entrée PowerShell unifiée pour les commandes de
développement, un inventaire local et des tests de cohérence.

## Structure

- `dev.ps1` : interface en ligne de commande.
- `Start-DevConsole.ps1` : séquence de démarrage du terminal.
- `config/config.example.json` : configuration et alias documentés.
- `scripts/Initialize-DevConsole.ps1` : inventaire en lecture seule.
- `tests/Run-Tests.ps1` : contrôles de structure, JSON et syntaxe.
- `reports/` : rapports générés.
- `data/` : historique JSONL.

## Sécurité

- Aucun outil n'est installé automatiquement.
- Aucun secret n'est stocké dans la configuration.
- Les scripts d'installation et de désinstallation sont séparés.
- La désinstallation ne doit être lancée qu'après vérification du chemin cible.
- L'inventaire n'effectue aucune modification système.

## Compatibilité

Les scripts ciblent Windows PowerShell 5.1 et PowerShell 7 lorsque
les commandes utilisées sont disponibles dans les deux environnements.
'@

$Files['README.md'] = @'
# DevConsole

Interface PowerShell pour faciliter les opérations de développement sous Windows.

## Prérequis

- Windows 10 ou Windows 11
- Windows PowerShell 5.1 ou PowerShell 7
- Les outils externes sont facultatifs et détectés via le `PATH`

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

Le rapport est écrit dans `reports\init-report.json`. L'inventaire ne
tente pas d'installer les outils manquants.

## Démarrage du terminal

```powershell
.\Start-DevConsole.ps1
```

Pour un raccourci Windows, cible recommandée :

```text
C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "C:\workspace\DevConsole\Start-DevConsole.ps1"
```

Définir « Démarrer dans » sur `C:\workspace`.

## Reconstruction

Depuis `C:\workspace` :

```powershell
.\Rebuild-DevConsole.ps1 -WhatIf
.\Rebuild-DevConsole.ps1
```

Pour remplacer les fichiers générés existants, utiliser explicitement `-Force`.
'@

$Files['.gitignore'] = @'
# Données locales
data/*
!data/.gitkeep

# Rapports générés
reports/*
!reports/.gitkeep

# Secrets et configuration locale
config/config.local.json
.env
.env.*

# Python
__pycache__/
.venv/
venv/

# Node
node_modules/

# IDE
.vscode/
.idea/

# Logs
*.log
'@

$Files['data\.gitkeep'] = ''
$Files['reports\.gitkeep'] = ''

# ---------------------------------------------------------------------------
# Création contrôlée
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ProjectRoot)) {
    if ($PSCmdlet.ShouldProcess($ProjectRoot, 'Créer le répertoire du projet')) {
        New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    }
}

foreach ($directory in $Directories) {
    $path = Join-Path $ProjectRoot $directory

    if (-not (Test-Path -LiteralPath $path)) {
        if ($PSCmdlet.ShouldProcess($path, 'Créer le répertoire')) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

$Written = [System.Collections.Generic.List[string]]::new()
$Skipped = [System.Collections.Generic.List[string]]::new()

foreach ($relativePath in $Files.Keys) {
    $target = Join-Path $ProjectRoot $relativePath
    $parent = Split-Path -Parent $target

    if (-not (Test-Path -LiteralPath $parent)) {
        if ($PSCmdlet.ShouldProcess($parent, 'Créer le répertoire parent')) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }

    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        $Skipped.Add($relativePath)
        Write-Host "[CONSERVÉ] $relativePath (utiliser -Force pour remplacer)" `
            -ForegroundColor Yellow
        continue
    }

    if ($PSCmdlet.ShouldProcess($target, 'Écrire le fichier')) {
        [System.IO.File]::WriteAllText(
            $target,
            [string]$Files[$relativePath],
            $Utf8Bom
        )
        $Written.Add($relativePath)
        Write-Host "[ÉCRIT] $relativePath" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Vérifications finales
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '===== VÉRIFICATION DE LA RECONSTRUCTION =====' -ForegroundColor Cyan
Write-Host "Racine : $ProjectRoot"

$Missing = @(
    foreach ($relativePath in $Files.Keys) {
        $target = Join-Path $ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $target)) {
            $relativePath
        }
    }
)

if ($Missing.Count -gt 0) {
    Write-Host 'Fichiers manquants :' -ForegroundColor Red
    $Missing | ForEach-Object { Write-Host "  - $_" }
    throw 'La reconstruction est incomplète. Consulte les erreurs ci-dessus.'
}

$configFile = Join-Path $ProjectRoot 'config\config.example.json'
try {
    $null = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Write-Host '[PASS] JSON de configuration valide' -ForegroundColor Green
}
catch {
    Write-Host "[FAIL] JSON invalide : $($_.Exception.Message)" -ForegroundColor Red
    throw
}

$syntaxFiles = @(
    'dev.ps1',
    'Start-DevConsole.ps1',
    'install.ps1',
    'uninstall.ps1',
    'scripts\Initialize-DevConsole.ps1',
    'tests\Run-Tests.ps1'
)

$syntaxFailures = 0

foreach ($relativePath in $syntaxFiles) {
    $path = Join-Path $ProjectRoot $relativePath
    $tokens = $null
    $errors = $null

    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors.Count -eq 0) {
        Write-Host "[PASS] Syntaxe : $relativePath" -ForegroundColor Green
    }
    else {
        $syntaxFailures += $errors.Count
        Write-Host "[FAIL] Syntaxe : $relativePath" -ForegroundColor Red
        foreach ($parseError in $errors) {
            Write-Host ("  Ligne {0} : {1}" -f
                $parseError.Extent.StartLineNumber,
                $parseError.Message)
        }
    }
}

Write-Host ''
Write-Host "Fichiers écrits     : $($Written.Count)"
Write-Host "Fichiers conservés  : $($Skipped.Count)"
Write-Host "Fichiers attendus   : $($Files.Count)"

if ($syntaxFailures -gt 0) {
    throw "$syntaxFailures erreur(s) de syntaxe PowerShell détectée(s)."
}

Write-Host ''
Write-Host 'Reconstruction terminée.' -ForegroundColor Green
Write-Host 'Étape suivante : exécuter les tests du projet.'
Write-Host "  & '$ProjectRoot\tests\Run-Tests.ps1'"
