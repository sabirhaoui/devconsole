param(
    [Parameter(Mandatory, Position=0)]
    [ValidateSet('build', 'test-api', 'run', 'run-published', 'stop', 'health')]
    [string]$Action,
    [ValidateRange(1, 65535)]
    [int]$Port = 18753
)

$ErrorActionPreference = 'Stop'
$base = 'http://127.0.0.1:18754'
$data = Join-Path ([IO.Path]::GetTempPath()) 'a2-connector-devconsole'
$pidFile = "$data.pid.json"

switch ($Action) {
    'build' {
        dotnet restore a2-builder.slnx
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        dotnet build a2-builder.slnx -c Release --no-restore
        exit $LASTEXITCODE
    }
    'test-api' {
        dotnet build src/A2.Connector.Host -c Debug
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        pwsh -NoProfile -File tests/A2.Connector.IntegrationTests/Test-ExportJobs.ps1 -Port $Port
        exit $LASTEXITCODE
    }
    'health' {
        (Invoke-WebRequest "$base/health/live" -TimeoutSec 5).Content
        exit 0
    }
    'stop' {
        if (Test-Path -LiteralPath $pidFile) {
            $state = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
            $process = Get-Process -Id $state.id -ErrorAction SilentlyContinue
            if ($process -and $process.StartTime.ToUniversalTime().Ticks.ToString() -eq $state.started) {
                taskkill.exe /PID $process.Id /T /F
                exit $LASTEXITCODE
            }
        }
        exit 0
    }
}

$lock = [Threading.Mutex]::new($false, 'DevConsole-A2-Connector-18754')
$acquired = $false
$process = $null
try {
    try { $acquired = $lock.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (!$acquired) { throw 'Un hôte A2 Connector est déjà géré par DevConsole.' }

    $start = [Diagnostics.ProcessStartInfo]::new('dotnet')
    $start.WorkingDirectory = $PWD.Path
    $start.UseShellExecute = $false
    $arguments = if ($Action -eq 'run') {
        @('run', '--project', 'src/A2.Connector.Host', '-c', 'Release', '--')
    } else {
        @('artifacts/a2-connector/A2.Connector.Host.dll')
    }
    foreach ($argument in ($arguments + @('--urls', $base, '--Persistence:Directory', $data))) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    @{ id = $process.Id; started = $process.StartTime.ToUniversalTime().Ticks.ToString() } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $pidFile
    $process.WaitForExit()
    exit $process.ExitCode
} finally {
    if ($process -and !$process.HasExited) { $process.Kill($true) }
    if ($acquired) {
        Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
        $lock.ReleaseMutex()
    }
    $lock.Dispose()
}
