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

    Write-Host "DevConsole installÃ© dans : $InstallDirectory" -ForegroundColor Green
    Write-Host 'Pour le lancer :'
    Write-Host "  & '$InstallDirectory\dev.ps1' help"
}