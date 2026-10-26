[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'DevConsole')
)

Write-Warning "Cette opÃ©ration supprime uniquement le rÃ©pertoire d'installation indiquÃ©."
Write-Warning 'Elle ne supprime ni les outils externes ni le projet source.'

if (-not (Test-Path -LiteralPath $InstallDirectory)) {
    Write-Host "Rien Ã  supprimer : $InstallDirectory"
    return
}

if ($PSCmdlet.ShouldProcess($InstallDirectory, 'Supprimer lâ€™installation DevConsole')) {
    Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
    Write-Host 'Installation supprimÃ©e.' -ForegroundColor Green
}