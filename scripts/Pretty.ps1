function global:Get-DevConsoleBranch {
    if ((Get-Location).Provider.Name -ne 'FileSystem') { return }
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return }
    $branch = & git symbolic-ref --quiet --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        $sha = & git rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0) { return "detached:$sha" }
        return
    }
    return $branch
}

function Enable-DevConsolePretty {
    param([string]$ThemeName)
    $root = Split-Path -Parent $PSScriptRoot
    $palettes = Get-Content (Join-Path $root 'config\themes.json') -Raw | ConvertFrom-Json
    $selection = Join-Path $root 'data\appearance.json'
    if (-not $ThemeName) {
        $ThemeName = 'ocean'
        if (Test-Path $selection) {
            try { $ThemeName = (Get-Content $selection -Raw | ConvertFrom-Json).theme } catch { Write-Verbose $_ }
        }
    }
    if ($ThemeName -notin $palettes.PSObject.Properties.Name) { throw "Theme inconnu : $ThemeName. Utiliser dev theme list." }
    $palette = $palettes.$ThemeName
    $global:DevConsolePromptColor = $palette.console
    function global:prompt {
        $savedExit = $global:LASTEXITCODE
        $branch = Get-DevConsoleBranch
        Write-Host ("{0}" -f $PWD) -NoNewline -ForegroundColor $global:DevConsolePromptColor
        if ($branch) { Write-Host " [$branch]" -NoNewline -ForegroundColor $global:DevConsolePromptColor }
        $global:LASTEXITCODE = $savedExit
        return "`n> "
    }
    $themeConfig = Get-Content (Join-Path $root 'config\devconsole.omp.json') -Raw | ConvertFrom-Json
    foreach ($block in $themeConfig.blocks) {
        foreach ($segment in $block.segments) {
            switch ($segment.type) {
                'text' { $segment.foreground = $palette.accent }
                'git' { $segment.foreground = $palette.git }
            }
        }
    }
    $themeConfig.blocks[-1].segments[0].foreground = $palette.prompt
    $theme = Join-Path $root "data\$ThemeName.omp.json"
    New-Item -ItemType Directory -Path (Split-Path $theme) -Force | Out-Null
    $themeConfig | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $theme -Encoding UTF8
    $posh = Get-Command oh-my-posh -CommandType Application -ErrorAction SilentlyContinue
    if ($posh) {
        try {
            $init = & $posh.Source init pwsh --config $theme
            if ($LASTEXITCODE -ne 0) { throw 'Initialisation Oh My Posh impossible.' }
            $init | Out-String | Invoke-Expression
        }
        catch { Write-Warning $_.Exception.Message }
    }
    else {
        Write-Host "Theme $ThemeName | Invite Git native | Oh My Posh : dev pretty -Install" -ForegroundColor DarkGray
    }
    if (Get-Module -ListAvailable PSReadLine) {
        try {
            Import-Module PSReadLine -ErrorAction Stop
            Set-PSReadLineOption -EditMode Windows -ErrorAction Stop
            if ((Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionSource')) {
                Set-PSReadLineOption -PredictionSource History -ErrorAction Stop
            }
        }
        catch { Write-Verbose "PSReadLine : $_" }
    }
}
