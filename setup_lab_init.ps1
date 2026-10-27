# ==============================================================================
# Script de Setup et Validation de la commande 'lab init' pour twins_lab
# ==============================================================================

$ErrorActionPreference = "Stop"

# Définition des chemins
$DevConsoleDir = "C:\workspace\devConsole"
$LabScriptPath = "$DevConsoleDir\scripts\twins_lab\lab.ps1"
$DevScriptPath = "$DevConsoleDir\dev.ps1"

Write-Host "=== 1. Vérification et Préparation du fichier lab.ps1 ===" -ForegroundColor Cyan

# 1. Vérification de la présence des dossiers et fichiers de référence
if (-not (Test-Path $LabScriptPath)) {
    Write-Host "[INFO] Le fichier $LabScriptPath n'existe pas encore. Création du répertoire et du fichier..." -ForegroundColor Yellow
    $LabDirectory = Split-Path -Parent $LabScriptPath
    if (-not (Test-Path $LabDirectory)) {
        New-Item -Path $LabDirectory -ItemType Directory -Force | Out-Null
    }
    Set-Content -Path $LabScriptPath -Value "param([string]`$Action)" -Encoding UTF8
}

# 2. Sauvegarde de sécurité
$BackupPath = "$LabScriptPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Copy-Item -Path $LabScriptPath -Destination $BackupPath -Force
Write-Host "[OK] Sauvegarde effectuée : $BackupPath" -ForegroundColor Green

# 3. Contenu de la fonction lab init à injecter
$InitCode = @'

# --- Bloc de commande 'init' pour le laboratoire twins_lab ---
param(
    [Parameter(Position=0)]
    [string]$Action = "doctor"
)

$RootProject = "C:\workspace\twins_project"
$BackendDir  = "$RootProject\backend"
$FrontendDir = "$RootProject\frontend"
$VenvDir     = "$BackendDir\.venv"

function Write-Step { param([string]$Msg) Write-Host "[LAB INIT] $Msg" -ForegroundColor Cyan }
function Write-Success { param([string]$Msg) Write-Host "[OK] $Msg" -ForegroundColor Green }
function Write-ErrExit { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red; exit 1 }

if ($Action -eq "init") {
    Write-Step "=== 1. Vérification des prérequis système ==="
    
    # Vérification Python
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCmd) { Write-ErrExit "Python n'est pas installé ou introuvable dans le PATH." }
    $pyVersion = (python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    Write-Success "Python détecté : version $pyVersion"

    # Vérification npm / Node.js
    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCmd) { Write-ErrExit "Node.js / npm n'est pas installé ou introuvable dans le PATH." }
    $npmVersion = (npm --version)
    Write-Success "npm détecté : version $npmVersion"

    # Vérification de la structure du projet
    if (-not (Test-Path $BackendDir)) { Write-ErrExit "Répertoire backend introuvable : $BackendDir" }
    if (-not (Test-Path $FrontendDir)) { Write-ErrExit "Répertoire frontend introuvable : $FrontendDir" }

    Write-Step "=== 2. Setup de l'environnement virtuel Python (Backend) ==="
    if (-not (Test-Path $VenvDir)) {
        Write-Host "Création d'un environnement virtuel dédié (.venv)..."
        python -m venv $VenvDir
    } else {
        Write-Success "Environnement virtuel existant détecté."
    }

    $venvPython = "$VenvDir\Scripts\python.exe"
    $venvPip    = "$VenvDir\Scripts\pip.exe"

    Write-Step "Mise à jour de pip et installation des dépendances backend (requirements.txt)..."
    & $venvPython -m pip install --upgrade pip --quiet
    if (Test-Path "$BackendDir\requirements.txt") {
        & $venvPip install -r "$BackendDir\requirements.txt"
        if ($LASTEXITCODE -ne 0) { Write-ErrExit "Erreur lors de l'installation des dépendances Python." }
        Write-Success "Dépendances backend installées avec succès dans .venv."
    } else {
        Write-ErrExit "Fichier requirements.txt introuvable dans $BackendDir."
    }

    Write-Step "=== 3. Setup du Frontend Angular ==="
    Set-Location $FrontendDir
    if (Test-Path "package-lock.json") {
        Write-Host "Exécution de 'npm ci' (installation verrouillée)..."
        npm ci
    } else {
        Write-Host "Exécution de 'npm install'..."
        npm install
    }
    if ($LASTEXITCODE -ne 0) { Write-ErrExit "Erreur lors de l'installation du frontend." }
    Write-Success "Dépendances frontend installées avec succès."

    Write-Step "=== 4. Test d'intégrité et stabilité ==="
    & $venvPython -c "import fastapi, pydantic, sqlalchemy, uvicorn, celery, redis; print('Imports critiques FastAPI/Celery validés avec succès.')"
    if ($LASTEXITCODE -ne 0) { Write-ErrExit "Échec lors de la vérification des modules Python." }

    Write-Success "=== Le laboratoire est prêt et stable pour les builds et tests ==="
    exit 0
}
'@

# Injection du code dans lab.ps1
Set-Content -Path $LabScriptPath -Value $InitCode -Encoding UTF8
Write-Host "[OK] Le fichier lab.ps1 a été configuré avec le handler 'init'." -ForegroundColor Green

# ==============================================================================
# Execution de test
# ==============================================================================

Write-Host "`n=== 2. Exécution du test de validation de la commande ===" -ForegroundColor Cyan
Write-Host "Lancement de : & '$DevScriptPath' lab init" -ForegroundColor Yellow
Write-Host "------------------------------------------------------------"

if (Test-Path $DevScriptPath) {
    & $DevScriptPath lab init
} else {
    # Exécution directe du script lab si dev.ps1 n'est pas présent sur ce chemin
    & $LabScriptPath -Action init
}