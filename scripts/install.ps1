param(
    [string]$RemoteUrl,
    [string]$Branch,
    [switch]$SkipClaudeTest
)
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-SolverDirs
$binDir = Join-Path $script:DataDir 'bin'
$watcherScript = Join-Path $binDir 'watcher.ps1'

function Write-Step { param([string]$Text) Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok { param([string]$Text) Write-Host "    OK  $Text" -ForegroundColor Green }
function Write-Bad { param([string]$Text) Write-Host "    !!  $Text" -ForegroundColor Yellow }

Write-Step 'Checking tools'
$script:GitExe = Find-Git
if (-not $script:GitExe) { throw 'git is not installed or not on PATH. Install Git for Windows first.' }
Write-Ok "git: $script:GitExe"
$tar = Find-Executable 'tar' @("$env:SystemRoot\System32\tar.exe")
if (-not $tar) { throw 'tar.exe not found. Windows 10 1803 or newer is required.' }
Write-Ok "tar: $tar"
$defaults = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'config.default.json') | ConvertFrom-Json
$claude = Find-Claude $null
if (-not $claude) { throw 'Claude Code (claude) not found on PATH. Install it and log in by running "claude" once.' }
Write-Ok "claude: $claude"
$ver = Invoke-Native -FilePath $claude -Arguments @('--version') -TimeoutSec 60
Write-Ok ("claude version: {0}" -f $ver.Out.Trim())
$help = Invoke-Native -FilePath $claude -Arguments @('--help') -TimeoutSec 60
if (-not ($help.Out + $help.Err).Contains('--restricted')) { Write-Bad 'This Claude Code version lacks --restricted. Run "claude update" for stronger isolation (the watcher still works).' }

Write-Step 'Stopping any running watcher (old or new)'
if (Get-SolverTask) { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue }
$old = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and ($_.CommandLine -match 'watch-github\.ps1' -or $_.CommandLine -match 'PracticeSolver\\bin\\watcher\.ps1') -and $_.ProcessId -ne $PID })
foreach ($p in $old) { Stop-ProcessTree -ProcessId $p.ProcessId; Write-Ok "stopped pid $($p.ProcessId)" }
if ($old.Count -eq 0) { Write-Ok 'none running' }

Write-Step "Installing scripts to $binDir"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
foreach ($f in @('common.ps1', 'watcher.ps1', 'control.ps1', 'install.ps1', 'uninstall.ps1', 'config.default.json', 'claude-permissions.json')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination (Join-Path $binDir $f) -Force
}
Write-Ok 'copied'

Write-Step 'Writing configuration'
if (-not $RemoteUrl) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $r = Invoke-Native -FilePath $script:GitExe -Arguments @('-C', $repoRoot, 'remote', 'get-url', 'origin') -TimeoutSec 30
    if ($r.ExitCode -eq 0 -and $r.Out.Trim()) { $RemoteUrl = $r.Out.Trim() }
}
if (Test-Path -LiteralPath $script:ConfigFile) {
    $cfg = Get-Content -Raw -LiteralPath $script:ConfigFile | ConvertFrom-Json
}
else {
    $cfg = [pscustomobject]@{ RemoteUrl = $defaults.RemoteUrl; Branch = $defaults.Branch; PollSeconds = $defaults.PollSeconds; ClaudeModel = ''; AllowCodeExecution = $true }
}
if ($RemoteUrl) { $cfg | Add-Member -NotePropertyName RemoteUrl -NotePropertyValue $RemoteUrl -Force }
if ($Branch) { $cfg | Add-Member -NotePropertyName Branch -NotePropertyValue $Branch -Force }
[IO.File]::WriteAllText($script:ConfigFile, (ConvertTo-Json -InputObject $cfg -Depth 4), $script:Utf8)
$script:BinDir = $binDir
$config = Get-SolverConfig
Write-Ok "repository: $($config.RemoteUrl)  branch: $($config.Branch)  config: $script:ConfigFile"

Write-Step 'Checking GitHub access with your existing Git credentials'
$ls = Invoke-Native -FilePath $script:GitExe -Arguments @('ls-remote', $config.RemoteUrl, "refs/heads/$($config.Branch)") -TimeoutSec 180
if ($ls.ExitCode -ne 0 -or -not $ls.Out.Trim()) { throw "Cannot read $($config.RemoteUrl) branch $($config.Branch): $($ls.Err.Trim())" }
Write-Ok ("remote head {0}" -f ($ls.Out.Trim() -split '\s+')[0])

if (-not $SkipClaudeTest) {
    Write-Step 'Checking that Claude Code runs non-interactively with your subscription login'
    $tmp = Join-Path $script:DataDir 'selftest'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $t = Invoke-Native -FilePath $claude -Arguments @('-p', '--tools', '', '--output-format', 'text') -WorkingDirectory $tmp -StdinText 'Reply with exactly the word OK and nothing else.' -TimeoutSec 180
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($t.ExitCode -eq 0 -and $t.Out -match 'OK') { Write-Ok 'claude -p works' }
    else { Write-Bad ("claude -p failed (exit {0}): {1} {2}" -f $t.ExitCode, $t.Out.Trim(), $t.Err.Trim()); Write-Bad 'Open a terminal, run "claude", complete /login, then re-run install.ps1.' }
}

Write-Step 'Configuring automatic start at Windows logon'
if (Test-Path -LiteralPath $script:StopFlag) { Remove-Item -LiteralPath $script:StopFlag -Force }
$argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcherScript`""
$userId = "$env:USERDOMAIN\$env:USERNAME"
$registered = $false
try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine -WorkingDirectory $script:DataDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    try {
        $rep = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
        $trigger.Repetition = $rep.Repetition
    }
    catch { Write-Bad 'Could not add the 5-minute keep-alive repetition; logon start and restart-on-failure still apply.' }
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $script:TaskName -Description 'Watches GitHub for new practice questions and publishes Claude Code solutions.' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Enable-ScheduledTask -TaskName $script:TaskName | Out-Null
    $registered = $true
    if (Test-Path -LiteralPath $script:StartupShortcut) { Remove-Item -LiteralPath $script:StartupShortcut -Force }
    Write-Ok "Task Scheduler task '$($script:TaskName)' registered (at logon, keep-alive every 5 min, restart on failure)"
}
catch {
    Write-Bad "Task Scheduler registration failed: $($_.Exception.Message)"
    Write-Bad 'Falling back to a Startup-folder shortcut.'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($script:StartupShortcut)
    $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = $argLine
    $lnk.WorkingDirectory = $script:DataDir
    $lnk.WindowStyle = 7
    $lnk.Save()
    Write-Ok "Startup shortcut created: $script:StartupShortcut"
}

Write-Step 'Starting the watcher now'
if ($registered) { Start-ScheduledTask -TaskName $script:TaskName }
else { Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argLine }
Start-Sleep -Seconds 8
& (Join-Path $binDir 'control.ps1') status
Write-Host ''
Write-Host 'Control commands:' -ForegroundColor Cyan
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$binDir\control.ps1`" status|start|stop|restart|logs|retry <commit>|solve <commit>"
