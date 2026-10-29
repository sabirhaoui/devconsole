# twins-common.ps1 - fonctions partagées (dot-source). Compatible Windows PowerShell 5.1 et PowerShell 7+.

$script:Findings = New-Object System.Collections.ArrayList
$script:Policy   = @{}
$script:Images   = @{}
$script:Stage    = ''

# ------------------------------------------------------------------ politique de versions
function Import-Policy {
    param([Parameter(Mandatory)][string]$Path)
    $data = Import-PowerShellDataFile -Path $Path
    $script:Policy = $data.Policy
    $script:Images = $data.Images
}

function ConvertTo-Ver {
    param([string]$Text)
    if ($Text -match '(\d+)(?:\.(\d+))?(?:\.(\d+))?') {
        $minor = 0; $patch = 0
        if ($Matches[2]) { $minor = [int]$Matches[2] }
        if ($Matches[3]) { $patch = [int]$Matches[3] }
        return [version]('{0}.{1}.{2}' -f [int]$Matches[1], $minor, $patch)
    }
    return $null
}

function Test-Policy {
    param([string]$Name, [version]$Version)
    $p = $script:Policy[$Name]
    # trois composantes partout : [version]'3.11' est inférieur à [version]'3.11.0'
    $v = [version]('{0}.{1}.0' -f $Version.Major, $Version.Minor)
    if ($v -lt (ConvertTo-Ver $p.Floor))   { return 'FAIL' }
    if ($v -lt (ConvertTo-Ver $p.Target))  { return 'UPGRADE' }
    if ($v -ge (ConvertTo-Ver $p.Ceiling)) { return 'WARN' }
    return 'OK'
}

# ------------------------------------------------------------------ constats
function Write-Stage {
    param([string]$Key, [string]$Title)
    $script:Stage = $Key
    Write-Host ''
    Write-Host ('=== {0} ===' -f $Title) -ForegroundColor White
}

function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('OK', 'INFO', 'WARN', 'UPGRADE', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )
    [void]$script:Findings.Add([pscustomobject]@{ Stage = $script:Stage; Item = $Item; Status = $Status; Detail = $Detail })
    $color = 'Gray'
    switch ($Status) { 'OK' { $color = 'Green' } 'WARN' { $color = 'Yellow' } 'UPGRADE' { $color = 'Cyan' } 'FAIL' { $color = 'Red' } }
    Write-Host ('  [{0,-7}] {1}' -f $Status, $Item) -ForegroundColor $color -NoNewline
    if ($Detail) { Write-Host (' - ' + $Detail) -ForegroundColor DarkGray } else { Write-Host '' }
}

function Add-VersionFinding {
    param([string]$Name, [string]$Item, [string]$Raw, [string]$Context = '')
    $v = ConvertTo-Ver $Raw
    if (-not $v) { Add-Finding -Item $Item -Status 'WARN' -Detail "version illisible : '$Raw'"; return }
    $status = Test-Policy $Name $v
    $p = $script:Policy[$Name]
    $detail = "détecté $Raw ; cible $($p.Target) (plancher $($p.Floor), borne haute <$($p.Ceiling))"
    if ($status -ne 'OK') { $detail += ' - ' + $p.Note }
    Add-Finding -Item $Item -Status $status -Detail $detail
}

function Get-ImageParts {
    param([string]$Ref)
    $digest = ''
    $r = $Ref
    if ($r -match '@(sha256:[0-9a-f]+)$') { $digest = $Matches[1]; $r = $r.Substring(0, $r.IndexOf('@')) }
    $slash = $r.LastIndexOf('/')
    $colon = $r.LastIndexOf(':')
    $name = $r; $tag = ''
    if ($colon -gt $slash) { $name = $r.Substring(0, $colon); $tag = $r.Substring($colon + 1) }
    $short = $name.Substring($name.LastIndexOf('/') + 1)
    return [pscustomobject]@{ Name = $name; Short = $short; Tag = $tag; Digest = $digest }
}

function Add-ImageFinding {
    param([string]$Where, [string]$Ref)
    if ($Ref -match '\$') { Add-Finding -Item "$Where : $Ref" -Status 'INFO' -Detail 'image paramétrée, valeur non vérifiable statiquement'; return }
    $i = Get-ImageParts $Ref
    $key = $null
    switch -Regex ($i.Short) { '^postgres$' { $key = 'PostgreSQL' } '^neo4j$' { $key = 'Neo4j' } '^python$' { $key = 'Python' } '^node$' { $key = 'Node' } }
    if (-not $key) { return }
    if ($i.Digest -and -not $i.Tag) { Add-Finding -Item "$Where : $Ref" -Status 'INFO' -Detail 'épinglée par digest (version non lisible)'; return }
    if ($i.Tag -notmatch '^\d') { Add-Finding -Item "$Where : $Ref" -Status 'WARN' -Detail "tag flottant '$($i.Tag)' : build non reproductible"; return }
    Add-VersionFinding -Name $key -Item "$Where : $Ref" -Raw $i.Tag
}

