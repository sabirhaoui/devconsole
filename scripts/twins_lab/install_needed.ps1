<#
.SYNOPSIS
    Installe, configure et prépare l'environnement complet pour le build et le run des composants Twins.
.DESCRIPTION
    Installs Python, Node.js, Git, Make, Docker Desktop, backend requirements,
    frontend dependencies, and creates .env from .env.example when missing.
    PostgreSQL, Neo4j, Redis and the other runtime services are provided by Docker Compose.
.EXAMPLE
    .\install_needed.ps1
#>
[CmdletBinding()]
param(
    [string]$TwinsRoot = "C:\workspace\twins_project",
    [switch]$Check,
    [switch]$Force,
    [switch]$Init,
    [switch]$InstallDocker,
    [switch]$SkipBackend,
    [switch]$SkipFrontend
)

$ErrorActionPreference = "Continue"
$LabPy = Join-Path $PSScriptRoot "lab.py"
$Missing = New-Object System.Collections.Generic.List[string]

function Write-Step { param([string]$Msg) Write-Host "`n== $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK  ] $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

function Update-SessionPath {
    $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ";"
}

function Repair-WingetSources {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "    -> Réinitialisation des sources winget..." -ForegroundColor DarkGray
        & winget source reset --force 2>$null
        & winget source update 2>$null
    }
}

