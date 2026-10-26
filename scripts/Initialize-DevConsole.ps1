[CmdletBinding()]
param(
    [string]$Workspace = 'C:\workspace'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$Root = Split-Path -Parent $PSScriptRoot
$ReportDirectory = Join-Path $Root 'reports'
$ReportPath = Join-Path $ReportDirectory 'init-report.json'

New-Item -ItemType Directory -Path $ReportDirectory -Force |
    Out-Null

$ToolNames = @(
    'pwsh', 'powershell', 'git', 'gh', 'ssh', 'curl', 'jq',
    'python', 'py', 'pip', 'uv', 'poetry', 'pipx',
    'java', 'javac', 'mvn', 'gradle',
    'node', 'npm', 'pnpm', 'yarn', 'tsc', 'ng',
    'docker', 'podman', 'kubectl', 'helm', 'kind', 'minikube',
    'gitlab-runner', 'terraform', 'ansible', 'make', 'cmake',
    'dotnet', 'go', 'cargo', 'code'
)

$Tools = foreach ($name in $ToolNames) {
    $command = Get-Command $name -ErrorAction SilentlyContinue |
        Select-Object -First 1

    [pscustomobject]@{
        Name      = $name
        Installed = [bool]$command
        Path      = if ($command) { $command.Source } else { $null }
        Version   = $null
    }
}

$Markers = @(
    '.git',
    '.gitlab-ci.yml',
    'Dockerfile',
    'compose.yaml',
    'docker-compose.yml',
    'pyproject.toml',
    'requirements.txt',
    'package.json',
    'pom.xml',
    'build.gradle',
    'build.gradle.kts'
)

$ProjectMarkers = foreach ($marker in $Markers) {
    $path = Join-Path $Workspace $marker
    [pscustomobject]@{
        Marker  = $marker
        Present = Test-Path -LiteralPath $path
        Path    = $path
    }
}

$report = [ordered]@{
    generatedAt   = (Get-Date).ToString('o')
    computerName  = $env:COMPUTERNAME
    userName      = $env:USERNAME
    workspace     = $Workspace
    powershell    = $PSVersionTable.PSVersion.ToString()
    tools         = @($Tools)
    projectMarkers = @($ProjectMarkers)
    note          = 'Inventaire en lecture seule : aucun logiciel installÃ© ou supprimÃ©.'
}

$report | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $ReportPath -Encoding UTF8

$installedCount = @($Tools | Where-Object Installed).Count
$missingCount = @($Tools | Where-Object { -not $_.Installed }).Count
$markerCount = @($ProjectMarkers | Where-Object Present).Count

Write-Host ''
Write-Host '===== INVENTAIRE DEVCONSOLE =====' -ForegroundColor Cyan
Write-Host "Workspace            : $Workspace"
Write-Host "Outils dÃ©tectÃ©s      : $installedCount"
Write-Host "Outils absents       : $missingCount"
Write-Host "Marqueurs de projet  : $markerCount / $($Markers.Count)"
Write-Host "Rapport JSON         : $ReportPath"
Write-Host ''
Write-Host 'Outils prÃ©sents :' -ForegroundColor Green

$Tools |
    Where-Object Installed |
    ForEach-Object {
        Write-Host ("  + {0} : {1}" -f $_.Name, $_.Path)
    }

Write-Host ''
Write-Host 'Outils absents du PATH :' -ForegroundColor Yellow

$Tools |
    Where-Object { -not $_.Installed } |
    ForEach-Object {
        Write-Host ("  - {0}" -f $_.Name)
    }

Write-Host ''
Write-Host 'Aucune installation ni suppression effectuÃ©e.'