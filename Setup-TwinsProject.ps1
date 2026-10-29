[CmdletBinding()]
param(
    [string]$RepositoryRoot = 'C:\workspace\DevConsole',
    [string]$BranchName = 'twins_project',
    [switch]$SkipBranchSetup,
    [switch]$AllowDirtyWorkingTree,
    [switch]$RunPreBuild,
    [switch]$NoInstall,
    [switch]$NoBuild,
    [switch]$RunTests
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-Exe([string[]]$Names) {
    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}
function Invoke-Native([string]$Exe,[string[]]$Args,[string]$Cwd) {
    Push-Location $Cwd
    try { & $Exe @Args; $rc = $LASTEXITCODE } finally { Pop-Location }
    if ($rc -ne 0) { throw "Commande en échec ($rc): $Exe $($Args -join ' ')" }
}
function Write-Phase([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw "Repository introuvable : $RepositoryRoot" }
$git = Find-Exe @('git.exe','git')
if (-not $git) { throw 'Git introuvable dans PATH.' }
$gitRoot = (& $git -C $RepositoryRoot rev-parse --show-toplevel 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or -not $gitRoot) { throw "Ce chemin n'est pas un dépôt Git : $RepositoryRoot" }
$RepositoryRoot = [IO.Path]::GetFullPath($gitRoot.Trim())

if (-not $SkipBranchSetup) {
    Write-Phase "Préparation de la branche $BranchName"
    $changes = @(& $git -C $RepositoryRoot status --porcelain)
    if ($changes.Count -gt 0 -and -not $AllowDirtyWorkingTree) {
        throw 'Working tree non propre. Committez/stashez les changements avant de créer/changer de branche. -AllowDirtyWorkingTree est réservé aux cas vérifiés.'
    }
    $current = (& $git -C $RepositoryRoot branch --show-current | Select-Object -First 1).Trim()
    $branchList = @(& $git -C $RepositoryRoot branch --list $BranchName)
    if ($current -eq $BranchName) {
        Write-Host "[OK] Déjà sur $BranchName" -ForegroundColor Green
    } elseif ($branchList.Count -gt 0) {
        Invoke-Native $git @('switch',$BranchName) $RepositoryRoot
    } else {
        Invoke-Native $git @('switch','-c',$BranchName) $RepositoryRoot
    }
}

$project = Join-Path $RepositoryRoot 'projects\twins_project'
$scripts = Join-Path $project 'scripts'
$build = Join-Path $project 'build'
foreach ($dir in @($scripts,$build,(Join-Path $build 'reports'),(Join-Path $build 'logs'))) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
$prebuildPath = Join-Path $scripts 'Invoke-TwinsPreBuild.ps1'

if (-not (Test-Path -LiteralPath $prebuildPath)) {
$prebuild = @'
[CmdletBinding()]
param(
    [string]$RepositoryRoot = 'C:\workspace\DevConsole',
    [switch]$NoInstall,
    [switch]$NoBuild,
    [switch]$RunTests
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$project = Join-Path $RepositoryRoot 'projects\twins_project'
$build = Join-Path $project 'build'
$reportDir = Join-Path $build 'reports'
$logDir = Join-Path $build 'logs'
$venv = Join-Path $build '.venv'
New-Item -ItemType Directory -Force -Path $reportDir,$logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $reportDir "prebuild-$stamp.json"
$logPath = Join-Path $logDir "prebuild-$stamp.log"
$findings = New-Object 'System.Collections.Generic.List[object]'
$started = Get-Date
$hadError = $false

function Add-Finding([string]$Area,[string]$Status,[string]$Observed,[string]$Expected,[string]$Evidence) {
    $findings.Add([pscustomobject]@{area=$Area;status=$Status;observed=$Observed;expected=$Expected;evidence=$Evidence}) | Out-Null
}
function Log([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 's'),$Message
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}
function Find-Exe([string[]]$Names) {
    foreach ($name in $Names) { $c=Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1; if($c){return $c.Source} }
    return $null
}
function Run-Cmd([string]$Exe,[string[]]$Args,[string]$Cwd,[switch]$AllowFailure) {
    Push-Location $Cwd
    try {
        & $Exe @Args 2>&1 | Tee-Object -FilePath $logPath -Append
        $rc = $LASTEXITCODE
    } finally { Pop-Location }
    if ($rc -ne 0 -and -not $AllowFailure) { throw "Échec ($rc) : $Exe $($Args -join ' ')" }
    return $rc
}
function Check-File([string]$Path,[string]$Area) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Add-Finding $Area 'FAIL' 'JSON invalide' 'Manifeste JSON valide' $Path; return }
    foreach ($section in @('dependencies','devDependencies')) {
        $map = $obj.$section
        if ($map) {
            foreach ($dep in $map.PSObject.Properties) {
                $v = [string]$dep.Value
                $status = if ($v -match '^(latest|[\^~*]|.*\bx\b)') {'REVIEW'} else {'DECLARED'}
                Add-Finding "$Area/$($dep.Name)" $status $v 'Version épinglée + lockfile cohérent' $Path
            }
        }
    }
}
try {
    Log "Twins Project pre-build; repository=$RepositoryRoot"
    $backend = Join-Path $RepositoryRoot 'backend'
    $frontend = Join-Path $RepositoryRoot 'frontend'
    if (-not (Test-Path $backend) -and -not (Test-Path $frontend)) { throw 'Ni backend/ ni frontend/ trouvé à la racine. Vérifier les chemins réels du projet.' }

    # Python runtime and dependency integrity
    $python = Find-Exe @('python.exe','python')
    if ($python) {
        $pyVersion = (& $python --version 2>&1 | Out-String).Trim()
        $pyMajorMinor = [regex]::Match($pyVersion,'Python (\d+\.\d+)').Groups[1].Value
        $pyStatus = if ($pyMajorMinor -and [version]$pyMajorMinor -ge [version]'3.14') {'PASS'} else {'REVIEW'}
        Add-Finding 'Python runtime' $pyStatus $pyVersion 'Python 3.14 minimum' $python
        if ((Test-Path $backend) -and -not $NoInstall) {
            if (-not (Test-Path $venv)) { & $python -m venv $venv; if($LASTEXITCODE -ne 0){throw 'Impossible de créer le virtualenv.'} }
            $vp = Join-Path $venv 'Scripts\python.exe'
            $uvLock = Join-Path $backend 'uv.lock'
            $requirements = Join-Path $backend 'requirements.txt'
            $pyproject = Join-Path $backend 'pyproject.toml'
            if (Test-Path $uvLock) {
                $uv = Find-Exe @('uv.exe','uv')
                if ($uv) { Run-Cmd $uv @('sync','--locked','--python',$vp) $backend | Out-Null }
                else { Add-Finding 'Python lockfile' 'BLOCKED' 'uv.lock détecté mais uv absent' 'Installer uv et synchroniser le lockfile' $uvLock }
            } elseif (Test-Path $requirements) {
                Run-Cmd $vp @('-m','pip','install','-r',$requirements) $backend | Out-Null
            } elseif (Test-Path $pyproject) {
                Run-Cmd $vp @('-m','pip','install','-e','.') $backend | Out-Null
            } else { Add-Finding 'Python dependencies' 'BLOCKED' 'Aucun uv.lock/requirements.txt/pyproject.toml' 'Déclarer et verrouiller les dépendances' $backend }
            Run-Cmd $vp @('-m','pip','check') $backend | Out-Null
            Run-Cmd $vp @('-m','compileall','-q','.') $backend | Out-Null
            if ($RunTests) { Run-Cmd $vp @('-m','pytest','-q') $backend -AllowFailure | Out-Null }
        } elseif ($NoInstall) { Add-Finding 'Python install' 'SKIPPED' 'NoInstall' 'Synchroniser les dépendances dans un environnement isolé' $backend }
    } else { Add-Finding 'Python runtime' 'BLOCKED' 'Python introuvable' 'Installer Python 3.14+' 'PATH' }

    # Node / Angular runtime, lockfile and compilation
    $pkgPath = Join-Path $frontend 'package.json'
    if (Test-Path $pkgPath) {
        $node = Find-Exe @('node.exe','node')
        $npm = Find-Exe @('npm.cmd','npm.exe','npm')
        $nodeVersion = if($node){(& $node --version 2>&1 | Out-String).Trim()}else{'introuvable'}
        Add-Finding 'Node runtime' $(if($nodeVersion -match '^v26\.'){'PASS'}else{'REVIEW'}) $nodeVersion 'Node 26 LTS' $node
        Check-File $pkgPath 'Frontend dependency'
        $pkg = Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $angular = [string]$pkg.dependencies.'@angular/core'
        Add-Finding 'Angular version' $(if($angular -match '(^|[^0-9])22(\.|$)'){'PASS'}else{'REVIEW'}) $angular 'Angular 22 (pas de montée demandée)' $pkgPath
        if (-not $NoInstall -and $npm) {
            $lock = Join-Path $frontend 'package-lock.json'
            if (Test-Path $lock) { Run-Cmd $npm @('ci','--no-audit','--no-fund') $frontend | Out-Null }
            else { Add-Finding 'npm reproducibility' 'BLOCKED' 'package-lock.json absent' 'Générer/revoir et committer package-lock.json ; npm ci requis' $frontend }
            if (-not $NoBuild) {
                if ($pkg.scripts.build) { Run-Cmd $npm @('run','build') $frontend | Out-Null }
                else { Add-Finding 'Angular build' 'BLOCKED' 'Script npm build absent' 'Déclarer la commande de build de production' $pkgPath }
            }
            if ($RunTests -and $pkg.scripts.test) { Run-Cmd $npm @('test','--','--watch=false') $frontend -AllowFailure | Out-Null }
        } elseif ($NoInstall) { Add-Finding 'Frontend install/build' 'SKIPPED' 'NoInstall' 'npm ci puis build de production' $frontend }
    } else { Add-Finding 'Frontend manifest' 'REVIEW' 'frontend/package.json absent' 'Vérifier le chemin réel du frontend' $frontend }

    # Static infrastructure inventory. This never upgrades or migrates data.
    $compose = @(Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(docker-compose|compose)\.(yml|yaml)$' -and $_.FullName -notmatch '[\\/](node_modules|\.git|build|dist)[\\/]' })
    foreach ($file in $compose) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($match in [regex]::Matches($text,'(?m)^\s*image:\s*["'']?(neo4j|postgres):([^\s"'']+)')) {
            $name = $match.Groups[1].Value
            $tag = "$name`:$($match.Groups[2].Value)"
            if ($name -eq 'neo4j') {
                Add-Finding 'Neo4j image' $(if($tag -match '^neo4j:5\.26(\.|$|-)'){'PASS'}else{'REVIEW'}) $tag 'Neo4j 5.26 LTS' $file.FullName
            } else {
                Add-Finding 'PostgreSQL image' $(if($tag -match '^postgres:18(\.|$|-)'){'PASS'}else{'REVIEW'}) $tag 'PostgreSQL 18 ; migration de données planifiée séparément' $file.FullName
            }
        }
    }
    if (-not $compose) { Add-Finding 'Database image inventory' 'REVIEW' 'Aucun Compose YAML trouvé' 'Vérifier les manifests de déploiement utilisés' $RepositoryRoot }

    $docker = Find-Exe @('docker.exe','docker')
    if ($docker) {
        $dv = (& $docker version --format '{{.Client.Version}}' 2>$null | Select-Object -First 1)
        Add-Finding 'Docker CLI' $(if($LASTEXITCODE -eq 0){'PASS'}else{'REVIEW'}) ([string]$dv) 'Docker CLI disponible si Compose est utilisé' $docker
        $cv = (& $docker compose version --short 2>$null | Select-Object -First 1)
        Add-Finding 'Docker Compose' $(if($LASTEXITCODE -eq 0){'PASS'}else{'REVIEW'}) ([string]$cv) 'Docker Compose disponible si Compose est utilisé' $docker
    } else { Add-Finding 'Docker CLI' 'REVIEW' 'Introuvable' 'Installer/configurer Docker si requis par le projet' 'PATH' }

} catch {
    $hadError = $true
    Log "FAIL: $($_.Exception.Message)"
    Add-Finding 'Pre-build execution' 'FAIL' $_.Exception.Message 'Corriger avant livraison' $logPath
} finally {
    $duration = [math]::Round(((Get-Date)-$started).TotalSeconds,2)
    $summary = [pscustomobject]@{
        total=$findings.Count
        pass=@($findings|Where-Object status -eq 'PASS').Count
        review=@($findings|Where-Object status -eq 'REVIEW').Count
        blocked=@($findings|Where-Object status -eq 'BLOCKED').Count
        fail=@($findings|Where-Object status -eq 'FAIL').Count
    }
    $branch = (& git -C $RepositoryRoot branch --show-current 2>$null | Select-Object -First 1)
    $commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    [pscustomobject]@{
        schemaVersion='1.0'; project='Twins Project'; generatedAt=(Get-Date).ToString('o')
        repositoryRoot=$RepositoryRoot; gitBranch=$branch; gitCommit=$commit; durationSeconds=$duration
        result=if($hadError -or $summary.blocked -gt 0 -or $summary.fail -gt 0){'FAIL'}else{'REVIEW_REQUIRED'}
        summary=$summary; findings=@($findings)
        notes=@(
            'Les versions déclarées ne prouvent pas seules la compatibilité ; confirmer par tests de build et intégration.',
            'PostgreSQL 15 vers 18 exige un plan pg_upgrade ou export/import, une sauvegarde et un test de restauration.',
            'Neo4j 5.26 LTS est ciblé ; Neo4j 2026.x est hors périmètre.',
            'Aucune migration de données ni démarrage de service n’est exécuté automatiquement.'
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Log "Rapport : $reportPath ; durée : $duration s"
    $findings | Format-Table area,status,observed,expected -AutoSize | Out-String -Width 220 | Write-Host
}
if ($hadError -or @($findings|Where-Object {$_.status -in @('FAIL','BLOCKED')}).Count -gt 0) { exit 1 }
exit 0
'@
    Set-Content -LiteralPath $prebuildPath -Value $prebuild -Encoding UTF8
    Write-Host "[OK] Pre-build créé : $prebuildPath" -ForegroundColor Green
} else {
    Write-Host "[INFO] Pre-build existant conservé : $prebuildPath" -ForegroundColor Yellow
}

$readme = Join-Path $project 'README.md'
if (-not (Test-Path $readme)) {
@'
# Twins Project — pre-build global

Ce module complète le build/run composant par un contrôle au niveau solution : inventaire de versions, validation de l'environnement Python, contrôle pip, installation npm reproductible, compilation Angular et rapport JSON horodaté.

## Commandes

```powershell
# Setup de la branche et génération du module
.\Setup-TwinsProject.ps1

# Scan + build (depuis la racine DevConsole)
.\projects\twins_project\scripts\Invoke-TwinsPreBuild.ps1 -RepositoryRoot C:\workspace\DevConsole

# Scan sans installation ni build
.\projects\twins_project\scripts\Invoke-TwinsPreBuild.ps1 -RepositoryRoot C:\workspace\DevConsole -NoInstall -NoBuild

# Ajouter les tests lorsqu'ils sont configurés
.\projects\twins_project\scripts\Invoke-TwinsPreBuild.ps1 -RepositoryRoot C:\workspace\DevConsole -RunTests
```

Les virtualenvs, rapports et logs sont sous `projects/twins_project/build/`, hors des répertoires de code.

## Cibles
- Python 3.14 minimum (attendre avant Python 3.15).
- Node 26 LTS ; conserver Angular 22.
- Neo4j 5.26 LTS ; Neo4j 2026.x est hors périmètre.
- PostgreSQL 18 ; prévoir une migration de données distincte.
- Le scan n'effectue aucune mise à niveau de framework ni migration de données.
'@ | Set-Content -LiteralPath $readme -Encoding UTF8
}
$ignore = Join-Path $project '.gitignore'
if (-not (Test-Path $ignore)) { "build/`n.venv/`n__pycache__/`n*.py[cod]" | Set-Content -LiteralPath $ignore -Encoding UTF8 }

if ($RunPreBuild) {
    Write-Phase 'Exécution du pré-build'
    $ps = Find-Exe @('powershell.exe','pwsh.exe')
    if (-not $ps) { throw 'PowerShell introuvable.' }
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$prebuildPath,'-RepositoryRoot',$RepositoryRoot)
    if ($NoInstall) { $args += '-NoInstall' }
    if ($NoBuild) { $args += '-NoBuild' }
    if ($RunTests) { $args += '-RunTests' }
    Invoke-Native $ps $args $RepositoryRoot
}

Write-Phase 'Setup terminé'
Write-Host "Branche : $BranchName"
Write-Host "Pre-build : $prebuildPath"
Write-Host "Pour lancer : .\projects\twins_project\scripts\Invoke-TwinsPreBuild.ps1 -RepositoryRoot `"$RepositoryRoot`""
Write-Host 'Le routeur dev.ps1 / CLI lab n’est pas modifié automatiquement : il faut inspecter son parser et ses tests avant d’y raccorder une commande native.' -ForegroundColor Yellow
