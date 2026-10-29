param([switch]$RemoveData)
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-SolverDirs
[IO.File]::WriteAllText($script:StopFlag, (Get-NowString), $script:Utf8)
foreach ($p in Get-WatcherProcesses) { Stop-ProcessTree -ProcessId $p.ProcessId }
if (Get-SolverTask) {
    Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    Write-Host "Removed scheduled task $($script:TaskName)."
}
if (Test-Path -LiteralPath $script:StartupShortcut) { Remove-Item -LiteralPath $script:StartupShortcut -Force; Write-Host 'Removed Startup shortcut.' }
if ($RemoveData) {
    Set-Location $env:TEMP
    Remove-Item -LiteralPath $script:DataDir -Recurse -Force
    Write-Host "Removed $($script:DataDir) (state, logs, private clone)."
}
else {
    Write-Host "Kept state and logs in $($script:DataDir). Use -RemoveData to delete them."
}
Write-Host 'Nothing in your GitHub repository was changed.'
