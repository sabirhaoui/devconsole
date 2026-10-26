
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$ReportDirectory = Join-Path $ProjectRoot "reports"
$JsonReport = Join-Path $ReportDirectory "init-report.json"

New-Item -ItemType Directory -Path $ReportDirectory -Force |
    Out-Null

$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string]$Category,
        [string]$Name,
        [string]$Status,
        [string]$Path = "",
        [string]$Details = ""
    )

    $script:Results.Add([pscustomobject]@{
        Category = $Category
        Name     = $Name
        Status   = $Status
        Path     = $Path
        Details  = $Details
    })
}

function Test-Executable {
    param(
        [string]$Category,
        [string]$Name,
        [string[]]$Candidates,
        [string[]]$VersionArgs = @("--version")
    )

    $command = $null

    foreach ($candidate in $Candidates) {
        $command = Get-Command $candidate `
            -CommandType Application `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($null -ne $command) {
            break
        }
    }

    if ($null -eq $command) {
        Add-Result -Category $Category -Name $Name `
            -Status "ABSENT" `
            -Details "Exécutable introuvable dans PATH"
        return $null
    }

    $version = ""
    try {
        $invokeArgs = $VersionArgs
        $output = @(& $command.Source @invokeArgs 2>&1)
        if ($output.Count -gt 0) {
            $version = [string]$output[0]
        }
    }
    catch {
        $version = "Version non récupérée : $($_.Exception.Message)"
    }

    Add-Result -Category $Category -Name $Name `
        -Status "PRESENT" -Path $command.Source -Details $version

    return $command.Source
}

function Test-ProjectMarker {
    param(
        [string]$Name,
        [string[]]$RelativePaths,
        [string]$Category = "Projet"
    )

    foreach ($relative in $RelativePaths) {
        $path = Join-Path $ProjectRoot $relative

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Add-Result -Category $Category -Name $Name `
                -Status "FOUND" -Path $path `
                -Details "Fichier de configuration détecté"
            return
        }
    }

    Add-Result -Category $Category -Name $Name `
        -Status "ABSENT" `
        -Details "Aucun fichier de configuration correspondant"
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " DevConsole - Initialisation et inventaire" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Projet : $ProjectRoot"
Write-Host ""

# ------------------------------------------------------------
# 1. Environnement et gestion de versions
# ------------------------------------------------------------

$null = Test-Executable "Environnement" "PowerShell 7" @("pwsh.exe")
$null = Test-Executable "Versioning" "Git" @("git.exe")
$null = Test-Executable "Versioning" "GitHub CLI" @("gh.exe")
$null = Test-Executable "Environnement" "SSH" @("ssh.exe")
$null = Test-Executable "Environnement" "curl" @("curl.exe")
$null = Test-Executable "Environnement" "jq" @("jq.exe")

# ------------------------------------------------------------
# 2. Python et outils de test
# ------------------------------------------------------------

$pythonPath = Test-Executable "Python" "Python" @("python.exe")
$null = Test-Executable "Python" "Python Launcher" @("py.exe")
$null = Test-Executable "Python" "pip" @("pip.exe")
$null = Test-Executable "Python" "uv" @("uv.exe")
$null = Test-Executable "Python" "Poetry" @("poetry.exe")
$null = Test-Executable "Python" "pipx" @("pipx.exe")
$null = Test-Executable "Python" "tox" @("tox.exe")
$null = Test-Executable "Python" "Ruff" @("ruff.exe")
$null = Test-Executable "Python" "Mypy" @("mypy.exe")

if ($pythonPath) {
    foreach ($module in @("pytest", "coverage")) {
        try {
            $output = @(& $pythonPath -m $module --version 2>&1)
            if ($LASTEXITCODE -eq 0) {
                Add-Result -Category "Tests Python" -Name $module `
                    -Status "PRESENT" -Path $pythonPath `
                    -Details ([string]$output[0])
            }
            else {
                Add-Result -Category "Tests Python" -Name $module `
                    -Status "ABSENT" `
                    -Details "Module indisponible dans cet environnement Python"
            }
        }
        catch {
            Add-Result -Category "Tests Python" -Name $module `
                -Status "ERROR" -Details $_.Exception.Message
        }
    }
}
else {
    Add-Result -Category "Tests Python" -Name "pytest" `
        -Status "UNKNOWN" -Details "Python introuvable ; test du module impossible"
}

# ------------------------------------------------------------
# 3. Java et frameworks de test
# ------------------------------------------------------------

$null = Test-Executable "Java" "JDK / Java" @("java.exe") @("-version")
$null = Test-Executable "Java" "Java Compiler" @("javac.exe") @("-version")
$null = Test-Executable "Java" "Maven" @("mvn.cmd", "mvn.exe")
$null = Test-Executable "Java" "Gradle" @("gradle.bat", "gradle.exe")
$null = Test-Executable "Java" "Maven Wrapper" @("mvnw.cmd", "mvnw")
$null = Test-Executable "Java" "Gradle Wrapper" @("gradlew.bat", "gradlew")

# La présence d'une dépendance est évaluée dans les manifestes
# du projet, pas déduite de la seule présence du JDK.
$javaManifests = @(
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "gradle\libs.versions.toml"
)

$manifestPaths = @(
    foreach ($relative in $javaManifests) {
        $path = Join-Path $ProjectRoot $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $path
        }
    }
)

foreach ($framework in @("JUnit", "TestNG", "Mockito")) {
    $found = $false

    foreach ($manifest in $manifestPaths) {
        if (Select-String -LiteralPath $manifest `
            -Pattern $framework `
            -Quiet -ErrorAction SilentlyContinue) {
            $found = $true
            break
        }
    }

    if ($found) {
        Add-Result -Category "Tests Java" -Name $framework `
            -Status "FOUND" -Details "Référence détectée dans un manifeste"
    }
    else {
        Add-Result -Category "Tests Java" -Name $framework `
            -Status "NOT CONFIRMED" `
            -Details "Référence non détectée dans les manifestes Java à la racine"
    }
}

