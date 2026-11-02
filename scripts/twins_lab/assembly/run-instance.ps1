#Requires -Version 5.1
<#
.SYNOPSIS
  Exécute une instance twins_project livrée par la chaîne d'assemblage.

.DESCRIPTION
  Chaque exécution (« run ») a son propre identifiant, son projet compose, son réseau, ses volumes,
  ses mots de passe et son port : deux runs d'un même build (ou de builds différents) ne se
  partagent rien. Le build, lui, est immuable (build.json / manifest.json).

.EXAMPLE
  .\run-instance.ps1                    # démarre un run (port libre choisi automatiquement)
  .\run-instance.ps1 -Port 8080
  .\run-instance.ps1 -Action status
  .\run-instance.ps1 -Action down -Purge   # arrête le dernier run et supprime ses volumes
  .\run-instance.ps1 -Action smoke      # run éphémère + contrôle des versions effectives, puis destruction
#>
[CmdletBinding()]
param(
    [ValidateSet('up', 'down', 'status', 'smoke')]
    [string]$Action = 'up',
    [string]$RunId,
    [int]$Port = 0,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'twins-common.ps1')
Import-Policy -Path (Join-Path $here 'versions.psd1')

$build = Get-Content -Raw -LiteralPath (Join-Path $here 'build.json') | ConvertFrom-Json
$runsDir = Join-Path $here '.runs'
New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
$docker = Resolve-Exe 'docker'
if (-not $docker) { throw 'docker est introuvable dans le PATH.' }

function New-Secret {
    param([int]$Length = 24)
    $chars = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
}

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return $p
}

function Get-RunState {
    param([string]$Id)
    if ($Id) { $f = Join-Path $runsDir "$Id.json" }
    else { $f = (Get-ChildItem -LiteralPath $runsDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { throw 'Aucun run connu : lancer d''abord -Action up.' }
    return (Get-Content -Raw -LiteralPath $f | ConvertFrom-Json)
}

function Invoke-Compose {
    param($State, [string[]]$ComposeArgs, [string]$Label, [switch]$Quiet)
    $a = @('compose', '-p', $State.Project, '--env-file', $State.EnvFile, '-f', (Join-Path $here 'docker-compose.yml')) + $ComposeArgs
    return Invoke-Native -File $docker -Arguments $a -WorkDir $here -Log (Join-Path $runsDir "$($State.RunId).log") -Label $Label -Quiet:$Quiet
}

function Start-Run {
    param([string]$Id, [int]$HostPort)
    if ($HostPort -le 0) { $HostPort = Get-FreePort }
    $envFile = Join-Path $runsDir "$Id.env"
    $text = @(
        "BUILD_VERSION=$($build.buildVersion)",
        "POSTGRES_IMAGE=$($build.images.postgres)",
        "NEO4J_IMAGE=$($build.images.neo4j)",
        "TWINS_HTTP_PORT=$HostPort",
        "POSTGRES_PASSWORD=$(New-Secret)",
        "NEO4J_PASSWORD=$(New-Secret)"
    ) -join "`n"
    [System.IO.File]::WriteAllText($envFile, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $override = Join-Path $here '.env.run'
    if (-not (Test-Path -LiteralPath $override)) { [System.IO.File]::WriteAllText($override, "# variables propres à l'application (non secrètes ici), lues par le backend`n") }

    $state = [pscustomobject]@{ RunId = $Id; Project = ("twins-$Id").ToLower(); Port = $HostPort; EnvFile = $envFile; BuildVersion = $build.buildVersion; StartedAt = (Get-Date).ToString('o') }
    Save-Json $state (Join-Path $runsDir "$Id.json")

    $r = Invoke-Compose $state @('up', '-d', '--wait', '--wait-timeout', '240') 'docker compose up'
    if ($r.ExitCode -ne 0) {
        Write-Host $r.Text -ForegroundColor Red
        $logs = Invoke-Compose $state @('logs', '--tail', '40') -Quiet
        Write-Host $logs.StdOut
        throw "Le run $Id n'a pas démarré (voir $(Join-Path $runsDir "$Id.log"))."
    }
    return $state
}

function Test-ComposeVersion {
    param($State, [string]$Service, [string[]]$Cmd, [string]$PolicyName, [string]$Item)
    $r = Invoke-Compose $State (@('exec', '-T', $Service) + $Cmd) -Quiet
    if ($r.ExitCode -ne 0) { Add-Finding -Item $Item -Status 'FAIL' -Detail "commande impossible dans le service $Service"; return }
    Add-VersionFinding -Name $PolicyName -Item $Item -Raw ($r.StdOut + $r.StdErr).Trim()
}

switch ($Action) {
    'up' {
        if (-not $RunId) { $RunId = 'run-' + (Get-Date -Format 'yyyyMMddHHmmss') }
        $s = Start-Run -Id $RunId -HostPort $Port
        Write-Host ''
        Write-Host "Instance prête : http://localhost:$($s.Port)   (run $($s.RunId), build $($s.BuildVersion))" -ForegroundColor Green
        Write-Host "Arrêt : .\run-instance.ps1 -Action down -RunId $($s.RunId) [-Purge]"
    }
    'status' {
        $s = Get-RunState $RunId
        (Invoke-Compose $s @('ps')).StdOut | Write-Host
    }
    'down' {
        $s = Get-RunState $RunId
        $a = @('down'); if ($Purge) { $a += '-v' }
        $r = Invoke-Compose $s $a 'docker compose down'
        if ($r.ExitCode -ne 0) { throw $r.Text }
        Write-Host "Run $($s.RunId) arrêté$(if ($Purge) { ' et volumes supprimés' })." -ForegroundColor Green
    }
    'smoke' {
        if (-not $RunId) { $RunId = 'smoke-' + (Get-Date -Format 'yyyyMMddHHmmss') }
        Write-Stage 'smoke' "SMOKE - run éphémère $RunId"
        $s = $null
        try {
            $s = Start-Run -Id $RunId -HostPort $Port
            Add-Finding -Item 'démarrage' -Status 'OK' -Detail "services healthy sur le port $($s.Port)"
            # versions EFFECTIVES, mesurées dans les conteneurs qui tournent
            Test-ComposeVersion $s 'postgres' @('postgres', '--version') 'PostgreSQL' 'PostgreSQL (effectif)'
            Test-ComposeVersion $s 'neo4j' @('neo4j', '--version') 'Neo4j' 'Neo4j (effectif)'
            Test-ComposeVersion $s 'backend' @('python', '--version') 'Python' 'Python backend (effectif)'
            try {
                $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$($s.Port)/" -TimeoutSec 20
                if ($resp.StatusCode -eq 200) { Add-Finding -Item 'frontend HTTP /' -Status 'OK' -Detail '200' } else { Add-Finding -Item 'frontend HTTP /' -Status 'FAIL' -Detail "$($resp.StatusCode)" }
            }
            catch { Add-Finding -Item 'frontend HTTP /' -Status 'FAIL' -Detail $_.Exception.Message }
        }
        catch { Add-Finding -Item 'smoke' -Status 'FAIL' -Detail $_.Exception.Message }
        finally {
            if ($s) { [void](Invoke-Compose $s @('down', '-v') -Quiet) }
        }
        # un smoke échoue sur FAIL et sur UPGRADE : l'instance livrée doit tourner sur les versions cibles
        $bad = @($script:Findings | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'UPGRADE' })
        exit $(if ($bad.Count -gt 0) { 1 } else { 0 })
    }
}