function Test-StageClean {
    param([string]$Key, [switch]$Strict)
    $bad = @($script:Findings | Where-Object { $_.Stage -eq $Key -and ($_.Status -eq 'FAIL' -or ($Strict -and ($_.Status -eq 'WARN' -or $_.Status -eq 'UPGRADE'))) })
    return ($bad.Count -eq 0)
}

function Write-Summary {
    param([switch]$Strict)
    Write-Host ''
    Write-Host '=== BILAN ===' -ForegroundColor White
    foreach ($s in 'OK', 'INFO', 'UPGRADE', 'WARN', 'FAIL') {
        $n = @($script:Findings | Where-Object { $_.Status -eq $s }).Count
        if ($n -gt 0) { Write-Host ('  {0,-8} {1}' -f $s, $n) }
    }
    $fail = @($script:Findings | Where-Object { $_.Status -eq 'FAIL' }).Count
    $pending = @($script:Findings | Where-Object { $_.Status -eq 'WARN' -or $_.Status -eq 'UPGRADE' }).Count
    if ($fail -gt 0) { return 1 }
    if ($Strict -and $pending -gt 0) { return 2 }
    return 0
}

# ------------------------------------------------------------------ processus natifs
function Resolve-Exe {
    param([string]$Name)
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Format-NativeArg {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
    return $Value
}

function Read-LastLine {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        try { $l = Get-Content -LiteralPath $p -Tail 1 -ErrorAction Stop; if ($l) { return ([string]$l).Trim() } } catch { }
    }
    return ''
}

# Lance un exécutable sans jamais lever d'erreur sur stderr (piège de Windows PowerShell 5.1) ;
# renvoie ExitCode / StdOut / StdErr et ajoute la sortie complète au journal -Log.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [string]$WorkDir = (Get-Location).Path,
        [hashtable]$Env = @{},
        [string]$Log,
        [string]$Label,
        [switch]$Quiet
    )
    $WhatIfPreference = $false   # les appels natifs sont de la lecture/exécution voulue, même sous -WhatIf
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Env[$k]) }
    $code = -1
    try {
        $sp = @{ FilePath = $File; WorkingDirectory = $WorkDir; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile; PassThru = $true; NoNewWindow = $true; WhatIf = $false; Confirm = $false }  # WhatIf/Confirm : ne pas hériter du -WhatIf de l'appelant
        $line = (@($Arguments | ForEach-Object { Format-NativeArg $_ })) -join ' '
        if ($line) { $sp['ArgumentList'] = $line }
        $proc = Start-Process @sp
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.WaitForExit(1500)) {
            if ($Label -and -not $Quiet) {
                Write-Progress -Activity $Label -Status ('{0:n0}s  {1}' -f $clock.Elapsed.TotalSeconds, (Read-LastLine @($outFile, $errFile)))
            }
        }
        $proc.WaitForExit()
        $code = $proc.ExitCode
    }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        if ($Label -and -not $Quiet) { Write-Progress -Activity $Label -Completed }
    }
    $stdout = [System.IO.File]::ReadAllText($outFile)
    $stderr = [System.IO.File]::ReadAllText($errFile)
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    if ($Log) {
        $dir = Split-Path -Parent $Log
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $header = '$ {0} {1}   (cwd: {2}, exit: {3})' -f $File, $line, $WorkDir, $code
        Add-Content -LiteralPath $Log -Value ($header + "`r`n" + $stdout + $stderr + "`r`n")
    }
    return [pscustomobject]@{ ExitCode = $code; StdOut = $stdout; StdErr = $stderr; Text = ($stdout + "`n" + $stderr) }
}

function Save-Json {
    param($Object, [string]$Path, [int]$Depth = 8)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth $Depth), (New-Object System.Text.UTF8Encoding($false)))
}

function Write-LfFile {
    # Copie un fichier en normalisant les fins de ligne en LF, sans BOM (Dockerfile, nginx.conf, yml).
    param([string]$From, [string]$To)
    $text = ([System.IO.File]::ReadAllText($From)) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($To, $text, (New-Object System.Text.UTF8Encoding($false)))
}
