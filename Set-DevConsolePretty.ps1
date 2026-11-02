[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Install,
    [string]$SettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
    [string]$ProfileName = 'PowerShell'
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pwsh) { throw 'PowerShell 7 absent. Installer avec : winget install --id Microsoft.PowerShell --exact' }
    $forward = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath, '-SettingsPath', $SettingsPath, '-ProfileName', $ProfileName)
    if ($Install) { $forward += '-Install' }
    if ($WhatIfPreference) { $forward += '-WhatIf' }
    & $pwsh.Source @forward
    if ($LASTEXITCODE -ne 0) { throw "Configuration interrompue dans PowerShell 7 (code $LASTEXITCODE)." }
    return
}

$ErrorActionPreference = 'Stop'
$font = '3270 Nerd Font Cond'
if ($Install -and -not (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'WinGet absent. Installer App Installer : https://learn.microsoft.com/windows/package-manager/winget/#install-winget'
    }
    if ($PSCmdlet.ShouldProcess('JanDeDobbeleer.OhMyPosh', 'Installer avec WinGet')) {
        & winget install --id JanDeDobbeleer.OhMyPosh --exact --source winget --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "Echec WinGet : $LASTEXITCODE" }
        Write-Host 'Oh My Posh installe. Relancer PowerShell pour actualiser PATH.' -ForegroundColor Green
    }
}

$fontFiles = @(foreach ($key in @(
    'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
)) {
    if (Test-Path $key) {
        $entry = (Get-ItemProperty $key).PSObject.Properties | Where-Object Name -eq "$font (TrueType)"
        foreach ($item in $entry) {
            $file = [Environment]::ExpandEnvironmentVariables([string]$item.Value)
            if (-not [IO.Path]::IsPathRooted($file)) { $file = Join-Path "$env:WINDIR\Fonts" $file }
            if (Test-Path -LiteralPath $file -PathType Leaf) { $file }
        }
    }
})
if (-not $fontFiles.Count) {
    throw "Police exacte '$font' absente du registre ou fichier introuvable. Installer 3270NerdFont-Condensed.ttf, puis relancer cette commande."
}
Write-Host "[OK] $font : $($fontFiles -join ', ')" -ForegroundColor Green

if (-not (Test-Path -LiteralPath $SettingsPath)) { throw "Configuration Terminal introuvable : $SettingsPath. Utiliser -SettingsPath." }
$settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$profiles = @($settings.profiles.list | Where-Object { $_.name -eq $ProfileName })
if ($profiles.Count -ne 1) { throw "Il faut exactement un profil '$ProfileName' ; trouve : $($profiles.Count). Utiliser -ProfileName." }
$target = $profiles[0]
if (-not $target.font) { $target.font = @{} }
$target.font.face = $font
$target.font.size = 11
if ($PSCmdlet.ShouldProcess($SettingsPath, "Configurer '$ProfileName' avec $font, taille 11")) {
    $backup = "$SettingsPath.devconsole-$(Get-Date -Format 'yyyyMMdd-HHmmss-ffff').bak"
    Copy-Item -LiteralPath $SettingsPath -Destination $backup
    $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $SettingsPath -Encoding utf8
    $verified = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json -Depth 100
    $actual = @($verified.profiles.list | Where-Object name -eq $ProfileName)[0]
    if ($actual.font.face -ne $font -or $actual.font.size -ne 11) { throw "Verification echouee. Sauvegarde : $backup" }
    Write-Host "Configuration enregistree. Sauvegarde : $backup" -ForegroundColor Green
    Write-Host 'Fermer toutes les fenetres Windows Terminal, relancer PowerShell et verifier le rendu visuellement.'
}
