<#
.SYNOPSIS
    Installe, configure et prépare l'environnement complet pour le build et le run des composants Twins.
.DESCRIPTION
    Installs Python, Node.js, Git, Make, Docker Desktop, Podman (when requested),
    backend requirements,
    frontend dependencies, PostgreSQL 15, and Neo4j Community 5.21.0. Docker
    Compose remains available for the full Twins runtime stack.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_needed.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_needed.ps1 -InstallPodman
#>
[CmdletBinding()]
param(
    [string]$TwinsRoot = "C:\workspace\twins_project",
    [switch]$Check,
    [switch]$Force,
    [switch]$Init,
    [switch]$InstallDocker,
    [switch]$InstallPodman,
    [switch]$InstallDevTools,
    [switch]$SkipDocker,
    [switch]$SkipNativeDatabases,
    [switch]$SkipBackend,
    [switch]$SkipFrontend
)

$ErrorActionPreference = "Continue"
$LabPy = Join-Path $PSScriptRoot "lab.py"
$Missing = New-Object System.Collections.Generic.List[string]

function Write-Step { param([string]$Msg) Write-Host "`n== $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK  ] $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

function Update-SessionPath {
    $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ";"
}

function Repair-WingetSources {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "    -> Réinitialisation des sources winget..." -ForegroundColor DarkGray
        & winget source reset --force 2>$null
        & winget source update 2>$null
    }
}

function Find-Python311 {
    $candidates = @()

    if ($env:LOCALAPPDATA) {
        $pyCoreRoot = Join-Path $env:LOCALAPPDATA "Python"
        if (Test-Path -LiteralPath $pyCoreRoot) {
            Get-ChildItem -Path $pyCoreRoot -Filter "pythoncore-*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Join-Path $_.FullName "python.exe"
                if (Test-Path -LiteralPath $p) { $candidates += @{ Exe = $p; Pre = @() } }
            }
        }
    }

    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        foreach ($v in "3.14", "3.13", "3.12", "3.11") { $candidates += @{ Exe = $launcher.Source; Pre = @("-$v") } }
    }

    foreach ($n in "python", "python3") {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source -notmatch "WindowsApps") { $candidates += @{ Exe = $c.Source; Pre = @() } }
    }

    foreach ($c in $candidates) {
        try {
            $ok = & $c.Exe @($c.Pre) -c "import sys; print(int(sys.version_info >= (3, 11)))" 2>$null
            if ($LASTEXITCODE -eq 0 -and "$ok".Trim() -eq "1") { return $c }
        } catch { }
    }
    return $null
}

function Get-NodeMajor {
    $n = Get-Command node -ErrorAction SilentlyContinue
    if (-not $n) { return 0 }
    $v = & $n.Source --version 2>$null
    if ("$v" -match "v(\d+)") { return [int]$Matches[1] }
    return 0
}

function Get-NpmCommand {
    foreach ($name in "npm.cmd", "npm") {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) { return $command.Source }
    }
    return $null
}

function Find-PostgresServer {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programRoot) { continue }
        $candidate = Join-Path $programRoot "PostgreSQL\15\bin\postgres.exe"
        if (Test-Path -LiteralPath $candidate) { $candidates.Add($candidate) }
    }
    $command = Get-Command postgres.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source -and -not $candidates.Contains($command.Source)) {
        $candidates.Add($command.Source)
    }
    foreach ($candidate in $candidates) {
        $version = & $candidate --version 2>$null
        if ("$version" -match '\b15\.') { return $candidate }
    }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return $null
}

function Find-CompatibleJava {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:JAVA_HOME) {
        $javaHomeExe = Join-Path $env:JAVA_HOME "bin\java.exe"
        if (Test-Path -LiteralPath $javaHomeExe) { $candidates.Add($javaHomeExe) }
    }
    $command = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { $candidates.Add($command.Source) }
    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programRoot) { continue }
        foreach ($pattern in @("Eclipse Adoptium\jdk-17*\bin\java.exe", "Eclipse Adoptium\jdk-21*\bin\java.exe", "Java\jdk-17*\bin\java.exe", "Java\jdk-21*\bin\java.exe")) {
            Get-ChildItem -Path (Join-Path $programRoot $pattern) -ErrorAction SilentlyContinue | ForEach-Object {
                $candidates.Add($_.FullName)
            }
        }
    }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        try {
            $versionOutput = & $candidate -version 2>&1 | Out-String
            if ($versionOutput -match 'version "1\.(\d+)|version "(\d+)') {
                $major = if ($Matches[1]) { [int]$Matches[1] } else { [int]$Matches[2] }
                if ($major -in @(17, 21)) { return $candidate }
            }
        } catch { }
    }
    return $null
}

