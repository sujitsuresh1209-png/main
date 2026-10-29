param(
    [Parameter(Position = 0)][ValidateSet('status', 'start', 'stop', 'restart', 'retry', 'solve', 'logs')][string]$Action = 'status',
    [Parameter(Position = 1)][string]$Commit,
    [int]$Tail = 40
)
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-SolverDirs
$watcherScript = Join-Path $script:DataDir 'bin\watcher.ps1'

function Stop-Watcher {
    [IO.File]::WriteAllText($script:StopFlag, (Get-NowString), $script:Utf8)
    $task = Get-SolverTask
    if ($task) { Disable-ScheduledTask -TaskName $script:TaskName | Out-Null }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-WatcherProcesses).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    foreach ($p in Get-WatcherProcesses) { Stop-ProcessTree -ProcessId $p.ProcessId }
    if ($task) { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue }
    Write-Host 'Watcher stopped. It will stay stopped (also after reboot) until you run: control.ps1 start'
}

function Start-Watcher {
    if (Test-Path -LiteralPath $script:StopFlag) { Remove-Item -LiteralPath $script:StopFlag -Force }
    if ((Get-WatcherProcesses).Count -gt 0) { Write-Host 'Watcher is already running.'; return }
    $task = Get-SolverTask
    if ($task) {
        Enable-ScheduledTask -TaskName $script:TaskName | Out-Null
        Start-ScheduledTask -TaskName $script:TaskName
    }
    else {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$watcherScript`"")
    }
    Start-Sleep -Seconds 3
    if ((Get-WatcherProcesses).Count -gt 0) { Write-Host 'Watcher started.' } else { Write-Host 'Watcher did not start; check the log with: control.ps1 logs' }
}

function Add-Request {
    param([string]$Kind)
    if ($Commit -notmatch '^[0-9a-fA-F]{4,40}$') { throw "Give a commit hash, for example: control.ps1 $Kind ccaee546" }
    [IO.File]::WriteAllText((Join-Path $script:RequestDir "$Kind-$Commit"), (Get-NowString), $script:Utf8)
    Write-Host "Request queued; the watcher picks it up within one poll interval."
}

function Show-Status {
    $task = Get-SolverTask
    $procs = Get-WatcherProcesses
    Write-Host '=== Practice Solver ==='
    if ($task) { Write-Host ("Scheduled task : {0} ({1})" -f $script:TaskName, $task.State) }
    elseif (Test-Path -LiteralPath $script:StartupShortcut) { Write-Host "Autostart      : Startup folder shortcut" }
    else { Write-Host 'Autostart      : NOT INSTALLED (run install.ps1)' }
    if ($procs.Count -gt 0) { Write-Host ("Watcher        : running (pid {0})" -f (($procs | ForEach-Object { $_.ProcessId }) -join ', ')) }
    else { Write-Host 'Watcher        : not running' }
    if (Test-Path -LiteralPath $script:StopFlag) { Write-Host 'Stop flag      : set (run control.ps1 start to resume)' }
    if (Test-Path -LiteralPath $script:HeartbeatFile) { Write-Host ("Last poll      : {0}" -f (Get-Content -Raw -LiteralPath $script:HeartbeatFile).Trim()) }
    $state = Read-SolverState
    if (-not $state) { Write-Host 'State          : none yet (baseline is set on first poll)'; return }
    Write-Host ("Baseline       : {0}" -f $state.baseline)
    Write-Host ("Last scanned   : {0}" -f $state.lastScanned)
    $groups = $state.jobs | Group-Object status | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
    Write-Host ("Jobs           : {0}" -f (($groups) -join '  '))
    $attention = @($state.jobs | Where-Object { $_.status -eq 'pending' -or $_.status -eq 'failed' -or $_.status -eq 'running' })
    if ($attention.Count -gt 0) {
        Write-Host ''
        Write-Host 'Waiting / retrying / failed:'
        $attention | Sort-Object { [int]$_.seq } | Format-Table -AutoSize -Wrap @{ n = 'commit'; e = { $_.short } }, status, attempts, @{ n = 'next try'; e = { $_.nextAttempt } }, @{ n = 'last error'; e = { $_.lastError } } | Out-String -Width 220 | Write-Host
    }
    Write-Host 'Recent jobs:'
    $state.jobs | Sort-Object { [int]$_.seq } | Select-Object -Last 15 | Format-Table -AutoSize @{ n = 'commit'; e = { $_.short } }, status, @{ n = 'subject'; e = { $_.subject } }, @{ n = 'answer / reason'; e = { if ($_.answerPath) { $_.answerPath } else { $_.reason } } } | Out-String -Width 220 | Write-Host
    Write-Host ("Data folder    : {0}" -f $script:DataDir)
}

function Show-Logs {
    $latest = Get-ChildItem -LiteralPath $script:LogDir -Filter 'watcher-*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $latest) { Write-Host 'No logs yet.'; return }
    Write-Host "== $($latest.FullName) =="
    Get-Content -LiteralPath $latest.FullName -Tail $Tail
    Write-Host ''
    Write-Host "Per-job Claude transcripts: $script:JobLogDir"
}

switch ($Action) {
    'status' { Show-Status }
    'start' { Start-Watcher }
    'stop' { Stop-Watcher }
    'restart' { Stop-Watcher; Start-Watcher }
    'retry' { Add-Request 'retry' }
    'solve' { Add-Request 'solve' }
    'logs' { Show-Logs }
}
