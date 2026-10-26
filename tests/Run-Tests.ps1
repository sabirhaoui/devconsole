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
    Write-Host 'Tous les tests sont passÃ©s.' -ForegroundColor Green
    exit 0
}

Write-Host "$Failures test(s) en Ã©chec." -ForegroundColor Red
exit 1