function Find-Neo4j {
    $candidates = @()
    if ($env:NEO4J_HOME) {
        $candidates += (Join-Path $env:NEO4J_HOME "bin\neo4j.bat")
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Neo4j\neo4j-community-5.21.0\bin\neo4j.bat")
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $admin = Join-Path (Split-Path -Parent $candidate) "neo4j-admin.bat"
            $version = if (Test-Path -LiteralPath $admin) { & $admin --version 2>&1 | Out-String } else { "" }
            if ($version -match '\b5\.21(?:\.0)?\b') { return $candidate }
        }
    }
    $command = Get-Command neo4j.bat -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        $admin = Join-Path (Split-Path -Parent $command.Source) "neo4j-admin.bat"
        $version = if (Test-Path -LiteralPath $admin) { & $admin --version 2>&1 | Out-String } else { "" }
        if ($version -match '\b5\.21(?:\.0)?\b') { return $command.Source }
    }
    return $null
}

function Find-Docker {
    $d = Get-Command docker -ErrorAction SilentlyContinue
    if ($d) { return $d.Source }
    $default = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    if (Test-Path -LiteralPath $default) { return $default }
    return $null
}

function Find-Podman {
    $podman = Get-Command podman -ErrorAction SilentlyContinue
    if ($podman) { return $podman.Source }
    $default = "C:\Program Files\RedHat\Podman\podman.exe"
    if (Test-Path -LiteralPath $default) { return $default }
    return $null
}

function Install-WithWinget {
    param([string]$Id, [string]$Label, [switch]$Interactive)
    if ($Check) {
        Write-Warn2 "$Label manquant : serait installé via winget ($Id)"
        $Missing.Add($Label)
        return $false
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Fail "$Label manquant et winget est introuvable."
        $Missing.Add($Label)
        return $false
    }
    
    $wingetArgs = @("install", "--id", $Id, "-e", "--accept-package-agreements", "--accept-source-agreements")
    if ($Interactive) {
        $wingetArgs += "--interactive"
        Write-Host "    -> winget install $Id (assistant d'installation interactif)" -ForegroundColor DarkGray
    } else {
        $wingetArgs += "--silent"
        Write-Host "    -> winget install $Id" -ForegroundColor DarkGray
    }
    & winget @wingetArgs

    if ($LASTEXITCODE -eq -1978335217 -or $LASTEXITCODE -eq 2316632079) {
        Repair-WingetSources
        & winget @wingetArgs
    }

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Fail "L'installation de $Label a échoué (code $LASTEXITCODE)."
        $Missing.Add($Label)
        return $false
    }
    Update-SessionPath
    return $true
}

function Set-Neo4jNativePorts {
    param([string]$Neo4jBat)
    $neo4jRoot = Split-Path -Parent (Split-Path -Parent $Neo4jBat)
    $confFile = Join-Path $neo4jRoot "conf\neo4j.conf"
    if (-not (Test-Path -LiteralPath $confFile -PathType Leaf)) {
        throw "Fichier de configuration Neo4j introuvable : $confFile"
    }
    $config = Get-Content -LiteralPath $confFile -Raw
    $settings = @(
        "server.bolt.listen_address=:7688",
        "server.bolt.advertised_address=localhost:7688",
        "server.http.listen_address=:7475",
        "server.http.advertised_address=localhost:7475"
    )
    foreach ($setting in $settings) {
        $key = ($setting -split "=", 2)[0]
        if ($config -notmatch "(?m)^\s*$([regex]::Escape($key))\s*=") {
            $config = $config.TrimEnd() + [Environment]::NewLine + $setting + [Environment]::NewLine
        }
    }
    Set-Content -LiteralPath $confFile -Value $config -Encoding Ascii
}

