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

function Write-DevInfo {
    param([string]$Message)
    Write-Host "[DevConsole] $Message" -ForegroundColor Cyan
}

function Write-DevError {
    param([string]$Message)
    Write-Host "[Erreur] $Message" -ForegroundColor Red
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
    Write-Host "dev help                 Affiche cette aide"
    Write-Host "dev version              Affiche la version"
    Write-Host "dev status               Affiche l environnement"
    Write-Host "dev config               Affiche la configuration"
    Write-Host "dev aliases              Affiche les alias documentes"
    Write-Host "dev history              Affiche les commandes recentes"
    Write-Host "dev init                 Lance l inventaire des outils"
    Write-Host "dev run <commande>       Execute une commande externe"
    Write-Host ""
    Write-Host "Exemples :"
    Write-Host "  .\dev.ps1 status"
    Write-Host "  .\dev.ps1 run git --version"
    Write-Host "  .\dev.ps1 run python --version"
    Write-Host ""
    Write-Host "Le script ne modifie pas automatiquement les installations de logiciels."
}

function Show-DevStatus {
    Write-Host "Projet       : DevConsole"
    Write-Host "Version      : 1.0.0"
    Write-Host "RÃ©pertoire   : $Root"
    Write-Host "PowerShell   : $($PSVersionTable.PSVersion)"
    Write-Host "ExÃ©cutable   : $((Get-Process -Id $PID).Path)"
    Write-Host "RÃ©pertoire courant : $((Get-Location).Path)"

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

switch ($Command.ToLowerInvariant()) {
    'help' {
        Show-DevHelp
        break
    }
    '--help' {
        Show-DevHelp
        break
    }
    '-h' {
        Show-DevHelp
        break
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