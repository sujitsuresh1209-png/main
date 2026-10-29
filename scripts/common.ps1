$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:BinDir = $PSScriptRoot
$script:DataDir = Join-Path $env:LOCALAPPDATA 'PracticeSolver'
$script:LogDir = Join-Path $script:DataDir 'logs'
$script:JobLogDir = Join-Path $script:LogDir 'jobs'
$script:JobsDir = Join-Path $script:DataDir 'jobs'
$script:RequestDir = Join-Path $script:DataDir 'requests'
$script:MirrorDir = Join-Path $script:DataDir 'repo'
$script:StateFile = Join-Path $script:DataDir 'state.json'
$script:ConfigFile = Join-Path $script:DataDir 'config.json'
$script:StopFlag = Join-Path $script:DataDir 'stop.flag'
$script:HeartbeatFile = Join-Path $script:DataDir 'heartbeat.txt'
$script:TaskName = 'PracticeSolverWatcher'
$script:StartupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'PracticeSolverWatcher.lnk'

function Initialize-SolverDirs {
    foreach ($d in @($script:DataDir, $script:LogDir, $script:JobLogDir, $script:JobsDir, $script:RequestDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $file = Join-Path $script:LogDir ('watcher-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    try { [IO.File]::AppendAllText($file, $line + [Environment]::NewLine, $script:Utf8) } catch { }
    Write-Host $line
}

function Get-SolverConfig {
    $defaultFile = Join-Path $script:BinDir 'config.default.json'
    $config = Get-Content -Raw -LiteralPath $defaultFile | ConvertFrom-Json
    if (Test-Path -LiteralPath $script:ConfigFile) {
        $user = Get-Content -Raw -LiteralPath $script:ConfigFile | ConvertFrom-Json
        foreach ($p in $user.PSObject.Properties) {
            $config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    }
    return $config
}

function ConvertTo-WinArg {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($c in $Value.ToCharArray()) {
        if ($c -eq '\') {
            $slashes++
        }
        elseif ($c -eq '"') {
            [void]$sb.Append('\' * ($slashes * 2 + 1))
            [void]$sb.Append('"')
            $slashes = 0
        }
        else {
            if ($slashes -gt 0) { [void]$sb.Append('\' * $slashes) }
            $slashes = 0
            [void]$sb.Append($c)
        }
    }
    if ($slashes -gt 0) { [void]$sb.Append('\' * ($slashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    try { & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null } catch { }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $script:DataDir,
        [string]$StdinText = $null,
        [int]$TimeoutSec = 600,
        [hashtable]$Environment = @{}
    )
    $argLine = ($Arguments | ForEach-Object { ConvertTo-WinArg $_ }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /s /c "' + (ConvertTo-WinArg $FilePath) + ' ' + $argLine + '"'
    }
    else {
        $psi.FileName = $FilePath
        $psi.Arguments = $argLine
    }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    try {
        if ($StdinText) {
            $bytes = $script:Utf8.GetBytes($StdinText)
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $p.StandardInput.BaseStream.Flush()
        }
        $p.StandardInput.Close()
    }
    catch { }
    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        Stop-ProcessTree -ProcessId $p.Id
        [void]$p.WaitForExit(15000)
    }
    else {
        $p.WaitForExit()
    }
    $out = ''
    $err = ''
    if ($outTask.Wait(15000)) { $out = $outTask.Result }
    if ($errTask.Wait(15000)) { $err = $errTask.Result }
    $code = -1
    if ($p.HasExited) { $code = $p.ExitCode }
    return [pscustomobject]@{ ExitCode = $code; Out = $out; Err = $err; TimedOut = $timedOut }
}

function Find-Executable {
    param([string]$Name, [string[]]$Candidates = @())
    $found = @(Get-Command $Name -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' })
    foreach ($ext in @('.exe', '.cmd', '.bat')) {
        foreach ($f in $found) {
            if ([IO.Path]::GetExtension($f.Source).ToLowerInvariant() -eq $ext) { return $f.Source }
        }
    }
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Find-Git {
    return Find-Executable 'git' @("$env:ProgramFiles\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")
}

function Find-Claude {
    param($Config)
    if ($Config -and $Config.ClaudePath -and (Test-Path -LiteralPath $Config.ClaudePath)) { return $Config.ClaudePath }
    return Find-Executable 'claude' @("$env:USERPROFILE\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd", "$env:LOCALAPPDATA\Programs\claude\claude.exe")
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$Repo = $script:MirrorDir,
        [int]$TimeoutSec = 300,
        [switch]$AllowFailure
    )
    $all = @('-C', $Repo, '-c', 'core.quotepath=false') + $Arguments
    $r = Invoke-Native -FilePath $script:GitExe -Arguments $all -TimeoutSec $TimeoutSec -Environment @{ GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'never' }
    if ($r.TimedOut -and -not $AllowFailure) { throw ('git {0} timed out after {1}s' -f ($Arguments -join ' '), $TimeoutSec) }
    if ($r.ExitCode -ne 0 -and -not $AllowFailure) {
        throw ('git {0} failed ({1}): {2}' -f ($Arguments -join ' '), $r.ExitCode, ($r.Err + ' ' + $r.Out).Trim())
    }
    return $r
}

function Get-Lines {
    param([string]$Text)
    if (-not $Text) { return @() }
    return @($Text -split "`r?`n" | Where-Object { $_ -ne '' })
}

function ConvertTo-Date {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return [DateTime]::MinValue }
    if ($Value -is [DateTime]) { return $Value }
    return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

function Get-NowString { return (Get-Date).ToString('o') }

function Read-SolverState {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return $null }
    $s = Get-Content -Raw -LiteralPath $script:StateFile | ConvertFrom-Json
    $list = New-Object System.Collections.ArrayList
    foreach ($j in @($s.jobs)) { if ($null -ne $j) { [void]$list.Add($j) } }
    $s | Add-Member -NotePropertyName jobs -NotePropertyValue $list -Force
    return $s
}

function Save-SolverState {
    param($State)
    $State | Add-Member -NotePropertyName updated -NotePropertyValue (Get-NowString) -Force
    $json = ConvertTo-Json -InputObject $State -Depth 8
    $tmp = $script:StateFile + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $script:StateFile -Force
}

function Get-WatcherProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'PracticeSolver\\bin\\watcher\.ps1' })
}

function Get-SolverTask {
    return Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
}