function Find-Python311 {
    $candidates = @()

    if ($env:LOCALAPPDATA) {
        $pyCoreRoot = Join-Path $env:LOCALAPPDATA "Python"
        if (Test-Path -LiteralPath $pyCoreRoot) {
            Get-ChildItem -Path $pyCoreRoot -Filter "pythoncore-*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Join-Path $_.FullName "python.exe"
                if (Test-Path -LiteralPath $p) { $candidates += @{ Exe = $p; Pre = @() } }
            }
        }
    }

    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        foreach ($v in "3.14", "3.13", "3.12", "3.11") { $candidates += @{ Exe = $launcher.Source; Pre = @("-$v") } }
    }

    foreach ($n in "python", "python3") {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source -notmatch "WindowsApps") { $candidates += @{ Exe = $c.Source; Pre = @() } }
    }

    foreach ($c in $candidates) {
        try {
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

function Get-NpmCommand {
    foreach ($name in "npm.cmd", "npm") {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) { return $command.Source }
    }
    return $null
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
        Write-Warn2 "$Label manquant : serait installé via winget ($Id)"
        $Missing.Add($Label)
        return $false
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Fail "$Label manquant et winget est introuvable."
        $Missing.Add($Label)
        return $false
    }
    
    Write-Host "    -> winget install $Id" -ForegroundColor DarkGray
    & winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements
    
    if ($LASTEXITCODE -eq -1978335217 -or $LASTEXITCODE -eq 2316632079) {
        Repair-WingetSources
        & winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements
    }

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Fail "L'installation de $Label a échoué (code $LASTEXITCODE)."
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

# ---------------------------------------------------------------- 1. Prérequis système
Write-Step "1. Prérequis système$(if ($Check) { ' (vérification seule)' })"
Update-SessionPath

$py = Find-Python311
if ($py) {
    Write-Ok "Python >= 3.11 : $($py.Exe) $($py.Pre -join ' ')"
} elseif (Install-WithWinget -Id "Python.Python.3.12" -Label "Python 3.12") {
    $py = Find-Python311
    if ($py) { Write-Ok "Python installé : $($py.Exe)" } else { Write-Fail "Python installé mais introuvable."; $Missing.Add("Python (PATH)") }
}

if ((Get-NodeMajor) -ge 22) {
    Write-Ok "Node.js $(& node --version) (npm/npx inclus)"
} elseif (Install-WithWinget -Id "OpenJS.NodeJS.LTS" -Label "Node.js LTS") {
    if ((Get-NodeMajor) -ge 22) { Write-Ok "Node.js installé : $(& node --version)" } else { Write-Fail "Node.js 22+ introuvable."; $Missing.Add("Node.js (PATH)") }
}

$npmCommand = Get-NpmCommand
if ($npmCommand) {
    Write-Ok "npm disponible : $npmCommand"
} else {
    Write-Fail "npm est introuvable. Réinstaller Node.js LTS puis rouvrir le terminal."
    $Missing.Add("npm")
}
if (Get-Command npx.cmd -ErrorAction SilentlyContinue) {
    Write-Ok "npx disponible"
} elseif (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Ok "npx disponible"
} else {
    Write-Fail "npx est introuvable. Réinstaller Node.js LTS puis rouvrir le terminal."
    $Missing.Add("npx")
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok "Git présent"
} else {
    [void](Install-WithWinget -Id "Git.Git" -Label "Git")
}

if (Test-Path -LiteralPath (Join-Path $TwinsRoot "Makefile") -PathType Leaf) {
    if (Get-Command make -ErrorAction SilentlyContinue) {
        Write-Ok "GNU Make présent"
    } elseif (Install-WithWinget -Id "ezwinports.make" -Label "GNU Make") {
        if (Get-Command make -ErrorAction SilentlyContinue) {
            Write-Ok "GNU Make installé"
        } else {
            Write-Fail "GNU Make installé mais introuvable dans le PATH. Rouvrez le terminal."
            $Missing.Add("GNU Make (PATH)")
        }
    }
}

$docker = Find-Docker
if ($docker) {
    $dockerVersion = & $docker --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Docker CLI : $dockerVersion"
    } else {
        Write-Fail "Docker CLI trouvé mais impossible à exécuter : $docker"
        $Missing.Add("Docker CLI")
    }
} elseif ($InstallDocker) {
    Write-Host "    -> Installation de Docker Desktop via winget." -ForegroundColor DarkGray
    $dockerInstalled = Install-WithWinget -Id "Docker.DockerDesktop" -Label "Docker Desktop"
    Update-SessionPath
    $docker = Find-Docker
    if ($docker) {
        Write-Ok "Docker Desktop installé : $docker"
    } elseif ($dockerInstalled) {
        Write-Fail "Docker Desktop a été installé, mais docker.exe reste introuvable. Redémarrez le terminal puis relancez lab install --check."
        $Missing.Add("Docker CLI (PATH)")
    }
} else {
    Write-Warn2 "Docker Desktop est requis pour PostgreSQL, Neo4j, Redis et le lancement de la stack locale."
}
if ($docker) {
    $composeVersion = & $docker compose version --short 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Docker Compose v2 : $composeVersion"
    } else {
        Write-Fail "Docker Compose v2 est introuvable. Mettre à jour Docker Desktop."
        $Missing.Add("Docker Compose v2")
    }
}

if (-not $py) {
    Write-Host ""
    Write-Fail "Python >= 3.11 est requis pour continuer."
    exit 1
}

if ($Check) {
    if ($TwinsRoot) { $env:TWINS_ROOT = $TwinsRoot }
    Write-Step "Verification complete des prerequis (aucune modification)"
    & $py.Exe @($py.Pre) $LabPy install --check
    exit $LASTEXITCODE
}

# ------------------------------------------------------------- 2. Configuration & Build des composants
if ($TwinsRoot) { $env:TWINS_ROOT = $TwinsRoot }

if (-not (Test-Path -LiteralPath $TwinsRoot -PathType Container)) {
    Write-Fail "Projet Twins introuvable : $TwinsRoot"
    exit 1
}