# ------------------------------------------------------------
# 4. JavaScript / TypeScript
# ------------------------------------------------------------

$null = Test-Executable "JavaScript" "Node.js" @("node.exe")
$null = Test-Executable "JavaScript" "npm" @("npm.cmd", "npm.exe")
$null = Test-Executable "JavaScript" "pnpm" @("pnpm.cmd", "pnpm.exe")
$null = Test-Executable "JavaScript" "Yarn" @("yarn.cmd", "yarn.exe")
$null = Test-Executable "JavaScript" "TypeScript" @("tsc.cmd", "tsc.exe")
$null = Test-Executable "JavaScript" "Angular CLI" @("ng.cmd", "ng.exe")

# ------------------------------------------------------------
# 5. Conteneurs et orchestration
# ------------------------------------------------------------

$null = Test-Executable "Conteneurs" "Docker" @("docker.exe")
$null = Test-Executable "Conteneurs" "Podman" @("podman.exe")
$null = Test-Executable "Kubernetes" "kubectl" @("kubectl.exe")
$null = Test-Executable "Kubernetes" "Helm" @("helm.exe")
$null = Test-Executable "Kubernetes" "kind" @("kind.exe")
$null = Test-Executable "Kubernetes" "Minikube" @("minikube.exe")
$null = Test-Executable "Kubernetes" "k9s" @("k9s.exe")

# ------------------------------------------------------------
# 6. CI/CD et outils d'ingénierie
# ------------------------------------------------------------

$null = Test-Executable "CI/CD" "GitLab Runner" @("gitlab-runner.exe")
$null = Test-Executable "CI/CD" "Jenkins CLI" @("jenkins-cli.exe")
$null = Test-Executable "Infrastructure" "Terraform" @("terraform.exe")
$null = Test-Executable "Infrastructure" "Ansible" @("ansible.exe")
$null = Test-Executable "Build" "Make" @("make.exe")
$null = Test-Executable "Build" "CMake" @("cmake.exe")
$null = Test-Executable "Build" ".NET SDK" @("dotnet.exe")
$null = Test-Executable "Build" "Go" @("go.exe")
$null = Test-Executable "Build" "Rust / Cargo" @("cargo.exe")
$null = Test-Executable "Éditeur" "Visual Studio Code" @("code.cmd", "code.exe")

# ------------------------------------------------------------
# 7. Configuration du projet et CI
# ------------------------------------------------------------

Test-ProjectMarker "Configuration GitLab CI" @(".gitlab-ci.yml") "CI/CD"
Test-ProjectMarker "Dockerfile" @("Dockerfile") "Conteneurs"
Test-ProjectMarker "Docker Compose" @("compose.yaml", "compose.yml", "docker-compose.yml") "Conteneurs"
Test-ProjectMarker "Dépendances Python" @("pyproject.toml", "requirements.txt") "Projet"
Test-ProjectMarker "Dépendances Node" @("package.json") "Projet"
Test-ProjectMarker "Projet Maven" @("pom.xml") "Projet"
Test-ProjectMarker "Projet Gradle" @("build.gradle", "build.gradle.kts") "Projet"

# ------------------------------------------------------------
# 8. Affichage et rapport JSON
# ------------------------------------------------------------

Write-Host ""
Write-Host "Résultats de l'inventaire" -ForegroundColor Cyan
Write-Host ""

$Results |
    Sort-Object Category, Name |
    Format-Table Category, Name, Status, Details -AutoSize -Wrap

$summary = [ordered]@{
    GeneratedAt = (Get-Date).ToString("o")
    ComputerName = $env:COMPUTERNAME
    UserName = $env:USERNAME
    ProjectRoot = $ProjectRoot
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    Results = @($Results)
    Counts = [ordered]@{
        Present = @($Results | Where-Object Status -eq "PRESENT").Count
        Found = @($Results | Where-Object Status -eq "FOUND").Count
        Absent = @($Results | Where-Object Status -eq "ABSENT").Count
        Other = @($Results | Where-Object {
            $_.Status -notin @("PRESENT", "FOUND", "ABSENT")
        }).Count
    }
}

$summary | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $JsonReport -Encoding UTF8

Write-Host ""
Write-Host "Rapport JSON : $JsonReport" -ForegroundColor Green
Write-Host "Inventaire terminé. Aucun outil n'a été installé ou supprimé." `
    -ForegroundColor Green
