# Raccourcis DevConsole charges a l'initialisation (dev.ps1, Start-DevConsole.ps1, profil PowerShell).
# Les fonctions sont declarees en portee globale pour rester disponibles dans la session.

function global:unzip {
    <#
    .SYNOPSIS
        Extrait une archive .zip (equivalent du unzip Unix, absent de Windows PowerShell).
    .EXAMPLE
        unzip files                 # extrait files.zip dans le dossier courant
        unzip app.zip -d .\app      # extrait dans .\app
        unzip app.zip -Force        # ecrase les fichiers existants
        unzip app.zip -List         # liste le contenu sans extraire
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        [Parameter(Position = 1)]
        [Alias('d', 'o')]
        [string]$Destination = '.',

        [switch]$Force,
        [switch]$List
    )

    $candidates = @($Path)
    if ([System.IO.Path]::GetExtension($Path) -eq '') { $candidates += "$Path.zip" }

    $archive = $null
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            $archive = (Resolve-Path -LiteralPath $c).ProviderPath
            break
        }
    }
    if (-not $archive) {
        Write-Host "[unzip] Archive introuvable : $Path" -ForegroundColor Red
        return
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
    }
    catch {
        Write-Host "[unzip] Archive illisible ou invalide : $archive" -ForegroundColor Red
        return
    }
    try {
        $entries = @($zip.Entries)
        if ($List) {
            $entries | ForEach-Object { '{0,12}  {1}' -f $_.Length, $_.FullName }
            return
        }
    }
    finally {
        $zip.Dispose()
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }
    $target = (Resolve-Path -LiteralPath $Destination).ProviderPath

    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $target -Force:$Force -ErrorAction Stop
        Write-Host "[unzip] $($entries.Count) entree(s) extraite(s) : $archive -> $target" -ForegroundColor Green
    }
    catch {
        Write-Host "[unzip] Echec : $($_.Exception.Message)" -ForegroundColor Red
        if (-not $Force) { Write-Host "        (fichiers deja presents ? relancer avec -Force)" -ForegroundColor Yellow }
    }
}