if (-not $SkipBackend) {
    Write-Step "2. Dépendances backend (venv + requirements.txt)"
    $backendDir = Join-Path $TwinsRoot "backend"
    $requirements = Join-Path $backendDir "requirements.txt"
    if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) {
        Write-Fail "Fichier requirements.txt introuvable : $requirements"
        $Missing.Add("backend/requirements.txt")
    } else {
        $venvDir = Join-Path $backendDir ".venv"
        $backendPython = Join-Path $venvDir "Scripts\python.exe"
        if (-not (Test-Path -LiteralPath $backendPython -PathType Leaf)) {
            Write-Host "    -> Création de $venvDir" -ForegroundColor DarkGray
            & $py.Exe @($py.Pre) -m venv $venvDir
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Création du venv backend échouée (code $LASTEXITCODE)."
                $Missing.Add("backend venv")
            }
        }
        if (Test-Path -LiteralPath $backendPython -PathType Leaf) {
            & $backendPython -m pip install --upgrade pip
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Mise à jour de pip échouée (code $LASTEXITCODE)."
                $Missing.Add("pip backend")
            } else {
                & $backendPython -m pip install -r $requirements
                if ($LASTEXITCODE -ne 0) {
                    Write-Fail "Installation des requirements backend échouée (code $LASTEXITCODE)."
                    $Missing.Add("backend requirements")
                } else {
                    Write-Ok "Dépendances backend installées."
                }
            }
        }
    }
}

if (-not $SkipFrontend) {
    Write-Step "3. Dépendances frontend (npm ci)"
    $frontendDir = Join-Path $TwinsRoot "frontend"
    $packageJson = Join-Path $frontendDir "package.json"
    $packageLock = Join-Path $frontendDir "package-lock.json"
    $npmCommand = Get-NpmCommand
    if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf) -or
        -not (Test-Path -LiteralPath $packageLock -PathType Leaf)) {
        Write-Fail "package.json ou package-lock.json introuvable dans $frontendDir"
        $Missing.Add("frontend manifests")
    } elseif (-not $npmCommand) {
        Write-Fail "npm est introuvable après l'installation de Node.js."
        $Missing.Add("npm")
    } else {
        & $npmCommand ci --engine-strict --prefix $frontendDir
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "npm ci a échoué (code $LASTEXITCODE)."
            $Missing.Add("frontend npm dependencies")
        } else {
            Write-Ok "Dépendances frontend installées."
        }
    }
}

Write-Step "4. Configuration locale"
$envExample = Join-Path $TwinsRoot ".env.example"
$envFile = Join-Path $TwinsRoot ".env"
if ((Test-Path -LiteralPath $envFile -PathType Leaf)) {
    Write-Ok ".env existant conservé sans modification."
} elseif (Test-Path -LiteralPath $envExample -PathType Leaf) {
    try {
        Copy-Item -LiteralPath $envExample -Destination $envFile -ErrorAction Stop
        Write-Ok ".env créé à partir de .env.example."
        Write-Warn2 "Vérifiez les secrets et mots de passe locaux dans .env avant de démarrer Docker Compose."
    } catch {
        Write-Fail "Impossible de créer .env : $($_.Exception.Message)"
        $Missing.Add(".env creation")
    }
} else {
    Write-Fail ".env.example introuvable : $envExample"
    $Missing.Add(".env.example")
}

Write-Host ""
if (-not $SkipBackend -and -not $SkipFrontend) {
    Write-Step "5. Vérification des prérequis de build"
    & $py.Exe @($py.Pre) $LabPy doctor --phase build
    if ($LASTEXITCODE -ne 0) {
        $Missing.Add("diagnostic des prérequis de build")
    }
}

if ($Missing.Count -gt 0) {
    Write-Warn2 "Éléments manquants : $($Missing -join ', ')"
    exit 1
} elseif ($Check) {
    Write-Host "[+] Vérification terminée." -ForegroundColor Green
} else {
    Write-Host "[+] Outils et dépendances de build installés."
    Write-Host "    PostgreSQL, Neo4j, Redis, Mailpit, backend et workers sont fournis par Docker Compose."
    Write-Host "    Pour lancer la stack : docker compose up --build -d"
    Write-Host "    Pour lancer Angular : npm start (depuis le répertoire frontend)."
}
if ($env:TWINS_ROOT) { Write-Host "    TWINS_ROOT = $($env:TWINS_ROOT)" -ForegroundColor DarkGray }
exit 0