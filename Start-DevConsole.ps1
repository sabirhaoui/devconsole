[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$SkipInventory,
    [switch]$NoPretty
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pwsh) { throw 'PowerShell 7 absent. Installer avec : winget install --id Microsoft.PowerShell --exact' }
    $forward = @('-NoLogo', '-NoExit', '-File', $PSCommandPath)
    if ($SkipTests) { $forward += '-SkipTests' }
    if ($SkipInventory) { $forward += '-SkipInventory' }
    if ($NoPretty) { $forward += '-NoPretty' }
    & $pwsh.Source @forward
    return
}

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Workspace = Split-Path -Parent $Root

. (Join-Path $Root 'scripts\Welcome.ps1')
$global:DevConsoleScript = Join-Path $Root 'dev.ps1'
function global:dev { & $global:DevConsoleScript @args }
function global:lab { & $global:DevConsoleScript lab @args }
Show-DevConsoleWelcome -ProjectRoot $Root -Workspace $Workspace

if (-not $NoPretty) {
    . (Join-Path $Root 'scripts\Pretty.ps1')
    Enable-DevConsolePretty
}

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
        Write-Host "[2/2] Inventaire de l'environnement" -ForegroundColor Yellow
        & $inventoryScript -Workspace $Workspace
    }
}

Set-Location -LiteralPath $Workspace

Write-Host ''
Write-Host 'DevConsole est pret.' -ForegroundColor Green
Write-Host 'Tape : dev help'
Write-Host ''
# Ne pas lancer de boucle Read-Host : le terminal reste interactif
# grâce à -NoExit dans le raccourci.
