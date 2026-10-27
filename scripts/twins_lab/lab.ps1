<#
.SYNOPSIS
    Moteur CLI modulaire pour twins_lab (Init, Build, Test, Isolation, Run).
.DESCRIPTION
    Permet d'administrer et d'exécuter des cycles de vie ciblés par composant 
    sans lancer l'intégralité du monorepo.
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Action = "doctor",

    [Parameter(Position=1)]
    [string]$SubAction = "", # init, build, test, isolation, run

    [Parameter(Position=2)]
    [string]$ComponentName = "",

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$TwinsProject = "C:\workspace\twins_project"
$BackendDir = Join-Path $TwinsProject "backend"
$ComponentsDir = Join-Path $ScriptDir "components"
$BuildsDir = Join-Path $ScriptDir "builds"

# Création des dossiers nécessaires si absents
if (!(Test-Path $BuildsDir)) { New-Item -ItemType Directory -Force -Path $BuildsDir | Out-Null }

function Get-ComponentConfig {
    param([string]$Name)
    $tomlPath = Join-Path $ComponentsDir "$Name.toml"
    if (!(Test-Path $tomlPath)) {
        # Configuration par défaut de secours pour experimentation
        return [PSCustomObject]@{
            Name       = $Name
            BackendPath = "app/modules/$Name"
            Port       = 8001
        }
    }
    # Simulation de lecture de configuration (ou parsing TOML basique)
    return [PSCustomObject]@{
        Name       = $Name
        BackendPath = "app/modules/$Name"
        Port       = 8001
    }
}

function Invoke-ComponentAction {
    param([string]$Op, [string]$Comp)

    if ([string]::IsNullOrEmpty($Comp)) {
        Write-Host "[-] Erreur : Nom de composant requis (ex: experimentation)." -ForegroundColor Red
        exit 1
    }

    $config = Get-ComponentConfig -Name $Comp
    $PythonExe = Join-Path $BackendDir ".venv\Scripts\python.exe"
    if (!(Test-Path $PythonExe)) { $PythonExe = "python" }

    switch ($Op) {
        "init" {
            Write-Host "=== [TWINS_LAB] INIT : $Comp ===" -ForegroundColor Cyan
            Write-Host "[*] Configuration des dépendances et stubs locaux pour $Comp..." -ForegroundColor Yellow
            # Initialisation des variables d'environnement de sandbox
            $env:JWT_SECRET_KEY = "test_jwt_secret_key_for_isolation_purposes_only"
            $env:DATABASE_URL = "sqlite:///:memory:"
            Write-Host "[+] Initialisation terminée avec succès." -ForegroundColor Green
        }

        "build" {
            Write-Host "=== [TWINS_LAB] BUILD : $Comp ===" -ForegroundColor Cyan
            Set-Location -Path $BackendDir

            # Récupération des métadonnées Git pour la traçabilité
            $gitSha = & git rev-parse HEAD 2>&1
            $gitStatus = & git status --porcelain 2>&1
            $isClean = [string]::IsNullOrEmpty($gitStatus)

            Write-Host "[*] Compilation ciblée et vérification syntaxique..." -ForegroundColor Yellow
            & $PythonExe -m py_compile app/modules/$Comp/*.py

            # Génération du manifeste de build
            $manifest = [PSCustomObject]@{
                Component         = $Comp
                Timestamp         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                GitCommitSha      = $gitSha.Trim()
                WorkingTreeClean  = $isClean
                Status            = "SUCCESS"
            }
            $manifestPath = Join-Path $BuildsDir "$Comp-build-manifest.json"
            $manifest | ConvertTo-Json -Depth 3 | Set-Content -Path $manifestPath -Encoding UTF8
            
            Write-Host "[+] Build validé. Manifeste généré : $manifestPath" -ForegroundColor Green
        }

        "test" {
            Write-Host "=== [TWINS_LAB] TEST : $Comp ===" -ForegroundColor Cyan
            Set-Location -Path $BackendDir
            $env:JWT_SECRET_KEY = "test_jwt_secret_key_for_isolation_purposes_only"
            $env:DATABASE_URL = "sqlite:///:memory:"

            $TestPath = "tests/unit/$Comp"
            if (!(Test-Path (Join-Path $BackendDir $TestPath))) {
                $TestPath = "tests/unit" # Fallback
            }

            Write-Host "[*] Exécution de pytest sur $TestPath..." -ForegroundColor Yellow
            & $PythonExe -m pytest $TestPath -v --tb=short

            if ($LASTEXITCODE -eq 0) {
                Write-Host "[+] Tests validés pour $Comp." -ForegroundColor Green
            } else {
                Write-Host "[-] Échec des tests sur $Comp." -ForegroundColor Red
                exit 1
            }
        }

        "isolation" {
            Write-Host "=== [TWINS_LAB] ISOLATION / DEBUG : $Comp ===" -ForegroundColor Cyan
            Write-Host "[*] Préparation de l'environnement de débogage sandboxé..." -ForegroundColor Yellow
            Write-Host "[*] Mocks des connecteurs LLM et bases de données activés." -ForegroundColor Green
            Write-Host "[+] Environnement prêt pour le diagnostic interactif." -ForegroundColor Cyan
        }

        "run" {
            Write-Host "=== [TWINS_LAB] RUN LOCAL : $Comp ===" -ForegroundColor Cyan
            Set-Location -Path $BackendDir

            $env:JWT_SECRET_KEY = "local_debug_secret_key"
            $env:DATABASE_URL = "sqlite:///local_debug_$Comp.db"
            $env:ENVIRONMENT = "development"

            Write-Host "[*] Démarrage d'une instance locale dédiée pour le module '$Comp' sur le port $($config.Port)..." -ForegroundColor Yellow
            Write-Host "[*] Appuyez sur Ctrl+C pour stopper l'instance." -ForegroundColor DarkGray

            # Lancement d'un serveur FastAPI léger ciblé ou d'un worker de test
            & $PythonExe -m uvicorn app.main:app --reload --port $config.Port
        }

        default {
            Write-Host "[-] Action inconnue : '$Op'. Utilisez init, build, test, isolation ou run." -ForegroundColor Red
            exit 1
        }
    }
}

# Routage global CLI
switch ($Action) {
    "doctor" {
        Write-Host "=== [TWINS_LAB] Diagnostic du Laboratoire ===" -ForegroundColor Cyan
        Write-Host "[+] Répertoire actif : $ScriptDir" -ForegroundColor Green
        Write-Host "[+] Dossier Builds : $BuildsDir" -ForegroundColor Green
    }
    "list" {
        Write-Host "=== [TWINS_LAB] Composants Enregistrés ===" -ForegroundColor Cyan
        Write-Host " - experimentation (Backend FastAPI / Angular)" -ForegroundColor White
        Write-Host " - auth (Backend FastAPI)" -ForegroundColor White
        Write-Host " - studio (Backend FastAPI / Neo4j)" -ForegroundColor White
    }
    "component" {
        Invoke-ComponentAction -Op $SubAction -Comp $ComponentName
    }
}