function Install-NativeDatabases {
    if ($SkipNativeDatabases) {
        Write-Warn2 "Installation native de PostgreSQL et Neo4j ignorée (-SkipNativeDatabases)."
        return
    }

    Write-Step "Bases de données natives (PostgreSQL 15 + Neo4j Community 5.21)"
    $postgres = Find-PostgresServer
    if ($postgres) {
        $postgresVersion = & $postgres --version 2>$null
        if ("$postgresVersion" -match '\b15\.') {
            Write-Ok "Serveur PostgreSQL 15 : $postgres"
        } else {
            Write-Fail "Serveur PostgreSQL détecté mais sa version n'est pas 15 : $postgresVersion"
            $Missing.Add("PostgreSQL 15")
        }
    } elseif (Install-WithWinget -Id "PostgreSQL.PostgreSQL.15" -Label "PostgreSQL 15" -Interactive) {
        Update-SessionPath
        $postgres = Find-PostgresServer
        $postgresVersion = if ($postgres) { & $postgres --version 2>$null } else { "" }
        if ($postgres -and "$postgresVersion" -match '\b15\.') {
            Write-Ok "Serveur PostgreSQL 15 installé : $postgres"
        } else {
            Write-Fail "postgres.exe introuvable après l'assistant. Terminez l'installation, puis relancez le script."
            $Missing.Add("PostgreSQL 15 (installation/configuration)")
        }
    }

    $java = Find-CompatibleJava
    if (-not $java) {
        if (Install-WithWinget -Id "EclipseAdoptium.Temurin.17.JDK" -Label "JDK Temurin 17") {
            Update-SessionPath
            $java = Find-CompatibleJava
        }
    }
    if ($java) {
        Write-Ok "Java compatible avec Neo4j : $java"
        if (-not $Check) {
            $javaHome = Split-Path -Parent (Split-Path -Parent $java)
            try {
                [Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "User")
                Write-Ok "JAVA_HOME utilisateur configuré pour Neo4j."
            } catch {
                Write-Fail "Impossible de configurer JAVA_HOME : $($_.Exception.Message)"
                $Missing.Add("JAVA_HOME pour Neo4j")
                return
            }
        }
        $javaHome = Split-Path -Parent (Split-Path -Parent $java)
        $env:JAVA_HOME = $javaHome
    } else {
        Write-Fail "JDK 17 ou 21 introuvable; Neo4j Community 5.21 ne peut pas démarrer."
        $Missing.Add("JDK 17/21")
        return
    }

    $neo4j = Find-Neo4j
    if ($neo4j) {
        if ($Check) {
            Write-Ok "Serveur Neo4j natif 5.21 présent : $neo4j"
            return
        }
        try {
            Set-Neo4jNativePorts -Neo4jBat $neo4j
            Write-Ok "Serveur Neo4j natif 5.21 présent : $neo4j"
        } catch {
            Write-Fail "Configuration Neo4j impossible : $($_.Exception.Message)"
            $Missing.Add("Configuration Neo4j native")
        }
        return
    }
    if ($Check) {
        Write-Warn2 "Neo4j Community 5.21.0 manquant : téléchargement prévu depuis dist.neo4j.org."
        $Missing.Add("Neo4j Community 5.21.0")
        return
    }
    if (-not $env:LOCALAPPDATA) {
        Write-Fail "LOCALAPPDATA est absent; impossible de choisir une destination Neo4j."
        $Missing.Add("Neo4j destination")
        return
    }

    $version = "5.21.0"
    $archiveUri = "https://dist.neo4j.org/neo4j-community-$version-windows.zip"
    $expectedHash = "2245e1e3246d390dca21c74941adfe3c6af8b288fb4ecd3089a6ec66bde4220b"
    $installRoot = Join-Path $env:LOCALAPPDATA "Programs\Neo4j"
    $target = Join-Path $installRoot "neo4j-community-$version"
    $archive = Join-Path $env:TEMP "neo4j-community-$version-windows.zip"
    $staging = Join-Path $env:TEMP "neo4j-community-$version-extract"
    try {
        Write-Host "    -> Téléchargement de Neo4j Community $version (SHA-256 vérifié)." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $archiveUri -OutFile $archive -UseBasicParsing -ErrorAction Stop
        $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Empreinte SHA-256 incorrecte; archive refusée."
        }
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
        $extracted = Join-Path $staging "neo4j-community-$version"
        if (-not (Test-Path -LiteralPath (Join-Path $extracted "bin\neo4j.bat") -PathType Leaf)) {
            throw "neo4j.bat absent de l'archive extraite."
        }
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
        if (Test-Path -LiteralPath $target) {
            throw "La destination existe déjà; aucune installation n'a été remplacée : $target"
        }
        Move-Item -LiteralPath $extracted -Destination $target -ErrorAction Stop
        Set-Neo4jNativePorts -Neo4jBat (Join-Path $target "bin\neo4j.bat")
        Write-Ok "Neo4j Community $version installé : $target"
        Write-Warn2 "Au premier démarrage, Neo4j demandera de remplacer le mot de passe initial neo4j/neo4j."
    } catch {
        Write-Fail "Installation Neo4j interrompue : $($_.Exception.Message)"
        $Missing.Add("Neo4j Community 5.21.0")
    } finally {
        if (Test-Path -LiteralPath $archive) {
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-PythonUserScriptsToPath {
    param($Python)
    $scriptsPath = & $Python.Exe @($Python.Pre) -c "import sysconfig; print(sysconfig.get_path('scripts', scheme='nt_user'))" 2>$null
    if ($LASTEXITCODE -eq 0 -and $scriptsPath -and (Test-Path -LiteralPath $scriptsPath -PathType Container)) {
        if (($env:Path -split ";") -notcontains $scriptsPath) {
            $env:Path = "$scriptsPath;$env:Path"
        }
    }
}

function Install-DevConsoleTools {
    param($Python)

    Write-Step "Outils DevConsole complémentaires"
    $wingetTools = @(
        @{ Command = "pwsh"; Label = "PowerShell 7"; Id = "Microsoft.PowerShell" },
        @{ Command = "gh"; Label = "GitHub CLI"; Id = "GitHub.cli" },
        @{ Command = "jq"; Label = "jq"; Id = "jqlang.jq" },
        @{ Command = "uv"; Label = "uv"; Id = "Astral-sh.uv" },
        @{ Command = "mvn"; Label = "Maven"; Id = "Apache.Maven" },
        @{ Command = "gradle"; Label = "Gradle"; Id = "Gradle.Gradle" },
        @{ Command = "helm"; Label = "Helm"; Id = "Helm.Helm" },
        @{ Command = "kind"; Label = "kind"; Id = "Kubernetes.kind" },
        @{ Command = "minikube"; Label = "Minikube"; Id = "Kubernetes.minikube" },
        @{ Command = "gitlab-runner"; Label = "GitLab Runner"; Id = "GitLab.Runner" },
        @{ Command = "terraform"; Label = "Terraform"; Id = "Hashicorp.Terraform" },
        @{ Command = "cmake"; Label = "CMake"; Id = "Kitware.CMake" },
        @{ Command = "dotnet"; Label = ".NET SDK"; Id = "Microsoft.DotNet.SDK.10" },
        @{ Command = "go"; Label = "Go"; Id = "GoLang.Go" },
        @{ Command = "cargo"; Label = "Rust/Cargo"; Id = "Rustlang.Rustup" }
    )
    foreach ($tool in $wingetTools) {
        if (Get-Command $tool.Command -ErrorAction SilentlyContinue) {
            Write-Ok "$($tool.Label) présent"
            continue
        }
        $installed = Install-WithWinget -Id $tool.Id -Label $tool.Label
        if ($Check) { continue }
        Update-SessionPath
        if (Get-Command $tool.Command -ErrorAction SilentlyContinue) {
            Write-Ok "$($tool.Label) installé"
        } elseif ($installed) {
            Write-Fail "$($tool.Label) installé mais introuvable dans le PATH. Rouvrez le terminal."
            $Missing.Add("$($tool.Label) (PATH)")
        }
    }

    & $Python.Exe @($Python.Pre) -m pip --version 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if ($Check) {
            Write-Warn2 "pip manquant : serait activé avec ensurepip"
            $Missing.Add("pip")
        } else {
            & $Python.Exe @($Python.Pre) -m ensurepip --upgrade
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Impossible d'activer pip avec ensurepip."
                $Missing.Add("pip")
            }
        }
    }
    if (-not $Check) {
        Add-PythonUserScriptsToPath -Python $Python
    }
    if (Get-Command pip -ErrorAction SilentlyContinue) {
        Write-Ok "pip disponible"
    } elseif ($Check) {
        Write-Warn2 "Commande pip absente du PATH."
        if ($Missing -notcontains "pip (PATH)") { $Missing.Add("pip (PATH)") }
    } else {
        Write-Fail "pip est installé mais introuvable dans le PATH utilisateur."
        $Missing.Add("pip (PATH)")
    }

    $pipx = Get-Command pipx -ErrorAction SilentlyContinue
    if (-not $pipx) {
        if ($Check) {
            Write-Warn2 "pipx manquant : serait installé avec pip --user"
            $Missing.Add("pipx")
        } else {
            & $Python.Exe @($Python.Pre) -m pip install --user --upgrade pipx
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Installation de pipx via pip a échoué."
                $Missing.Add("pipx")
            } else {
                Add-PythonUserScriptsToPath -Python $Python
                $pipx = Get-Command pipx -ErrorAction SilentlyContinue
                if ($pipx) {
                    Write-Ok "pipx installé"
                } else {
                    Write-Fail "pipx est installé mais introuvable dans le PATH utilisateur."
                    $Missing.Add("pipx (PATH)")
                }
            }
        }
    } else {
        Write-Ok "pipx présent"
    }

    $pipx = Get-Command pipx -ErrorAction SilentlyContinue
    if ($pipx) {
        if (-not (Get-Command poetry -ErrorAction SilentlyContinue)) {
            if ($Check) {
                Write-Warn2 "Poetry manquant : serait installé avec pipx"
                $Missing.Add("Poetry")
            } else {
                & $pipx.Source install poetry
                if ($LASTEXITCODE -ne 0) {
                    Write-Fail "Installation de Poetry via pipx a échoué."
                    $Missing.Add("Poetry")
                } else {
                    Add-PythonUserScriptsToPath -Python $Python
                    if (Get-Command poetry -ErrorAction SilentlyContinue) {
                        Write-Ok "Poetry installé"
                    } else {
                        Write-Fail "Poetry est installé mais introuvable dans le PATH utilisateur."
                        $Missing.Add("Poetry (PATH)")
                    }
                }
            }
        } else {
            Write-Ok "Poetry présent"
        }
    } elseif ($Check -and -not (Get-Command poetry -ErrorAction SilentlyContinue)) {
        Write-Warn2 "Poetry manquant : serait installé avec pipx."
        $Missing.Add("Poetry")
    }

    $npm = Get-NpmCommand
    if (-not $npm) {
        Write-Fail "npm est requis pour installer pnpm, Yarn, TypeScript et Angular CLI."
        $Missing.Add("pnpm, yarn, tsc, ng")
    } else {
        $npmTools = @(
            @{ Command = "pnpm"; Package = "pnpm"; Label = "pnpm" },
            @{ Command = "yarn"; Package = "yarn"; Label = "Yarn" },
            @{ Command = "tsc"; Package = "typescript"; Label = "TypeScript" },
            @{ Command = "ng"; Package = "@angular/cli"; Label = "Angular CLI" }
        )
        foreach ($tool in $npmTools) {
            if (Get-Command $tool.Command -ErrorAction SilentlyContinue) {
                Write-Ok "$($tool.Label) présent"
                continue
            }
            if ($Check) {
                Write-Warn2 "$($tool.Label) manquant : serait installé avec npm"
                $Missing.Add($tool.Label)
                continue
            }
            & $npm install --global $tool.Package
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Installation de $($tool.Label) avec npm a échoué."
                $Missing.Add($tool.Label)
            } else {
                Update-SessionPath
                if (Get-Command $tool.Command -ErrorAction SilentlyContinue) {
                    Write-Ok "$($tool.Label) installé"
                } else {
                    Write-Fail "$($tool.Label) installé mais introuvable dans le PATH. Rouvrez le terminal."
                    $Missing.Add("$($tool.Label) (PATH)")
                }
            }
        }
    }

    Install-AnsibleInWsl
}

