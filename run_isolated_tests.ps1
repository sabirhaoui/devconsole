<#
.SYNOPSIS
    Lance les tests isolés du module experimentation en injectant les variables d'environnement minimales.
#>

[CmdletBinding()]
param(
    [string]$TwinsProject = "C:\workspace\twins_project",
    [string]$Scope = "unit",
    [string]$TargetTest = ""
)

$ErrorActionPreference = "Stop"
$BackendDir = Join-Path $TwinsProject "backend"

Write-Host "=== [TWINS_LAB] Exécution des tests isolés : experimentation ($Scope) ===" -ForegroundColor Cyan

Set-Location -Path $BackendDir

# Recherche de l'environnement virtuel local (.venv ou venv)
$PythonExe = "python"
foreach ($venv in @(".venv", "venv")) {
    $candidate = Join-Path $BackendDir "$venv\Scripts\python.exe"
    if (Test-Path $candidate) {
        $PythonExe = $candidate
        Write-Host "[*] Environnement virtuel détecté : $candidate" -ForegroundColor Green
        break
    }
}

# --- INJECTION DES VARIABLES D'ENVIRONNEMENT DE TEST ---
Write-Host "[*] Configuration des variables d'environnement isolées..." -ForegroundColor Yellow
$env:JWT_SECRET_KEY = "test_jwt_secret_key_for_isolation_purposes_only"
$env:DATABASE_URL = "sqlite:///:memory:"
$env:ENVIRONMENT = "test"

if ($TargetTest -ne "") {
    $TestPath = $TargetTest
} elseif ($Scope -eq "unit") {
    $TestPath = "tests/unit/experimentation"
} elseif ($Scope -eq "integration") {
    $TestPath = "tests/integration/experimentation"
} else {
    $TestPath = "tests/unit/experimentation"
}

Write-Host "[*] Lancement de pytest sur : $TestPath" -ForegroundColor Yellow
& $PythonExe -m pytest $TestPath -v --tb=short

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n[+] Tests exécutés avec succès !" -ForegroundColor Green
} else {
    Write-Host "`n[-] Échec lors de l'exécution des tests." -ForegroundColor Red
}