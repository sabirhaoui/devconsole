<#
.SYNOPSIS
    Script de setup et de cartographie isolée pour le module 'experimentation' (twins_project).
.DESCRIPTION
    Scanne les sources du module experimentation (Backend FastAPI & Frontend Angular) 
    dans C:\workspace\twins_project et génère une cartographie locale dans C:\workspace\devConsole\scripts\twins_lab\modules\experimentation.
#>

[CmdletBinding()]
param(
    [string]$TwinsProject = "C:\workspace\twins_project",
    [string]$LabDir = "C:\workspace\devConsole\scripts\twins_lab"
)

$ErrorActionPreference = "Stop"

$TargetModule = "experimentation"
$ModuleLabDir = Join-Path $LabDir "modules\$TargetModule"
$BackendSource = Join-Path $TwinsProject "backend"
$FrontendSource = Join-Path $TwinsProject "frontend"

Write-Host "=== [TWINS_LAB] Setup et Cartographie : $TargetModule ===" -ForegroundColor Cyan

# 1. Création de la structure de staging du laboratoire
if (!(Test-Path $ModuleLabDir)) {
    New-Item -ItemType Directory -Force -Path $ModuleLabDir | Out-Null
    New-Item -ItemType Directory -Force -Path "$ModuleLabDir\mocks" | Out-Null
    New-Item -ItemType Directory -Force -Path "$ModuleLabDir\fixtures" | Out-Null
    Write-Host "[+] Dossier de laboratoire créé : $ModuleLabDir" -ForegroundColor Green
} else {
    Write-Host "[*] Dossier de laboratoire existant : $ModuleLabDir" -ForegroundColor Yellow
}

# 2. Cartographie Backend (FastAPI - routes, services, modèles)
Write-Host "`n[*] Analyse des sources Backend pour '$TargetModule'..." -ForegroundColor Yellow
$backendMapPath = Join-Path $ModuleLabDir "backend_map.json"
$backendFiles = Get-ChildItem -Path $BackendSource -Recurse -File -Filter "*.py" | Where-Object { 
    $_.FullName -match $TargetModule -or $_.Name -match $TargetModule 
}

$backendDetails = [PSCustomObject]@{
    Module      = $TargetModule
    ScannedAt   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    FilesFound  = $backendFiles.FullName
}
$backendDetails | ConvertTo-Json -Depth 5 | Set-Content -Path $backendMapPath -Encoding UTF8
Write-Host "[+] Cartographie Backend enregistrée : $backendMapPath" -ForegroundColor Green

# 3. Cartographie Frontend (Angular - composants, services, modèles)
Write-Host "`n[*] Analyse des sources Frontend pour '$TargetModule'..." -ForegroundColor Yellow
$frontendMapPath = Join-Path $ModuleLabDir "frontend_map.json"
$frontendFiles = Get-ChildItem -Path $FrontendSource -Recurse -File | Where-Object { 
    $_.FullName -match $TargetModule 
}

$frontendDetails = [PSCustomObject]@{
    Module      = $TargetModule
    ScannedAt   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    FilesFound  = $frontendFiles.FullName
}
$frontendDetails | ConvertTo-Json -Depth 5 | Set-Content -Path $frontendMapPath -Encoding UTF8
Write-Host "[+] Cartographie Frontend enregistrée : $frontendMapPath" -ForegroundColor Green

Write-Host "`n=== Setup et Cartographie terminés avec succès ===" -ForegroundColor Cyan
Write-Host "Les rapports de cartographie sont disponibles dans : $ModuleLabDir" -ForegroundColor White