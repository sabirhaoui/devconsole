<#
.SYNOPSIS
    Installe tout ce qu'il faut pour travailler sur twins_project avec twins_lab.
.DESCRIPTION
    1. Prerequis systeme via winget, uniquement s'ils manquent :
         Python >= 3.11, Node.js LTS (npm/npx), Git, et Docker Desktop avec -InstallDocker.
    2. Delegue a `lab.py install` : .venv du backend, pip install -r requirements*.txt,
       npm ci dans frontend/ si node_modules est absent, variable TWINS_ROOT.
    3. Avec -Init : `lab.py init <composant>` pour chaque composant (fixtures, stubs, .env isole).
    -Check ne modifie rien : il rapporte l'etat et ce qui serait installe.
.EXAMPLE
    .\install_needed.ps1 -Check
    .\install_needed.ps1 -TwinsRoot C:\workspace\twins_project -Init
    .\install_needed.ps1 -InstallDocker
#>
[CmdletBinding()]
param(
    [string]$TwinsRoot = "",
    [switch]$Check,
    [switch]$Force,
    [switch]$Init,
    [switch]$InstallDocker,
    [switch]$SkipBackend,
    [switch]$SkipFrontend
)

# Les commandes natives ecrivent sur stderr : on controle les codes de sortie nous-memes.
$ErrorActionPreference = "Continue"
$LabPy = Join-Path $PSScriptRoot "lab.py"
$Missing = New-Object System.Collections.Generic.List[string]

function Write-Step { param([string]$Msg) Write-Host "`n== $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK  ] $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

function Update-SessionPath {
    # Recharge le PATH Machine+User : un outil tout juste installe devient visible sans rouvrir le terminal.
    $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ";"
}

function Find-Python311 {
    $candidates = @()
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        foreach ($v in "3.13", "3.12", "3.11") { $candidates += @{ Exe = $launcher.Source; Pre = @("-$v") } }
    }
    foreach ($n in "python", "python3") {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { $candidates += @{ Exe = $c.Source; Pre = @() } }
    }
    # Emplacements par defaut des installeurs (au cas ou le PATH n'est pas a jour)
    $globs = @()
    if ($env:LOCALAPPDATA) { $globs += (Join-Path $env:LOCALAPPDATA "Programs\Python\Python3*\python.exe") }
    if ($env:ProgramFiles) { $globs += (Join-Path $env:ProgramFiles "Python3*\python.exe") }
    foreach ($g in $globs) {
        Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Sort-Object FullName -Descending |
            ForEach-Object { $candidates += @{ Exe = $_.FullName; Pre = @() } }
    }
    foreach ($c in $candidates) {
        try {
            # Les alias du Microsoft Store (WindowsApps) echouent ici : ils sont donc ecartes
            $ok = & $c.Exe @($c.Pre) -c "import sys; print(int(sys.version_info >= (3, 11)))" 2>$null
            if ($LASTEXITCODE -eq 0 -and "$ok".Trim() -eq "1") { return $c }
        } catch { }
    }
    return $null
}

function Get-NodeMajor {
    $n = Get-Command node -ErrorAction SilentlyContinue
    if (-not $n) { return 0 }
    $v = & $n.Source --version 2>$null
    if ("$v" -match "v(\d+)") { return [int]$Matches[1] }
    return 0
}

function Find-Docker {
    $d = Get-Command docker -ErrorAction SilentlyContinue
    if ($d) { return $d.Source }
    $default = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    if (Test-Path -LiteralPath $default) { return $default }
    return $null
}

function Install-WithWinget {
    param([string]$Id, [string]$Label)
    if ($Check) {
        Write-Warn2 "$Label manquant : serait installe via winget ($Id)"
        $Missing.Add($Label)
        return $false
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Fail "$Label manquant et winget est introuvable : installez-le manuellement (App Installer du Microsoft Store)."
        $Missing.Add($Label)
        return $false
    }
    Write-Host "    -> winget install $Id" -ForegroundColor DarkGray
    & winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements
    # 0 = installe ; -1978335189 (0x8A15002B) = deja installe / aucune mise a jour applicable
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Fail "L'installation de $Label a echoue (code $LASTEXITCODE)."
        $Missing.Add($Label)
        return $false
    }
    Update-SessionPath
    return $true
}