function Install-AnsibleInWsl {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        if ($Check) {
            Write-Warn2 "Ansible absent : WSL/Ubuntu devrait être installé pour utiliser Ansible sous Windows."
            $Missing.Add("Ansible (WSL)")
            return
        }
        Write-Host "    -> Installation de WSL via winget." -ForegroundColor DarkGray
        $wslInstalled = Install-WithWinget -Id "Microsoft.WSL" -Label "Windows Subsystem for Linux"
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if (-not $wsl -and $wslInstalled) {
            Write-Warn2 "WSL a été installé. Redémarrez Windows si demandé, puis relancez lab install all."
            $Missing.Add("Ansible (redémarrage requis pour WSL)")
            return
        } elseif (-not $wsl) {
            $Missing.Add("Ansible (WSL indisponible)")
            return
        }
        & $wsl.Source --install --no-launch --distribution Ubuntu
        if ($LASTEXITCODE -eq 0) {
            Write-Warn2 "WSL/Ubuntu a été préparé. Redémarrez si Windows le demande, lancez Ubuntu une fois pour créer le compte Linux, puis relancez lab install all."
        } else {
            Write-Fail "Installation d'Ubuntu WSL échouée (code $LASTEXITCODE)."
        }
        $Missing.Add("Ansible (initialisation WSL requise)")
        return
    }

    $distributions = @(& $wsl.Source --list --quiet 2>$null | ForEach-Object { "$_".Trim([char]0, [char]13, [char]10, [char]32) } | Where-Object { $_ })
    if ($distributions -notcontains "Ubuntu") {
        if ($Check) {
            Write-Warn2 "Ubuntu WSL absent : serait installé pour Ansible."
            $Missing.Add("Ansible (Ubuntu WSL)")
            return
        }
        & $wsl.Source --install --no-launch --distribution Ubuntu
        if ($LASTEXITCODE -eq 0) {
            Write-Warn2 "Ubuntu WSL installé. Lancez Ubuntu une fois pour créer le compte Linux, puis relancez lab install all."
        } else {
            Write-Fail "Installation d'Ubuntu WSL échouée (code $LASTEXITCODE)."
        }
        $Missing.Add("Ansible (initialisation Ubuntu WSL requise)")
        return
    }

    $ansibleCheck = & $wsl.Source --distribution Ubuntu -- sh -lc "command -v ansible" 2>$null
    if ($LASTEXITCODE -eq 0 -and $ansibleCheck) {
        Write-Ok "Ansible disponible dans Ubuntu WSL : $("$ansibleCheck".Trim())"
        if ($Check) {
            if (-not (Get-Command ansible -ErrorAction SilentlyContinue)) {
                Write-Warn2 "La commande Windows ansible serait reliée à Ubuntu WSL."
                $Missing.Add("Ansible (PATH Windows)")
            }
        } else {
            Register-AnsibleWslCommand -WslPath $wsl.Source
        }
        return
    }
    if ($Check) {
        Write-Warn2 "Ansible manquant dans Ubuntu WSL."
        $Missing.Add("Ansible (Ubuntu WSL)")
        return
    }
    & $wsl.Source --distribution Ubuntu -- sh -lc "sudo apt-get update && sudo apt-get install -y ansible"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Installation d'Ansible dans Ubuntu WSL échouée. Vérifiez la configuration du compte Linux et sudo, puis relancez."
        $Missing.Add("Ansible (Ubuntu WSL)")
        return
    }
    $ansibleCheck = & $wsl.Source --distribution Ubuntu -- sh -lc "command -v ansible" 2>$null
    if ($LASTEXITCODE -eq 0 -and $ansibleCheck) {
        Write-Ok "Ansible installé dans Ubuntu WSL : $("$ansibleCheck".Trim())"
        Register-AnsibleWslCommand -WslPath $wsl.Source
    } else {
        Write-Fail "L'installation d'Ansible dans Ubuntu WSL s'est terminée mais la commande n'est pas disponible."
        $Missing.Add("Ansible (Ubuntu WSL)")
    }
}

