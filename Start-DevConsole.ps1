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
            Write-Warning 'Les tests ont signalÃ© une erreur.'
        }
    }
}

if (-not $SkipInventory) {
    $inventoryScript = Join-Path $Root 'scripts\Initialize-DevConsole.ps1'
    if (Test-Path -LiteralPath $inventoryScript) {
        Write-Host ''
        Write-Host '[2/2] Inventaire de lâ€™environnement' -ForegroundColor Yellow
        & $inventoryScript -Workspace $Workspace
    }
}

Set-Location -LiteralPath $Workspace

Write-Host ''
Write-Host 'DevConsole est prÃªt. Invite PowerShell native activÃ©e.' -ForegroundColor Green
Write-Host "Tape : & '$Root\dev.ps1' help"
Write-Host ''
# Ne pas lancer de boucle Read-Host : le terminal reste interactif
# grÃ¢ce Ã  -NoExit dans le raccourci.