if (-not (Test-Path -LiteralPath $LabPy -PathType Leaf)) {
    Write-Fail "lab.py introuvable : $LabPy"
    exit 2
}

# ---------------------------------------------------------------- 1. prerequis systeme
Write-Step "1. Prerequis systeme$(if ($Check) { ' (verification seule)' })"
Update-SessionPath

$py = Find-Python311
if ($py) {
    Write-Ok "Python >= 3.11 : $($py.Exe) $($py.Pre -join ' ')"
} elseif (Install-WithWinget -Id "Python.Python.3.12" -Label "Python 3.12") {
    $py = Find-Python311
    if ($py) { Write-Ok "Python installe : $($py.Exe)" } else { Write-Fail "Python installe mais introuvable : rouvrez le terminal et relancez."; $Missing.Add("Python (PATH)") }
}

if ((Get-NodeMajor) -ge 18) {
    Write-Ok "Node.js $(& node --version) (npm/npx inclus)"
} elseif (Install-WithWinget -Id "OpenJS.NodeJS.LTS" -Label "Node.js LTS") {
    if ((Get-NodeMajor) -ge 18) { Write-Ok "Node.js installe : $(& node --version)" } else { Write-Fail "Node.js installe mais introuvable : rouvrez le terminal et relancez."; $Missing.Add("Node.js (PATH)") }
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok "Git present"
} else {
    [void](Install-WithWinget -Id "Git.Git" -Label "Git")
}

$docker = Find-Docker
if ($docker) {
    Write-Ok "Docker : $docker"
} elseif ($InstallDocker) {
    Write-Warn2 "Docker Desktop : installation demandee (droits administrateur, redemarrage possible)."
    [void](Install-WithWinget -Id "Docker.DockerDesktop" -Label "Docker Desktop")
} else {
    Write-Warn2 "Docker Desktop absent : requis seulement pour 'lab up' et les tests d'integration (-InstallDocker pour l'installer)."
}

if (-not $py) {
    Write-Host ""
    Write-Fail "Python >= 3.11 est requis pour continuer."
    exit 1
}

# ------------------------------------------------------------- 2. projet twins (lab.py)
if ($TwinsRoot) { $env:TWINS_ROOT = $TwinsRoot }

$labArgs = @("install")
if ($Check)        { $labArgs += "--check" }
if ($Force)        { $labArgs += "--force" }
if ($SkipBackend)  { $labArgs += "--skip-backend" }
if ($SkipFrontend) { $labArgs += "--skip-frontend" }

Write-Step "2. Projet twins : venv, requirements Python, npm ci, TWINS_ROOT"
& $py.Exe @($py.Pre) $LabPy @labArgs
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    Write-Fail "lab.py install a signale des erreurs (code $rc)."
    exit $rc
}

# ------------------------------------------------------------------- 3. init composants
if ($Init -and -not $Check) {
    Write-Step "3. Initialisation des composants (fixtures, stubs, .env isole)"
    $componentsDir = Join-Path $PSScriptRoot "components"
    foreach ($f in (Get-ChildItem -Path $componentsDir -Filter *.toml -ErrorAction SilentlyContinue)) {
        & $py.Exe @($py.Pre) $LabPy init $f.BaseName
        if ($LASTEXITCODE -ne 0) { Write-Warn2 "init $($f.BaseName) : code $LASTEXITCODE" }
    }
}

Write-Host ""
if ($Missing.Count -gt 0) {
    Write-Warn2 "Elements manquants : $($Missing -join ', ')"
} elseif ($Check) {
    Write-Host "[+] Verification terminee : relancez sans -Check pour installer ce qui manque (voir WARN ci-dessus)." -ForegroundColor Green
} else {
    Write-Host "[+] Environnement twins_lab pret. Essayez : python lab.py test all" -ForegroundColor Green
}
if ($env:TWINS_ROOT) { Write-Host "    TWINS_ROOT = $($env:TWINS_ROOT)" -ForegroundColor DarkGray }
exit 0