function Register-AnsibleWslCommand {
    param([string]$WslPath)
    if (-not $env:LOCALAPPDATA) {
        Write-Fail "LOCALAPPDATA absent : impossible d'exposer la commande Ansible WSL au PATH Windows."
        $Missing.Add("Ansible (PATH Windows)")
        return
    }
    $binDirectory = Join-Path $env:LOCALAPPDATA "DevConsole\bin"
    $ansibleCommand = Join-Path $binDirectory "ansible.cmd"
    try {
        New-Item -ItemType Directory -Path $binDirectory -Force | Out-Null
        Set-Content -LiteralPath $ansibleCommand -Encoding Ascii -Value @(
            "@echo off",
            "`"$WslPath`" --distribution Ubuntu -- ansible %*",
            "exit /b %errorlevel%"
        )
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $userEntries = @($userPath -split ";" | Where-Object { $_ })
        if ($userEntries -notcontains $binDirectory) {
            $updatedUserPath = (@($binDirectory) + $userEntries) -join ";"
            [Environment]::SetEnvironmentVariable("Path", $updatedUserPath, "User")
        }
        if (($env:Path -split ";") -notcontains $binDirectory) {
            $env:Path = "$binDirectory;$env:Path"
        }
        if (Get-Command ansible -ErrorAction SilentlyContinue) {
            Write-Ok "Commande Windows 'ansible' reliée à Ubuntu WSL."
        } else {
            Write-Warn2 "La commande ansible sera disponible dans un nouveau terminal."
        }
    } catch {
        Write-Fail "Impossible d'exposer Ansible WSL dans le PATH Windows : $($_.Exception.Message)"
        $Missing.Add("Ansible (PATH Windows)")
    }
}

if (-not (Test-Path -LiteralPath $LabPy -PathType Leaf)) {
    Write-Fail "lab.py introuvable : $LabPy"
    exit 2
}

# ---------------------------------------------------------------- 1. Prérequis système
Write-Step "1. Prérequis système$(if ($Check) { ' (vérification seule)' })"
Update-SessionPath

$py = Find-Python311
if ($py) {
    Write-Ok "Python >= 3.11 : $($py.Exe) $($py.Pre -join ' ')"
} elseif (Install-WithWinget -Id "Python.Python.3.12" -Label "Python 3.12") {
    $py = Find-Python311
    if ($py) { Write-Ok "Python installé : $($py.Exe)" } else { Write-Fail "Python installé mais introuvable."; $Missing.Add("Python (PATH)") }
}

if ((Get-NodeMajor) -ge 22) {
    Write-Ok "Node.js $(& node --version) (npm/npx inclus)"
} elseif (Install-WithWinget -Id "OpenJS.NodeJS.LTS" -Label "Node.js LTS") {
    if ((Get-NodeMajor) -ge 22) { Write-Ok "Node.js installé : $(& node --version)" } else { Write-Fail "Node.js 22+ introuvable."; $Missing.Add("Node.js (PATH)") }
}

$npmCommand = Get-NpmCommand
if ($npmCommand) {
    Write-Ok "npm disponible : $npmCommand"
} else {
    Write-Fail "npm est introuvable. Réinstaller Node.js LTS puis rouvrir le terminal."
    $Missing.Add("npm")
}
if (Get-Command npx.cmd -ErrorAction SilentlyContinue) {
    Write-Ok "npx disponible"
} elseif (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Ok "npx disponible"
} else {
    Write-Fail "npx est introuvable. Réinstaller Node.js LTS puis rouvrir le terminal."
    $Missing.Add("npx")
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok "Git présent"
} else {
    [void](Install-WithWinget -Id "Git.Git" -Label "Git")
}

if (Test-Path -LiteralPath (Join-Path $TwinsRoot "Makefile") -PathType Leaf) {
    if (Get-Command make -ErrorAction SilentlyContinue) {
        Write-Ok "GNU Make présent"
    } elseif (Install-WithWinget -Id "ezwinports.make" -Label "GNU Make") {
        if (Get-Command make -ErrorAction SilentlyContinue) {
            Write-Ok "GNU Make installé"
        } else {
            Write-Fail "GNU Make installé mais introuvable dans le PATH. Rouvrez le terminal."
            $Missing.Add("GNU Make (PATH)")
        }
    }
}

$docker = Find-Docker
if ($docker) {
    $dockerVersion = & $docker --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Docker CLI : $dockerVersion"
    } else {
        Write-Fail "Docker CLI trouvé mais impossible à exécuter : $docker"
        $Missing.Add("Docker CLI")
    }
} elseif ($InstallDocker -or -not $SkipDocker) {
    Write-Host "    -> Installation de Docker Desktop via winget." -ForegroundColor DarkGray
    $dockerInstalled = Install-WithWinget -Id "Docker.DockerDesktop" -Label "Docker Desktop"
    Update-SessionPath
    $docker = Find-Docker
    if ($docker) {
        Write-Ok "Docker Desktop installé : $docker"
    } elseif ($dockerInstalled) {
        Write-Fail "Docker Desktop a été installé, mais docker.exe reste introuvable. Redémarrez le terminal puis relancez lab install --check."
        $Missing.Add("Docker CLI (PATH)")
    }
} else {
    Write-Warn2 "Docker Desktop est requis pour Redis, Mailpit, backend, workers et le lancement de la stack Compose."
}
if ($docker) {
    $composeVersion = & $docker compose version --short 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Docker Compose v2 : $composeVersion"
    } else {
        Write-Fail "Docker Compose v2 est introuvable. Mettre à jour Docker Desktop."
        $Missing.Add("Docker Compose v2")
    }
}

$podman = Find-Podman
if ($podman) {
    $podmanVersion = & $podman --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Podman : $podmanVersion"
    } else {
        Write-Fail "Podman trouvé mais impossible à exécuter : $podman"
        $Missing.Add("Podman")
    }
} elseif ($InstallPodman) {
    Write-Host "    -> Installation de Podman via winget." -ForegroundColor DarkGray
    $podmanInstalled = Install-WithWinget -Id "RedHat.Podman" -Label "Podman"
    if (-not $Check) {
        Update-SessionPath
        $podman = Find-Podman
        if ($podman) {
            $podmanVersion = & $podman --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Podman installé : $podmanVersion"
            } else {
                Write-Fail "Podman installé mais impossible à exécuter : $podman"
                $Missing.Add("Podman")
            }
        } elseif ($podmanInstalled) {
            Write-Fail "Podman installé mais introuvable dans le PATH. Rouvrez le terminal puis relancez."
            $Missing.Add("Podman (PATH)")
        }
    }
} else {
    Write-Warn2 "Podman absent : optionnel (-InstallPodman pour l'installer)."
}

Install-NativeDatabases

if (-not $py) {
    Write-Host ""
    Write-Fail "Python >= 3.11 est requis pour continuer."
    exit 1
}

if ($InstallDevTools) {
    Install-DevConsoleTools -Python $py
}

if ($Check) {
    if ($TwinsRoot) { $env:TWINS_ROOT = $TwinsRoot }
    Write-Step "Verification complete des prerequis (aucune modification)"
    & $py.Exe @($py.Pre) $LabPy install --check
    exit $LASTEXITCODE
}

# ------------------------------------------------------------- 2. Configuration & Build des composants
if ($TwinsRoot) { $env:TWINS_ROOT = $TwinsRoot }

if (-not (Test-Path -LiteralPath $TwinsRoot -PathType Container)) {
    Write-Fail "Projet Twins introuvable : $TwinsRoot"
    exit 1
}

if (-not $SkipBackend) {
    Write-Step "2. Dépendances backend (venv + requirements.txt)"
    $backendDir = Join-Path $TwinsRoot "backend"
    $requirements = Join-Path $backendDir "requirements.txt"
    if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) {
        Write-Fail "Fichier requirements.txt introuvable : $requirements"
        $Missing.Add("backend/requirements.txt")
    } else {
        $venvDir = Join-Path $backendDir ".venv"
        $backendPython = Join-Path $venvDir "Scripts\python.exe"
        if (-not (Test-Path -LiteralPath $backendPython -PathType Leaf)) {
            Write-Host "    -> Création de $venvDir" -ForegroundColor DarkGray
            & $py.Exe @($py.Pre) -m venv $venvDir
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Création du venv backend échouée (code $LASTEXITCODE)."
                $Missing.Add("backend venv")
            }
        }
        if (Test-Path -LiteralPath $backendPython -PathType Leaf) {
            & $backendPython -m pip install --upgrade pip
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Mise à jour de pip échouée (code $LASTEXITCODE)."
                $Missing.Add("pip backend")
            } else {
                & $backendPython -m pip install -r $requirements
                if ($LASTEXITCODE -ne 0) {
                    Write-Fail "Installation des requirements backend échouée (code $LASTEXITCODE)."
                    $Missing.Add("backend requirements")
                } else {
                    Write-Ok "Dépendances backend installées."
                }
            }
        }
    }
}

if (-not $SkipFrontend) {
    Write-Step "3. Dépendances frontend (npm ci)"
    $frontendDir = Join-Path $TwinsRoot "frontend"
    $packageJson = Join-Path $frontendDir "package.json"
    $packageLock = Join-Path $frontendDir "package-lock.json"
    $npmCommand = Get-NpmCommand
    if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf) -or
        -not (Test-Path -LiteralPath $packageLock -PathType Leaf)) {
        Write-Fail "package.json ou package-lock.json introuvable dans $frontendDir"
        $Missing.Add("frontend manifests")
    } elseif (-not $npmCommand) {
        Write-Fail "npm est introuvable après l'installation de Node.js."
        $Missing.Add("npm")
    } else {
        & $npmCommand ci --engine-strict --prefix $frontendDir
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "npm ci a échoué (code $LASTEXITCODE)."
            $Missing.Add("frontend npm dependencies")
        } else {
            Write-Ok "Dépendances frontend installées."
        }
    }
}

Write-Step "4. Configuration locale"
$envExample = Join-Path $TwinsRoot ".env.example"
$envFile = Join-Path $TwinsRoot ".env"
if ((Test-Path -LiteralPath $envFile -PathType Leaf)) {
    Write-Ok ".env existant conservé sans modification."
} elseif (Test-Path -LiteralPath $envExample -PathType Leaf) {
    try {
        Copy-Item -LiteralPath $envExample -Destination $envFile -ErrorAction Stop
        Write-Ok ".env créé à partir de .env.example."
        Write-Warn2 "Vérifiez les secrets et mots de passe locaux dans .env avant de démarrer Docker Compose."
    } catch {
        Write-Fail "Impossible de créer .env : $($_.Exception.Message)"
        $Missing.Add(".env creation")
    }
} else {
    Write-Fail ".env.example introuvable : $envExample"
    $Missing.Add(".env.example")
}

Write-Host ""
if (-not $SkipBackend -and -not $SkipFrontend) {
    Write-Step "5. Vérification des prérequis de build"
    & $py.Exe @($py.Pre) $LabPy doctor --phase build
    if ($LASTEXITCODE -ne 0) {
        $Missing.Add("diagnostic des prérequis de build")
    }
}

if ($Missing.Count -gt 0) {
    Write-Warn2 "Éléments manquants : $($Missing -join ', ')"
    exit 1
} elseif ($Check) {
    Write-Host "[+] Vérification terminée." -ForegroundColor Green
} else {
    Write-Host "[+] Outils, bases natives et dépendances de build installés."
    Write-Host "    PostgreSQL natif utilise le port 5432 par défaut."
    Write-Host "    Neo4j natif utilise Bolt 7688 et HTTP 7475; le premier démarrage demande un nouveau mot de passe."
    Write-Host "    Avant un backend natif, alignez POSTGRES_PASSWORD et NEO4J_PASSWORD dans .env sur vos mots de passe locaux."
    Write-Host "    Pour utiliser Neo4j natif avec un lancement local du backend, ajustez NEO4J_URI dans .env à bolt://localhost:7688."
    Write-Host "    Les ports natifs évitent les conflits avec PostgreSQL/Neo4j Compose sur 5433/7687."
    Write-Host "    Le diagnostic --check ne démarre aucun service."
    Write-Host "    Pour démarrer Neo4j natif : & `"$env:LOCALAPPDATA\Programs\Neo4j\neo4j-community-5.21.0\bin\neo4j.bat`" console"
    Write-Host "    Pour la stack conteneurisée : démarrez Docker Desktop, puis exécutez 'docker compose up --build -d' depuis $TwinsRoot."
    Write-Host "    Pour lancer Angular : npm start (depuis le répertoire frontend)."
}
if ($env:TWINS_ROOT) { Write-Host "    TWINS_ROOT = $($env:TWINS_ROOT)" -ForegroundColor DarkGray }
exit 0