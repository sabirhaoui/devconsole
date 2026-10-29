#Requires -Version 5.1
<#
.SYNOPSIS
  Chaîne d'assemblage de la solution twins_project complète :
  scan -> resolve -> compile -> test -> package -> deliver.

.DESCRIPTION
  Chaque étape est une porte de qualité : si elle produit un FAIL, la chaîne s'arrête.
  Le build part d'un COMMIT (git worktree jetable), jamais du dossier de travail, avec son
  propre venv Python et son propre node_modules : deux builds ne partagent aucun état.
  Le livrable est un dossier immuable (build-version = date du commit + sha) contenant les
  images Docker, le compose, le manifeste de traçabilité et run-instance.ps1 pour l'exécuter.

.PARAMETER UpTo
  Dernière étape à exécuter. 'scan' = pré-build seul (aucun worktree, aucune installation).

.EXAMPLE
  .\twins-assemble.ps1 -UpTo scan                 # le setup du prebuild : outils et versions déclarées
  .\twins-assemble.ps1 -UpTo compile -SkipTests   # inventaire + compilation, sans Docker
  .\twins-assemble.ps1                            # chaîne complète jusqu'à la livraison
  .\twins-assemble.ps1 -Strict                    # UPGRADE et WARN deviennent bloquants
#>
[CmdletBinding()]
param(
    [ValidateSet('scan', 'resolve', 'compile', 'test', 'package', 'deliver')]
    [string]$UpTo = 'deliver',
    [string]$TwinsRoot = $(if ($env:TWINS_ROOT) { $env:TWINS_ROOT } else { 'C:\workspace\twins_project' }),
    [string]$Ref = 'HEAD',
    [string]$OutRoot,
    [switch]$Strict,
    [switch]$IgnoreDirty,
    [switch]$SkipTests,
    [switch]$AllowTestFailures,
    [hashtable]$TestEnv = @{},
    [switch]$Audit,
    [switch]$NoCache,
    [switch]$NoSmoke,
    [switch]$ExportImages,
    [switch]$KeepSource,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'twins-common.ps1')
Import-Policy -Path (Join-Path $PSScriptRoot 'versions.psd1')

$Order = @('scan', 'resolve', 'compile', 'test', 'package', 'deliver')
function Test-StageEnabled { param([string]$Key) return ($Order.IndexOf($Key) -le $Order.IndexOf($UpTo)) }

$GitExe = Resolve-Exe 'git'
if (-not $GitExe) { throw 'git est introuvable dans le PATH.' }
function Invoke-Git {
    param([string[]]$GitArgs, [string]$Dir = $TwinsRoot)
    return Invoke-Native -File $GitExe -Arguments (@('-C', $Dir) + $GitArgs) -Quiet
}

# ====================================================================== SCAN (pré-build)
function Find-Python {
    $cands = @()
    $launcher = Resolve-Exe 'py'
    if ($launcher) { foreach ($v in '3.14', '3.13', '3.12', '3.11') { $cands += , @{ File = $launcher; Pre = @("-$v") } } }
    foreach ($n in 'python3.14', 'python3', 'python') { $e = Resolve-Exe $n; if ($e) { $cands += , @{ File = $e; Pre = @() } } }
    $found = @()
    foreach ($c in $cands) {
        $r = Invoke-Native -File $c.File -Arguments ($c.Pre + @('-c', "import sys; print('.'.join(map(str, sys.version_info[:3])))")) -Quiet
        if ($r.ExitCode -eq 0 -and (ConvertTo-Ver $r.StdOut)) {
            $found += [pscustomobject]@{ File = $c.File; Pre = $c.Pre; Version = $r.StdOut.Trim(); Display = (($c.File + ' ' + ($c.Pre -join ' ')).Trim()) }
        }
    }
    if ($found.Count -eq 0) { return $null }
    $ceiling = ConvertTo-Ver $script:Policy['Python'].Ceiling
    $allowed = @($found | Where-Object { (ConvertTo-Ver $_.Version) -lt $ceiling })
    if ($allowed.Count -eq 0) { $allowed = $found }
    return ($allowed | Sort-Object { ConvertTo-Ver $_.Version } -Descending | Select-Object -First 1)
}

