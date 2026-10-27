[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config\config.example.json'
$HistoryPath = Join-Path $Root 'data\history.jsonl'
$DevScriptPath = Join-Path $Root 'dev.ps1'

function Write-DevInfo {
    param([string]$Message)
    Write-Host "[DevConsole] $Message" -ForegroundColor Cyan
}

function Write-DevError {
    param([string]$Message)
    Write-Host "[Erreur] $Message" -ForegroundColor Red
}

function Enable-LabShortcut {
    $profileDir = Split-Path -Parent $PROFILE
    if (!(Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    }
    if (!(Test-Path -LiteralPath $PROFILE)) {
        New-Item -ItemType File -Force -Path $PROFILE | Out-Null
    }

    $labSnippet = "`nfunction lab { & `"$DevScriptPath`" lab @args }"
    $profileContent = Get-Content -LiteralPath $PROFILE -ErrorAction SilentlyContinue

    if (-not ($profileContent | Select-String "function lab")) {
        Add-Content -Path $PROFILE -Value $labSnippet
        Write-DevInfo "Raccourci global 'lab' activé avec succès dans le profil PowerShell."
    }

    # Correction : Fige le chemin absolu du script dans la session active
    $scriptBlock = [scriptblock]::Create("& `"$DevScriptPath`" lab @args")
    Set-Item -Path "function:global:lab" -Value $scriptBlock
}

function Get-DevConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration introuvable : $ConfigPath"
    }
    Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}

function Add-DevHistory {
    param([string]$Text)

    try {
        $config = Get-DevConfig
        if (-not $config.history.enabled) { return }

        $parent = Split-Path -Parent $HistoryPath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force |
                Out-Null
        }

        $entry = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            command   = $Text
            directory = (Get-Location).Path
        }

        $json = $entry | ConvertTo-Json -Compress
        Add-Content -LiteralPath $HistoryPath -Value $json -Encoding UTF8
    }
    catch {
        Write-Verbose "Historique indisponible : $($_.Exception.Message)"
    }
}

function Show-DevHelp {
    Write-Host "DevConsole - aide"
    Write-Host "-----------------"
    Write-Host "dev help                Affiche cette aide"
    Write-Host "dev version             Affiche la version"
    Write-Host "dev status              Affiche l environnement"
    Write-Host "dev config              Affiche la configuration"
    Write-Host "dev aliases             Affiche les alias documentes"
    Write-Host "dev history             Affiche les commandes recentes"
    Write-Host "dev init                Lance l inventaire des outils"
    Write-Host "dev run <commande>      Execute une commande externe"
    Write-Host 'dev lab doctor          Diagnostique twins_lab'
    Write-Host 'dev lab list            Liste les composants du projet'
    Write-Host 'dev lab inspect <module>  Analyse les dependances'
    Write-Host 'dev lab test <module>     Lance les tests du composant'
    Write-Host 'dev lab run <module>      Lance un composant isole'
    Write-Host ""
    Write-Host "Exemples :"
    Write-Host "  .\dev.ps1 status"
    Write-Host "  .\dev.ps1 run git --version"
}

function Show-DevStatus {
    Write-Host "Projet       : DevConsole"
    Write-Host "Version      : 1.0.0"
    Write-Host "Répertoire   : $Root"
    Write-Host "PowerShell   : $($PSVersionTable.PSVersion)"
    Write-Host "Exécutable   : $((Get-Process -Id $PID).Path)"
    Write-Host "Répertoire courant : $((Get-Location).Path)"

    foreach ($tool in @('git', 'python', 'node', 'npm', 'podman', 'docker')) {
        $found = Get-Command $tool -ErrorAction SilentlyContinue
        if ($found) {
            Write-Host ("{0,-12}: {1}" -f $tool, $found.Source)
        }
        else {
            Write-Host ("{0,-12}: absent du PATH" -f $tool)
        }
    }
}

function Invoke-DevExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [string[]]$Args = @()
    )

    $resolved = Get-Command $Executable -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Write-DevError "Commande introuvable : $Executable"
        return 127
    }

    Add-DevHistory (($Executable + ' ' + ($Args -join ' ')).Trim())

    & $resolved.Source @Args
    if ($null -ne $LASTEXITCODE) {
        return [int]$LASTEXITCODE
    }
    return 0
}

# Rafraîchissement automatique et activation immédiate du raccourci dans la session active
Enable-LabShortcut

switch ($Command.ToLowerInvariant()) {
    'help' {
        Show-DevHelp
        break
    }
    'lab' {
            $labPy = Join-Path $PSScriptRoot 'scripts\twins_lab\lab.py'

            if (-not (Test-Path -LiteralPath $labPy -PathType Leaf)) {
                Write-Error "Script lab.py introuvable : $labPy"
                exit 2
            }

            # Utilisation de Python pour exécuter lab.py avec tous les arguments
            $pythonExe = "python"
            if (Get-Command "python3" -ErrorAction SilentlyContinue) {
                $pythonExe = "python3"
            }

            & $pythonExe $labPy @Arguments
            exit $LASTEXITCODE
        }
    'version' {
        Write-Host 'DevConsole 1.0.0'
        break
    }
    'status' {
        Show-DevStatus
        break
    }
    'config' {
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            Write-Host
        break
    }
    'aliases' {
        $config = Get-DevConfig
        $config.aliases.PSObject.Properties |
            ForEach-Object {
                Write-Host ("{0,-12} -> {1}" -f $_.Name, $_.Value)
            }
        break
    }
    'history' {
        if (Test-Path -LiteralPath $HistoryPath) {
            Get-Content -LiteralPath $HistoryPath -Tail 20 |
                ForEach-Object { Write-Host $_ }
        }
        else {
            Write-Host 'Aucun historique disponible.'
        }
        break
    }
    'init' {
        & (Join-Path $Root 'scripts\Initialize-DevConsole.ps1')
        break
    }
    'run' {
        if ($Arguments.Count -lt 1) {
            Write-DevError 'Usage : dev run <commande> [arguments...]'
            break
        }
        $exitCode = Invoke-DevExternalCommand `
            -Executable $Arguments[0] `
            -Args @($Arguments | Select-Object -Skip 1)
        exit $exitCode
    }
    default {
        Write-DevError "Sous-commande inconnue : $Command"
        Write-Host 'Utilise : .\dev.ps1 help'
        exit 2
    }
}