function Invoke-ScanStage {
    Write-Stage 'scan' 'SCAN - outils effectifs et versions déclarées'
    $needDocker = Test-StageEnabled 'package'

    # --- outils présents sur le poste
    Add-Finding -Item 'git' -Status 'OK' -Detail ((Invoke-Native -File $GitExe -Arguments @('--version') -Quiet).StdOut.Trim())
    $nodeExe = Resolve-Exe 'node'
    if ($nodeExe) { Add-VersionFinding -Name 'Node' -Item 'node (poste)' -Raw ((Invoke-Native -File $nodeExe -Arguments @('--version') -Quiet).StdOut.Trim()) }
    else { Add-Finding -Item 'node (poste)' -Status 'FAIL' -Detail 'introuvable dans le PATH' }
    $npmExe = Resolve-Exe 'npm'
    if ($npmExe) { Add-Finding -Item 'npm' -Status 'OK' -Detail ((Invoke-Native -File $npmExe -Arguments @('--version') -Quiet).StdOut.Trim()) }
    else { Add-Finding -Item 'npm' -Status 'FAIL' -Detail 'introuvable dans le PATH' }

    $script:Python = Find-Python
    if ($script:Python) { Add-VersionFinding -Name 'Python' -Item ('python (poste) : ' + $script:Python.Display) -Raw $script:Python.Version }
    else { Add-Finding -Item 'python (poste)' -Status 'FAIL' -Detail 'aucun interpréteur trouvé (py -3.14, python3, python)' }

    $dockerExe = Resolve-Exe 'docker'
    $dockerStatus = 'WARN'; if ($needDocker) { $dockerStatus = 'FAIL' }
    if ($dockerExe) {
        $dv = Invoke-Native -File $dockerExe -Arguments @('version', '--format', '{{.Server.Version}}') -Quiet
        if ($dv.ExitCode -eq 0) { Add-Finding -Item 'docker (moteur)' -Status 'OK' -Detail $dv.StdOut.Trim() }
        else { Add-Finding -Item 'docker (moteur)' -Status $dockerStatus -Detail 'installé mais moteur injoignable (Docker Desktop démarré ?)' }
        $dc = Invoke-Native -File $dockerExe -Arguments @('compose', 'version', '--short') -Quiet
        if ($dc.ExitCode -eq 0) { Add-Finding -Item 'docker compose' -Status 'OK' -Detail $dc.StdOut.Trim() }
        else { Add-Finding -Item 'docker compose' -Status $dockerStatus -Detail 'plugin compose v2 absent' }
    }
    else { Add-Finding -Item 'docker' -Status $dockerStatus -Detail 'introuvable (requis pour package/deliver)' }

    # --- fichiers de dépendances déclarés dans le dépôt
    $be = Join-Path $script:SrcRoot 'backend'
    $fe = Join-Path $script:SrcRoot 'frontend'

    $reqFiles = @()
    if (Test-Path -LiteralPath $be) { $reqFiles = @(Get-ChildItem -LiteralPath $be -Filter 'requirements*.txt' -File) }
    if ($reqFiles.Count -eq 0) { Add-Finding -Item 'backend/requirements*.txt' -Status 'FAIL' -Detail 'aucun fichier de dépendances Python' }
    foreach ($f in $reqFiles) {
        $lines = @(Get-Content -LiteralPath $f.FullName | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') -and -not $_.StartsWith('-') })
        $loose = @($lines | Where-Object { $_ -notmatch '==' })
        if ($loose.Count -eq 0) { Add-Finding -Item "backend/$($f.Name)" -Status 'OK' -Detail "$($lines.Count) dépendances, toutes épinglées (==)" }
        else {
            $sample = ($loose | Select-Object -First 5) -join ', '
            Add-Finding -Item "backend/$($f.Name)" -Status 'WARN' -Detail "$($loose.Count)/$($lines.Count) non épinglées (build non reproductible) : $sample"
        }
    }

    $pyproject = Join-Path $be 'pyproject.toml'
    if (Test-Path -LiteralPath $pyproject) {
        $t = Get-Content -Raw -LiteralPath $pyproject
        if ($t -match 'requires-python\s*=\s*"([^"]+)"') {
            $req = $Matches[1]
            $reqVer = ConvertTo-Ver $req
            $target = ConvertTo-Ver $script:Policy['Python'].Target
            if ($reqVer -and $reqVer -lt $target) { Add-Finding -Item 'pyproject.toml requires-python' -Status 'UPGRADE' -Detail "$req : à relever à >=$($script:Policy['Python'].Target)" }
            else { Add-Finding -Item 'pyproject.toml requires-python' -Status 'OK' -Detail $req }
        }
    }

    foreach ($vf in @('.python-version', '.nvmrc', 'frontend/.nvmrc', 'backend/.python-version')) {
        $p = Join-Path $script:SrcRoot $vf
        if (Test-Path -LiteralPath $p) {
            $raw = (Get-Content -LiteralPath $p -TotalCount 1).Trim()
            $name = 'Python'; if ($vf -like '*nvmrc') { $name = 'Node' }
            Add-VersionFinding -Name $name -Item "$vf (épinglage du dépôt)" -Raw $raw
        }
    }

    $pkgPath = Join-Path $fe 'package.json'
    if (-not (Test-Path -LiteralPath $pkgPath)) { Add-Finding -Item 'frontend/package.json' -Status 'FAIL' -Detail 'introuvable' }
    else {
        $pkg = Get-Content -Raw -LiteralPath $pkgPath | ConvertFrom-Json
        if (Test-Path -LiteralPath (Join-Path $fe 'package-lock.json')) { Add-Finding -Item 'frontend/package-lock.json' -Status 'OK' -Detail 'présent (npm ci possible)' }
        else { Add-Finding -Item 'frontend/package-lock.json' -Status 'FAIL' -Detail 'absent : npm ci impossible, build non reproductible' }
        $ng = $null
        foreach ($sect in 'dependencies', 'devDependencies') { if ($pkg.PSObject.Properties[$sect] -and $pkg.$sect.PSObject.Properties['@angular/core']) { $ng = $pkg.$sect.'@angular/core' } }
        if ($ng) { Add-VersionFinding -Name 'Angular' -Item '@angular/core (déclaré)' -Raw $ng } else { Add-Finding -Item '@angular/core' -Status 'WARN' -Detail 'non déclaré dans package.json' }
        if ($pkg.PSObject.Properties['engines'] -and $pkg.engines.PSObject.Properties['node']) { Add-Finding -Item 'package.json engines.node' -Status 'INFO' -Detail ([string]$pkg.engines.node) }
        else { Add-Finding -Item 'package.json engines.node' -Status 'WARN' -Detail "absent : ajouter engines.node >=$($script:Policy['Node'].Target) et engine-strict=true dans .npmrc" }
        if (-not ($pkg.PSObject.Properties['scripts'] -and $pkg.scripts.PSObject.Properties['build'])) { Add-Finding -Item 'package.json scripts.build' -Status 'FAIL' -Detail 'script build absent' }
    }

    # --- images déclarées (compose + Dockerfile) : fichiers suivis par git uniquement
    $ls = Invoke-Git @('ls-files', '--', '*docker-compose*', '*compose*.yml', '*compose*.yaml', '*Dockerfile*') $script:SrcRoot
    $files = @($ls.StdOut -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($files.Count -eq 0) { Add-Finding -Item 'compose / Dockerfile' -Status 'INFO' -Detail 'aucun fichier suivi par git' }
    foreach ($rel in $files) {
        $full = Join-Path $script:SrcRoot $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        foreach ($l in Get-Content -LiteralPath $full) {
            if ($l -match '^\s*image:\s*["'']?([^\s"''#]+)') { Add-ImageFinding -Where $rel -Ref $Matches[1] }
            elseif ($l -match '^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)') { Add-ImageFinding -Where $rel -Ref $Matches[1] }
        }
    }
}

# ====================================================================== RESOLVE (inventaire)
function Get-PipFailures {
    param([string]$Text)
    $res = @()
    foreach ($m in [regex]::Matches($Text, 'Failed building wheel for (\S+)')) { $res += "wheel non construit : $($m.Groups[1].Value)" }
    foreach ($m in [regex]::Matches($Text, 'No matching distribution found for (\S+)')) { $res += "aucune distribution pour : $($m.Groups[1].Value)" }
    foreach ($m in [regex]::Matches($Text, 'Could not find a version that satisfies the requirement (\S+)')) { $res += "version introuvable : $($m.Groups[1].Value)" }
    if ($res.Count -eq 0) { foreach ($m in ([regex]::Matches($Text, '(?m)^ERROR: .+$') | Select-Object -First 3)) { $res += $m.Value } }
    return ($res | Select-Object -Unique)
}

function Invoke-ResolveStage {
    Write-Stage 'resolve' 'RESOLVE - installation isolée et inventaire des dépendances'
    $log = Join-Path $script:LogDir 'resolve.log'
    $be = Join-Path $script:SrcRoot 'backend'
    $fe = Join-Path $script:SrcRoot 'frontend'
    $py = $script:Python
    if (-not $py) { Add-Finding -Item 'backend' -Status 'FAIL' -Detail 'aucun interpréteur Python'; return }

    # ---- backend : venv neuf, propre à ce build
    $r = Invoke-Native -File $py.File -Arguments ($py.Pre + @('-m', 'venv', $script:Venv)) -Log $log -Label 'création du venv'
    $vpy = Join-Path $script:Venv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $vpy)) { $vpy = Join-Path $script:Venv 'bin/python' }
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $vpy)) { Add-Finding -Item 'backend venv' -Status 'FAIL' -Detail "création impossible (voir $log)"; return }
    $script:VenvPython = $vpy

    $pipArgs = @('-m', 'pip', 'install', '--disable-pip-version-check', '-r', 'requirements.txt')
    if (Test-Path -LiteralPath (Join-Path $be 'requirements-dev.txt')) { $pipArgs += @('-r', 'requirements-dev.txt') }
    $r = Invoke-Native -File $vpy -Arguments $pipArgs -WorkDir $be -Env @{ PIP_NO_INPUT = '1' } -Log $log -Label 'pip install'
    if ($r.ExitCode -ne 0) {
        $why = (Get-PipFailures $r.Text) -join ' ; '
        Add-Finding -Item 'backend pip install' -Status 'FAIL' -Detail ("échec avec Python $($py.Version) : $why (voir $log)")
        return
    }
    Add-Finding -Item 'backend pip install' -Status 'OK' -Detail "dépendances installées avec Python $($py.Version)"

    $chk = Invoke-Native -File $vpy -Arguments @('-m', 'pip', 'check') -WorkDir $be -Log $log -Quiet
    if ($chk.ExitCode -eq 0) { Add-Finding -Item 'backend pip check' -Status 'OK' -Detail 'aucun conflit de dépendances' }
    else { Add-Finding -Item 'backend pip check' -Status 'FAIL' -Detail (($chk.StdOut.Trim() -split "`n" | Select-Object -First 3) -join ' | ') }

    $lst = Invoke-Native -File $vpy -Arguments @('-m', 'pip', 'list', '--format=json', '--disable-pip-version-check') -WorkDir $be -Log $log -Quiet
    $backendInv = @()
    if ($lst.ExitCode -eq 0) { $backendInv = @($lst.StdOut | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ name = $_.name; version = $_.version } }) }
    $script:Inventory.backend = $backendInv
    Add-Finding -Item 'backend inventaire' -Status 'INFO' -Detail "$($backendInv.Count) paquets Python installés"

    $frz = Invoke-Native -File $vpy -Arguments @('-m', 'pip', 'freeze', '--all') -WorkDir $be -Log $log -Quiet
    if ($frz.ExitCode -eq 0) { [System.IO.File]::WriteAllText((Join-Path $script:ReportDir 'backend-host-freeze.txt'), $frz.StdOut) }

    $old = Invoke-Native -File $vpy -Arguments @('-m', 'pip', 'list', '--outdated', '--format=json', '--disable-pip-version-check') -WorkDir $be -Log $log -Label 'pip outdated'
    if ($old.ExitCode -eq 0) {
        $o = @($old.StdOut | ConvertFrom-Json)
        $script:Inventory.backendOutdated = @($o | ForEach-Object { [pscustomobject]@{ name = $_.name; version = $_.version; latest = $_.latest_version } })
        Add-Finding -Item 'backend dépendances en retard' -Status 'INFO' -Detail "$($o.Count) paquets ont une version plus récente (voir inventory.json)"
    }

    # ---- frontend : npm ci depuis le lockfile, dans le worktree
    $npm = Resolve-Exe 'npm'
    $node = Resolve-Exe 'node'
    if (-not $npm -or -not $node) { Add-Finding -Item 'frontend' -Status 'FAIL' -Detail 'node/npm introuvables'; return }
    $npmEnv = @{ CI = 'true'; NPM_CONFIG_UPDATE_NOTIFIER = 'false'; NPM_CONFIG_FUND = 'false' }
    $r = Invoke-Native -File $npm -Arguments @('ci', '--no-audit', '--no-fund') -WorkDir $fe -Env $npmEnv -Log $log -Label 'npm ci'
    if ($r.ExitCode -ne 0) {
        $errs = @($r.Text -split "`n" | Where-Object { $_ -match 'npm error|ERESOLVE|ETARGET|E404' } | Select-Object -First 3) -join ' | '
        Add-Finding -Item 'frontend npm ci' -Status 'FAIL' -Detail "$errs (voir $log)"
        return
    }
    Add-Finding -Item 'frontend npm ci' -Status 'OK' -Detail 'dépendances installées depuis package-lock.json'

    $engine = @([regex]::Matches($r.Text, "package: '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($engine.Count -gt 0) { Add-Finding -Item 'frontend engines (EBADENGINE)' -Status 'WARN' -Detail ("$($engine.Count) paquets refusent le Node courant : " + (($engine | Select-Object -First 5) -join ', ')) }
    else { Add-Finding -Item 'frontend engines' -Status 'OK' -Detail 'aucun paquet n''exclut le Node courant' }

    $ngPkg = Join-Path $fe 'node_modules/@angular/core/package.json'
    if (Test-Path -LiteralPath $ngPkg) { Add-VersionFinding -Name 'Angular' -Item '@angular/core (installé)' -Raw ((Get-Content -Raw -LiteralPath $ngPkg | ConvertFrom-Json).version) }

    $ls = Invoke-Native -File $npm -Arguments @('ls', '--all') -WorkDir $fe -Env $npmEnv -Log $log -Label 'npm ls'
    $problems = @($ls.Text -split "`n" | Where-Object { $_ -match 'invalid|missing|extraneous|UNMET' })
    if ($ls.ExitCode -eq 0 -and $problems.Count -eq 0) { Add-Finding -Item 'frontend npm ls' -Status 'OK' -Detail 'arbre de dépendances cohérent' }
    else { Add-Finding -Item 'frontend npm ls' -Status 'FAIL' -Detail ("$($problems.Count) problèmes : " + (($problems | Select-Object -First 3 | ForEach-Object { $_.Trim() }) -join ' | ')) }

    # inventaire lu dans le lockfile par node (évite la limite de 2 Mo de ConvertFrom-Json sous PS 5.1)
    $tool = Join-Path $script:ToolDir 'lock-inventory.js'
    $js = "const fs=require('fs');const l=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const o=[];" +
          "for(const [k,v] of Object.entries(l.packages||{})){if(!k)continue;o.push({name:v.name||k.split('node_modules/').pop(),version:v.version,dev:!!v.dev});}" +
          "process.stdout.write(JSON.stringify(o));"
    [System.IO.File]::WriteAllText($tool, $js)
    $inv = Invoke-Native -File $node -Arguments @($tool, (Join-Path $fe 'package-lock.json')) -WorkDir $fe -Log $log -Quiet
    if ($inv.ExitCode -eq 0) {
        $feInv = @($inv.StdOut | ConvertFrom-Json)
        $script:Inventory.frontend = $feInv
        $prod = @($feInv | Where-Object { -not $_.dev }).Count
        Add-Finding -Item 'frontend inventaire' -Status 'INFO' -Detail "$($feInv.Count) paquets npm ($prod runtime, $($feInv.Count - $prod) dev)"
    }

    $outd = Invoke-Native -File $npm -Arguments @('outdated', '--json') -WorkDir $fe -Env $npmEnv -Log $log -Label 'npm outdated'
    if ($outd.StdOut.Trim().StartsWith('{')) {
        $o = $outd.StdOut | ConvertFrom-Json
        $rows = @($o.PSObject.Properties | ForEach-Object { [pscustomobject]@{ name = $_.Name; current = $_.Value.current; wanted = $_.Value.wanted; latest = $_.Value.latest } })
        $script:Inventory.frontendOutdated = $rows
        $major = @($rows | Where-Object { $_.current -and $_.latest -and (ConvertTo-Ver $_.latest).Major -gt (ConvertTo-Ver $_.current).Major })
        Add-Finding -Item 'frontend dépendances directes en retard' -Status 'INFO' -Detail "$($rows.Count) en retard dont $($major.Count) d'une version majeure"
    }

    if ($Audit) {
        $au = Invoke-Native -File $npm -Arguments @('audit', '--json') -WorkDir $fe -Env $npmEnv -Log $log -Label 'npm audit'
        try {
            $v = ($au.StdOut | ConvertFrom-Json).metadata.vulnerabilities
            $st = 'OK'; if ($v.critical -gt 0 -or $v.high -gt 0) { $st = 'WARN' }
            Add-Finding -Item 'frontend npm audit' -Status $st -Detail "critique=$($v.critical) haute=$($v.high) moyenne=$($v.moderate) basse=$($v.low)"
        }
        catch { Add-Finding -Item 'frontend npm audit' -Status 'WARN' -Detail 'résultat illisible (registre injoignable ?)' }
    }
}

# ====================================================================== COMPILE
function Invoke-CompileStage {
    Write-Stage 'compile' 'COMPILE - la solution complète compile-t-elle ?'
    $log = Join-Path $script:LogDir 'compile.log'
    $be = Join-Path $script:SrcRoot 'backend'
    $fe = Join-Path $script:SrcRoot 'frontend'

    if ($script:VenvPython) {
        $r = Invoke-Native -File $script:VenvPython -Arguments @('-m', 'compileall', '-q', 'app') -WorkDir $be -Log $log -Label 'compileall backend'
        if ($r.ExitCode -eq 0) { Add-Finding -Item 'backend compileall' -Status 'OK' -Detail 'tous les modules app/ compilent' }
        else { Add-Finding -Item 'backend compileall' -Status 'FAIL' -Detail (($r.Text.Trim() -split "`n" | Select-Object -First 3) -join ' | ') }
        $r = Invoke-Native -File $script:VenvPython -Arguments @('-c', 'import app.main') -WorkDir $be -Env @{ PYTHONPATH = $be } -Log $log -Quiet
        if ($r.ExitCode -eq 0) { Add-Finding -Item 'backend import app.main' -Status 'OK' -Detail 'l''application s''importe' }
        else { Add-Finding -Item 'backend import app.main' -Status 'WARN' -Detail ('import impossible (variables d''environnement requises ?) : ' + (($r.StdErr.Trim() -split "`n" | Select-Object -Last 1))) }
    }
    else { Add-Finding -Item 'backend compile' -Status 'FAIL' -Detail 'venv absent : étape resolve non réussie' }

    $npm = Resolve-Exe 'npm'
    if ($npm -and (Test-Path -LiteralPath (Join-Path $fe 'node_modules'))) {
        $r = Invoke-Native -File $npm -Arguments @('run', 'build') -WorkDir $fe -Env @{ CI = 'true'; NG_CLI_ANALYTICS = 'false'; NPM_CONFIG_UPDATE_NOTIFIER = 'false' } -Log $log -Label 'npm run build'
        if ($r.ExitCode -ne 0) {
            $errs = @($r.Text -split "`n" | Where-Object { $_ -match 'error|Error' } | Select-Object -First 3 | ForEach-Object { $_.Trim() }) -join ' | '
            Add-Finding -Item 'frontend build' -Status 'FAIL' -Detail "$errs (voir $log)"
        }
        else {
            $idx = Get-ChildItem -LiteralPath (Join-Path $fe 'dist') -Recurse -Filter 'index.html' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($idx) {
                $size = (Get-ChildItem -LiteralPath $idx.DirectoryName -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
                Add-Finding -Item 'frontend build' -Status 'OK' -Detail ('livrable statique : {0} ({1:n1} Mo)' -f $idx.DirectoryName.Substring($script:SrcRoot.Length).TrimStart('\', '/'), $size)
            }
            else { Add-Finding -Item 'frontend build' -Status 'FAIL' -Detail 'build terminé mais aucun index.html produit dans dist/' }
        }
    }
    else { Add-Finding -Item 'frontend build' -Status 'FAIL' -Detail 'node_modules absent : étape resolve non réussie' }
}

# ====================================================================== TEST
function Invoke-TestStage {
    Write-Stage 'test' 'TEST - porte qualité avant livraison'
    if ($SkipTests) { Add-Finding -Item 'tests' -Status 'INFO' -Detail 'ignorés (-SkipTests)'; return }
    $log = Join-Path $script:LogDir 'test.log'
    $badStatus = 'FAIL'; if ($AllowTestFailures) { $badStatus = 'WARN' }
    $be = Join-Path $script:SrcRoot 'backend'
    $fe = Join-Path $script:SrcRoot 'frontend'

    if ($script:VenvPython) {
        $has = Invoke-Native -File $script:VenvPython -Arguments @('-m', 'pytest', '--version') -WorkDir $be -Log $log -Quiet
        if ($has.ExitCode -ne 0) { Add-Finding -Item 'backend pytest' -Status 'WARN' -Detail 'pytest absent des requirements : tests backend non exécutés' }
        else {
            $r = Invoke-Native -File $script:VenvPython -Arguments @('-m', 'pytest', '-q', '-p', 'no:cacheprovider') -WorkDir $be -Env $TestEnv -Log $log -Label 'pytest (suite complète)'
            $summary = @($r.StdOut -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)[0]
            if ($r.ExitCode -eq 0 -or $r.ExitCode -eq 5) { Add-Finding -Item 'backend pytest' -Status 'OK' -Detail ([string]$summary).Trim() }
            else { Add-Finding -Item 'backend pytest' -Status $badStatus -Detail (([string]$summary).Trim() + " (voir $log)") }
        }
    }

    $npx = Resolve-Exe 'npx'
    $jest = (Test-Path -LiteralPath (Join-Path $fe 'node_modules/.bin/jest')) -or (Test-Path -LiteralPath (Join-Path $fe 'node_modules/.bin/jest.cmd'))
    if ($npx -and $jest) {
        $r = Invoke-Native -File $npx -Arguments @('--no-install', 'jest', '--ci', '--passWithNoTests') -WorkDir $fe -Env @{ CI = 'true' } -Log $log -Label 'jest (suite complète)'
        $line = @($r.Text -split "`n" | Where-Object { $_ -match '^Tests:' } | Select-Object -First 1)[0]
        if ($r.ExitCode -eq 0) { Add-Finding -Item 'frontend jest' -Status 'OK' -Detail ([string]$line).Trim() }
        else { Add-Finding -Item 'frontend jest' -Status $badStatus -Detail (([string]$line).Trim() + " (voir $log)") }
    }
    else { Add-Finding -Item 'frontend jest' -Status 'INFO' -Detail 'jest non installé dans le frontend : étape ignorée' }
}

# ====================================================================== PACKAGE (images)
function Get-ImageId {
    param([string]$Image)
    $r = Invoke-Native -File $script:Docker -Arguments @('image', 'inspect', $Image, '--format', '{{.Id}}') -Quiet
    if ($r.ExitCode -eq 0) { return $r.StdOut.Trim() }
    return ''
}

function Invoke-PackageStage {
    Write-Stage 'package' 'PACKAGE - images Docker construites dans des conteneurs propres'
    $log = Join-Path $script:LogDir 'package.log'
    $script:Docker = Resolve-Exe 'docker'
    if (-not $script:Docker) { Add-Finding -Item 'docker' -Status 'FAIL' -Detail 'introuvable'; return }
    if ((Invoke-Native -File $script:Docker -Arguments @('info', '--format', '{{.ServerVersion}}') -Quiet).ExitCode -ne 0) {
        Add-Finding -Item 'docker' -Status 'FAIL' -Detail 'moteur injoignable (Docker Desktop démarré ?)'; return
    }

    # Dockerfiles normalisés en LF (un CRLF casse les continuations de RUN)
    $dockerDir = Join-Path $script:BuildDir 'docker'
    New-Item -ItemType Directory -Force -Path $dockerDir | Out-Null
    foreach ($n in 'Dockerfile.backend', 'Dockerfile.backend.dockerignore', 'Dockerfile.frontend', 'Dockerfile.frontend.dockerignore') {
        Write-LfFile -From (Join-Path $PSScriptRoot $n) -To (Join-Path $dockerDir $n)
    }

    # nginx.conf est déposé dans le contexte jetable du frontend (le Dockerfile ne peut copier que depuis son contexte)
    Write-LfFile -From (Join-Path $PSScriptRoot 'nginx.conf') -To (Join-Path $script:SrcRoot 'frontend/nginx.twins.conf')

    $v = $script:BuildVersion
    $common = @('--label', "org.opencontainers.image.version=$v", '--label', "org.opencontainers.image.revision=$($script:Sha)", '--build-arg', "BUILD_VERSION=$v", '--build-arg', "GIT_SHA=$($script:Sha)")
    if ($NoCache) { $common += '--no-cache' }
    $env = @{ DOCKER_BUILDKIT = '1' }

    $jobs = @(
        @{ Name = 'backend';  Image = "twins-backend:$v";  File = 'Dockerfile.backend';  Ctx = (Join-Path $script:SrcRoot 'backend');  Args = @('--build-arg', "PYTHON_IMAGE=$($script:Images.Python)") },
        @{ Name = 'frontend'; Image = "twins-frontend:$v"; File = 'Dockerfile.frontend'; Ctx = (Join-Path $script:SrcRoot 'frontend'); Args = @('--build-arg', "NODE_IMAGE=$($script:Images.Node)", '--build-arg', "NGINX_IMAGE=$($script:Images.Nginx)") }
    )
    foreach ($j in $jobs) {
        $a = @('build', '-f', (Join-Path $dockerDir $j.File), '-t', $j.Image) + $common + $j.Args + @($j.Ctx)
        $r = Invoke-Native -File $script:Docker -Arguments $a -WorkDir $script:SrcRoot -Env $env -Log $log -Label "docker build $($j.Name)"
        if ($r.ExitCode -ne 0) { Add-Finding -Item "image $($j.Image)" -Status 'FAIL' -Detail "build impossible (voir $log)"; return }
        $script:Images2[$j.Name] = $j.Image
        Add-Finding -Item "image $($j.Image)" -Status 'OK' -Detail ((Get-ImageId $j.Image))
    }

    # ---- inventaire EFFECTIF : ce qui est réellement dans l'image livrée (Linux), pas sur le poste Windows
    $backendImage = $script:Images2['backend']
    $r = Invoke-Native -File $script:Docker -Arguments @('run', '--rm', '--entrypoint', 'python', $backendImage, '--version') -Log $log -Quiet
    if ($r.ExitCode -eq 0) { Add-VersionFinding -Name 'Python' -Item 'python (image backend livrée)' -Raw $r.StdOut.Trim() }
    $r = Invoke-Native -File $script:Docker -Arguments @('run', '--rm', '--entrypoint', 'python', $backendImage, '-m', 'pip', 'check') -Log $log -Quiet
    if ($r.ExitCode -eq 0) { Add-Finding -Item 'image backend pip check' -Status 'OK' -Detail 'aucun conflit' } else { Add-Finding -Item 'image backend pip check' -Status 'FAIL' -Detail ($r.StdOut.Trim()) }
    $r = Invoke-Native -File $script:Docker -Arguments @('run', '--rm', '--entrypoint', 'python', $backendImage, '-m', 'pip', 'list', '--format=json') -Log $log -Quiet
    if ($r.ExitCode -eq 0) {
        $delivered = @($r.StdOut | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ name = $_.name; version = $_.version } })
        $script:Inventory.backendDelivered = $delivered
        $hostMap = @{}; foreach ($p in $script:Inventory.backend) { $hostMap[$p.name.ToLower()] = $p.version }
        $diff = @($delivered | Where-Object { $hostMap.ContainsKey($_.name.ToLower()) -and $hostMap[$_.name.ToLower()] -ne $_.version } | ForEach-Object { "$($_.name) $($hostMap[$_.name.ToLower()])->$($_.version)" })
        if ($diff.Count -eq 0) { Add-Finding -Item 'écart poste vs image (backend)' -Status 'OK' -Detail 'mêmes versions que le venv du build' }
        else { Add-Finding -Item 'écart poste vs image (backend)' -Status 'WARN' -Detail ("$($diff.Count) paquets diffèrent : " + (($diff | Select-Object -First 5) -join ', ') + ' -> épingler un lockfile') }
    }
    foreach ($b in 'Python', 'Node', 'Nginx', 'PostgreSQL', 'Neo4j') {
        $img = $script:Images[$b]
        $script:BaseImages[$b] = [pscustomobject]@{ image = $img; id = (Get-ImageId $img) }
    }
}

# ====================================================================== DELIVER
function Invoke-DeliverStage {
    Write-Stage 'deliver' 'DELIVER - livrable immuable et test de fumée'
    $log = Join-Path $script:LogDir 'deliver.log'
    $dir = $script:DeliveryDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($n in 'docker-compose.yml', 'run-instance.ps1', 'twins-common.ps1', 'versions.psd1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $n) -Destination (Join-Path $dir $n) -Force }
    Write-LfFile -From (Join-Path $PSScriptRoot 'docker-compose.yml') -To (Join-Path $dir 'docker-compose.yml')

    $build = [ordered]@{
        buildVersion = $script:BuildVersion
        images       = [ordered]@{
            backend = "twins-backend:$($script:BuildVersion)"; frontend = "twins-frontend:$($script:BuildVersion)"
            postgres = $script:Images.PostgreSQL; neo4j = $script:Images.Neo4j
        }
    }
    Save-Json $build (Join-Path $dir 'build.json')
    Add-Finding -Item 'livrable' -Status 'OK' -Detail $dir

    if ($ExportImages) {
        $docker = Resolve-Exe 'docker'
        $names = @($build.images.Values)
        foreach ($n in @($build.images.postgres, $build.images.neo4j)) { Invoke-Native -File $docker -Arguments @('pull', $n) -Log $log -Label "docker pull $n" | Out-Null }
        $tar = Join-Path $dir 'images.tar'
        $r = Invoke-Native -File $docker -Arguments (@('save', '-o', $tar) + $names) -Log $log -Label 'docker save'
        if ($r.ExitCode -eq 0) { Add-Finding -Item 'images.tar' -Status 'OK' -Detail ('{0:n0} Mo (livraison hors ligne : docker load -i images.tar)' -f ((Get-Item -LiteralPath $tar).Length / 1MB)) }
        else { Add-Finding -Item 'images.tar' -Status 'FAIL' -Detail "docker save en échec (voir $log)" }
    }

    if ($NoSmoke) { Add-Finding -Item 'test de fumée' -Status 'INFO' -Detail 'ignoré (-NoSmoke)' }
    else {
        $hostPs = (Get-Process -Id $PID).Path
        $r = Invoke-Native -File $hostPs -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dir 'run-instance.ps1'), '-Action', 'smoke') -WorkDir $dir -Log $log -Label 'test de fumée (instance éphémère)'
        $tail = (($r.StdOut -split "`n" | Where-Object { $_ -match '^\s*\[' }) | Select-Object -Last 8) -join ' | '
        if ($r.ExitCode -eq 0) { Add-Finding -Item 'test de fumée' -Status 'OK' -Detail 'instance démarrée, versions effectives conformes, détruite après test' }
        else { Add-Finding -Item 'test de fumée' -Status 'FAIL' -Detail "$tail (voir $log)" }
    }
}

# ====================================================================== PRINCIPAL
$TwinsRoot = (Resolve-Path -LiteralPath $TwinsRoot).Path
if ((Invoke-Git @('rev-parse', '--git-dir')).ExitCode -ne 0) { throw "Ce dossier n'est pas un dépôt git : $TwinsRoot" }
$shaRes = Invoke-Git @('rev-parse', '--short=7', "$Ref^{commit}")
if ($shaRes.ExitCode -ne 0) { throw "Référence git inconnue : $Ref" }
$Sha = $shaRes.StdOut.Trim()
$cdate = (Invoke-Git @('show', '-s', '--format=%cd', '--date=format:%Y%m%d', $Sha)).StdOut.Trim()
$BuildVersion = "$cdate-$Sha"   # identité IMMUABLE du build, dérivée du commit (le "run" aura son propre identifiant)
$Branch = (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')).StdOut.Trim()
$dirty = @((Invoke-Git @('status', '--porcelain')).StdOut -split "`n" | Where-Object { $_.Trim() })

if (-not $OutRoot) { $OutRoot = Join-Path (Split-Path -Parent $TwinsRoot) 'twins_builds' }
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
$OutRoot = (Resolve-Path -LiteralPath $OutRoot).Path

Write-Host "twins_project  $Branch @ $Sha   build $BuildVersion   (jusqu'à : $UpTo)" -ForegroundColor White

$script:SrcRoot = $TwinsRoot
$script:Python = $null; $script:VenvPython = $null; $script:Docker = $null
$script:Inventory = [ordered]@{ backend = @(); backendOutdated = @(); backendDelivered = @(); frontend = @(); frontendOutdated = @() }
$script:Images2 = @{}; $script:BaseImages = @{}
$script:BuildVersion = $BuildVersion; $script:Sha = $Sha

$worktree = $false
$exitCode = 0
try {
    if ($UpTo -ne 'scan') {
        if ($dirty.Count -gt 0 -and -not $IgnoreDirty) {
            throw "Arbre de travail modifié ($($dirty.Count) fichiers). Commit/stash d'abord, ou -IgnoreDirty : le build part du commit $Sha, les modifications locales n'y seront PAS."
        }
        $script:BuildDir = Join-Path $OutRoot $BuildVersion
        if (Test-Path -LiteralPath $script:BuildDir) {
            if (-not $Rebuild) { throw "Le build $BuildVersion existe déjà ($($script:BuildDir)). Un build est immuable : -Rebuild pour le refaire." }
            Remove-Item -LiteralPath $script:BuildDir -Recurse -Force
            Invoke-Git @('worktree', 'prune') | Out-Null
        }
        $script:ReportDir = Join-Path $script:BuildDir 'reports'
        $script:LogDir = Join-Path $script:BuildDir 'logs'
        $script:ToolDir = Join-Path $script:BuildDir 'tools'
        $script:Venv = Join-Path $script:BuildDir 'venv'
        $script:DeliveryDir = Join-Path $script:BuildDir 'delivery'
        $script:SrcRoot = Join-Path $script:BuildDir 'src'
        foreach ($d in $script:ReportDir, $script:LogDir, $script:ToolDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        $wt = Invoke-Git @('worktree', 'add', '--detach', $script:SrcRoot, $Sha)
        if ($wt.ExitCode -ne 0) { throw "git worktree add a échoué : $($wt.StdErr)" }
        $worktree = $true
        Write-Host "worktree jetable : $($script:SrcRoot)" -ForegroundColor DarkGray
    }
    elseif ($dirty.Count -gt 0) { Write-Host "(scan du dossier de travail : $($dirty.Count) fichiers modifiés non commités)" -ForegroundColor Yellow }

    foreach ($key in $Order) {
        if (-not (Test-StageEnabled $key)) { break }
        switch ($key) {
            'scan'    { Invoke-ScanStage }
            'resolve' { Invoke-ResolveStage }
            'compile' { Invoke-CompileStage }
            'test'    { Invoke-TestStage }
            'package' { Invoke-PackageStage }
            'deliver' { Invoke-DeliverStage }
        }
        if (-not (Test-StageClean -Key $key -Strict:$Strict)) {
            Write-Host "`nPorte qualité '$key' non franchie : chaîne interrompue." -ForegroundColor Red
            break
        }
    }
}
catch { Write-Host "`nERREUR : $($_.Exception.Message)" -ForegroundColor Red; $exitCode = 1 }
finally {
    $code = Write-Summary -Strict:$Strict
    if ($exitCode -eq 0) { $exitCode = $code }

    $report = [ordered]@{
        buildVersion = $BuildVersion; commit = $Sha; branch = $Branch; ref = $Ref; upTo = $UpTo
        createdAtUtc = (Get-Date).ToUniversalTime().ToString('o'); strict = [bool]$Strict
        host = [ordered]@{ powershell = $PSVersionTable.PSVersion.ToString(); python = $(if ($script:Python) { $script:Python.Version } else { $null }) }
        policySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $PSScriptRoot 'versions.psd1')).Hash
        lockfiles = [ordered]@{}
        findings = @($script:Findings)
        images = $script:Images2; baseImages = $script:BaseImages
        inventoryCounts = [ordered]@{ backend = @($script:Inventory.backend).Count; frontend = @($script:Inventory.frontend).Count }
    }
    foreach ($lf in 'frontend/package-lock.json', 'backend/requirements.txt', 'backend/requirements-dev.txt') {
        $p = Join-Path $script:SrcRoot $lf
        if (Test-Path -LiteralPath $p) { $report.lockfiles[$lf] = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash }
    }
    if ($UpTo -eq 'scan') { Save-Json $report (Join-Path $OutRoot "scan-$BuildVersion.json"); Write-Host "Rapport : $(Join-Path $OutRoot "scan-$BuildVersion.json")" -ForegroundColor DarkGray }
    elseif ($script:ReportDir -and (Test-Path -LiteralPath $script:ReportDir)) {
        Save-Json $script:Inventory (Join-Path $script:ReportDir 'inventory.json')
        Save-Json $report (Join-Path $script:ReportDir 'manifest.json')
        if (Test-Path -LiteralPath $script:DeliveryDir) { Copy-Item -LiteralPath (Join-Path $script:ReportDir 'manifest.json') -Destination (Join-Path $script:DeliveryDir 'manifest.json') -Force }
        Write-Host "Rapports : $($script:ReportDir)" -ForegroundColor DarkGray
    }
    if ($worktree -and -not $KeepSource) {
        $rm = Invoke-Git @('worktree', 'remove', '--force', $script:SrcRoot)
        if ($rm.ExitCode -ne 0 -and (Test-Path -LiteralPath $script:SrcRoot)) { Remove-Item -LiteralPath $script:SrcRoot -Recurse -Force -ErrorAction SilentlyContinue }
        Invoke-Git @('worktree', 'prune') | Out-Null
    }
}
exit $exitCode
