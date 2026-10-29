param([switch]$Once)
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-SolverDirs

$config = Get-SolverConfig
$Branch = [string]$config.Branch
$RemoteRef = "refs/remotes/origin/$Branch"

if (Test-Path -LiteralPath $script:StopFlag) {
    Write-Log 'stop.flag present; watcher will not start. Run control.ps1 start to resume.'
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\PracticeSolverWatcher')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    Write-Host 'Another watcher instance is already running.'
    exit 0
}

$script:GitExe = Find-Git
if (-not $script:GitExe) { Write-Log 'git was not found on PATH.' 'ERROR'; exit 1 }
$script:TarExe = Find-Executable 'tar' @("$env:SystemRoot\System32\tar.exe")
if (-not $script:TarExe) { Write-Log 'tar.exe was not found (needs Windows 10 1803 or newer).' 'ERROR'; exit 1 }
$script:ClaudeExe = Find-Claude $config
$script:ClaudeFeatures = @{}
$script:PermissionsFile = Join-Path $script:BinDir 'claude-permissions.json'

function Initialize-ClaudeFeatures {
    $script:ClaudeExe = Find-Claude $config
    if (-not $script:ClaudeExe) { throw 'Claude Code CLI (claude) was not found. Install it or set ClaudePath in config.json.' }
    $help = Invoke-Native -FilePath $script:ClaudeExe -Arguments @('--help') -TimeoutSec 60
    $text = $help.Out + $help.Err
    foreach ($f in @('--restricted', '--permission-prompts', 'dontAsk', '--no-session-persistence', '--strict-mcp-config', '--tools')) {
        $script:ClaudeFeatures[$f] = $text.Contains($f)
    }
    if (-not $script:ClaudeFeatures['--restricted']) {
        Write-Log 'This Claude Code version has no --restricted flag. Run "claude update" for stronger isolation.' 'WARN'
    }
}

function Initialize-Mirror {
    if (-not (Test-Path -LiteralPath (Join-Path $script:MirrorDir '.git'))) {
        if (Test-Path -LiteralPath $script:MirrorDir) { Remove-Item -LiteralPath $script:MirrorDir -Recurse -Force }
        Write-Log "Cloning $($config.RemoteUrl) into $script:MirrorDir"
        Invoke-Git -Repo $script:DataDir -Arguments @('clone', '--branch', $Branch, $config.RemoteUrl, $script:MirrorDir) -TimeoutSec 1800 | Out-Null
    }
    Invoke-Git @('remote', 'set-url', 'origin', $config.RemoteUrl) | Out-Null
}

function Test-Ignored {
    param([string]$Path)
    foreach ($p in @($config.IgnoredPaths)) {
        $p = [string]$p
        if ($p.EndsWith('/')) {
            if ($Path.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        elseif ($Path.Equals($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    if ($Path.StartsWith(([string]$config.AnswersDir).TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Get-CommitInfo {
    param([string]$Commit)
    $parentLine = @(Get-Lines (Invoke-Git @('rev-list', '--parents', '-n', '1', $Commit)).Out)[0]
    $parents = @($parentLine -split ' ' | Select-Object -Skip 1)
    $subject = (Get-Lines (Invoke-Git @('log', '-1', '--format=%s', $Commit)).Out | Select-Object -First 1)
    $body = (Invoke-Git @('log', '-1', '--format=%B', $Commit)).Out
    $info = [pscustomobject]@{ Commit = $Commit; Subject = [string]$subject; Body = $body; Skip = $false; Reason = $null; Files = @() }
    if ($body -match 'Practice-Solver-Source:') { $info.Skip = $true; $info.Reason = 'answer commit published by the watcher'; return $info }
    if ($parents.Count -gt 1) { $info.Skip = $true; $info.Reason = 'merge commit (its branch commits are processed individually)'; return $info }
    if ($parents.Count -eq 0) { $diff = Invoke-Git @('diff-tree', '--root', '--no-commit-id', '-r', '--name-status', $Commit) }
    else { $diff = Invoke-Git @('diff-tree', '--no-commit-id', '-r', '--name-status', $parents[0], $Commit) }
    $files = New-Object System.Collections.ArrayList
    foreach ($line in @(Get-Lines $diff.Out)) {
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) { continue }
        if ($parts[0].StartsWith('D')) { continue }
        $path = $parts[$parts.Count - 1]
        if (-not (Test-Ignored $path)) { [void]$files.Add($path) }
    }
    $info.Files = @($files)
    if ($files.Count -eq 0) { $info.Skip = $true; $info.Reason = 'only automation, answer, or deleted files changed' }
    return $info
}

function New-SolverJob {
    param($Info, $State)
    $job = [pscustomobject]@{
        seq = [int]$State.nextSeq; commit = $Info.Commit; short = $Info.Commit.Substring(0, 12); subject = $Info.Subject
        detected = (Get-NowString); status = 'pending'; stage = 'queued'; attempts = 0; nextAttempt = (Get-NowString)
        lastError = $null; reason = $null; files = @($Info.Files); answerPath = $null; answerCommit = $null
        verified = $null; summary = $null; finished = $null; workDir = $null
    }
    if ($Info.Skip) { $job.status = 'skipped'; $job.stage = 'skipped'; $job.reason = $Info.Reason; $job.finished = (Get-NowString) }
    $State.nextSeq = [int]$State.nextSeq + 1
    [void]$State.jobs.Add($job)
    return $job
}

function Find-SolverJob {
    param($State, [string]$Commit)
    foreach ($j in $State.jobs) { if ($j.commit -eq $Commit -or $j.commit.StartsWith($Commit)) { return $j } }
    return $null
}

function Get-RemoteHead {
    Invoke-Git @('fetch', '--quiet', 'origin', $Branch) -TimeoutSec 180 | Out-Null
    return @(Get-Lines (Invoke-Git @('rev-parse', $RemoteRef)).Out)[0]
}

function Update-Queue {
    param($State, [string]$Head)
    if (-not $State.baseline) {
        $State.baseline = $Head
        $State.lastScanned = $Head
        Save-SolverState $State
        Write-Log "Baseline set to $Head. Commits up to this point will not be processed."
        return
    }
    if ($Head -eq $State.lastScanned) { return }
    $exists = Invoke-Git @('cat-file', '-e', "$($State.lastScanned)^{commit}") -AllowFailure
    if ($exists.ExitCode -ne 0) {
        Write-Log "Last scanned commit $($State.lastScanned) no longer exists (history rewritten). Rebasing scan point to $Head." 'WARN'
        $State.lastScanned = $Head
        Save-SolverState $State
        return
    }
    $commits = Get-Lines (Invoke-Git @('rev-list', '--reverse', '--topo-order', "$($State.lastScanned)..$Head")).Out
    foreach ($c in $commits) {
        if (Find-SolverJob $State $c) { continue }
        $info = Get-CommitInfo $c
        $job = New-SolverJob $info $State
        if ($job.status -eq 'skipped') { Write-Log "Skipped $($job.short) '$($job.subject)': $($job.reason)" }
        else { Write-Log "Queued $($job.short) '$($job.subject)' ($($job.files.Count) project file(s))" }
    }
    $State.lastScanned = $Head
    Save-SolverState $State
}

function Invoke-Requests {
    param($State)
    foreach ($f in @(Get-ChildItem -LiteralPath $script:RequestDir -File -ErrorAction SilentlyContinue)) {
        try {
            $name = $f.Name
            Remove-Item -LiteralPath $f.FullName -Force
            if ($name -notmatch '^(retry|solve)-([0-9a-fA-F]{4,40})$') { continue }
            $kind = $Matches[1]
            $rev = Invoke-Git @('rev-parse', '--verify', '--quiet', "$($Matches[2])^{commit}") -AllowFailure
            $full = (Get-Lines $rev.Out | Select-Object -First 1)
            if ($rev.ExitCode -ne 0 -or -not $full) { Write-Log "Request $name ignored: commit not found." 'WARN'; continue }
            $job = Find-SolverJob $State $full
            if ($job -and $job.status -eq 'done') { Write-Log "Request $name ignored: $($job.short) is already published at $($job.answerPath)." 'WARN'; continue }
            if (-not $job) {
                if ($kind -ne 'solve') { Write-Log "Request $name ignored: no job for that commit. Use solve instead." 'WARN'; continue }
                $info = Get-CommitInfo $full
                if ($info.Skip -and $info.Files.Count -eq 0 -and $info.Reason -notmatch 'answer commit') {
                    $files = Get-Lines (Invoke-Git @('ls-tree', '-r', '--name-only', $full)).Out
                    $info.Files = @($files | Where-Object { -not (Test-Ignored $_) })
                }
                $info.Skip = $false
                $job = New-SolverJob $info $State
            }
            if ($kind -eq 'solve' -and $job.files.Count -eq 0) {
                $info = Get-CommitInfo $full
                $job.files = @($info.Files)
            }
            if ($kind -eq 'solve') { $job.stage = 'queued' }
            $job.status = 'pending'; $job.attempts = 0; $job.nextAttempt = (Get-NowString)
            $job.lastError = $null; $job.reason = $null; $job.finished = $null
            Save-SolverState $State
            Write-Log "Request $name accepted: $($job.short) queued."
        }
        catch { Write-Log "Request $($f.Name) failed: $($_.Exception.Message)" 'ERROR' }
    }
}

function Test-AnswerPublished {
    param([string]$AnswerRel)
    $r = Invoke-Git @('ls-tree', $RemoteRef, '--', $AnswerRel) -AllowFailure
    return ($r.ExitCode -eq 0 -and @(Get-Lines $r.Out).Count -gt 0)
}

function Remove-BuildArtifacts {
    param([string]$Dir)
    $dirNames = @('node_modules', '__pycache__', '.pytest_cache', '.mypy_cache', '.gradle', '.venv', 'venv', '.git', '.idea', '.vscode', '.claude')
    foreach ($d in @(Get-ChildItem -LiteralPath $Dir -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $dirNames -contains $_.Name })) {
        if (Test-Path -LiteralPath $d.FullName) { Remove-Item -LiteralPath $d.FullName -Recurse -Force }
    }
    $exts = @('.class', '.pyc', '.pyo', '.o', '.obj', '.exe', '.out', '.dll', '.so', '.pdb', '.ilk', '.jar', '.log')
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($exts -contains $f.Extension.ToLowerInvariant() -or $f.Name -eq 'a.out' -or $f.Name -eq '.DS_Store') { Remove-Item -LiteralPath $f.FullName -Force }
    }
}

function Remove-WorkDir {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return }
    try { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop }
    catch { try { & $env:ComSpec /d /c rd /s /q "\\?\$Dir" 2>&1 | Out-Null } catch { } }
    if (Test-Path -LiteralPath $Dir) { Write-Log "Could not fully remove $Dir; it can be deleted manually." 'WARN' }
}

function Get-SolverPrompt {
    param($Job, [string]$Body)
    $fileList = (@($Job.files) | ForEach-Object { "- $_" }) -join "`n"
    if (-not $fileList) { $fileList = '- (none detected; inspect the whole snapshot)' }
    $verify = 'Copy the solution and any needed project files into build/, then compile, run and test them with the available tools (python, node, npm, javac/java, gcc/g++, sqlite3, dotnet, go and similar). Fix every failure and test again until it works.'
    if (-not $config.AllowCodeExecution) { $verify = 'Command execution is disabled. Verify by careful review of the requirements, edge cases and syntax.' }
    return @"
You are an automated solver for a programming practice repository. A new commit was pushed and you must produce its complete answer without asking any questions.

Commit: $($Job.commit)
Commit message:
$($Body.Trim())

Files added or changed in this commit (paths relative to the repository root):
$fileList

Layout of the current directory:
- project/  read-only snapshot of the repository at this commit. Never modify it.
- solution/ write the final answer files here and nothing else.
- build/    scratch space for compiling, running and testing. Nothing in it is published.

Instructions:
1. Read the changed files and every related file in project/ (question text, instructions, README, starter code, tests, images or screenshots, PDFs, data files) and work out exactly what is being asked.
2. Write the complete, correct, runnable solution in the language the task requires (Java, Python, C, C++, JavaScript, TypeScript, HTML, CSS, SQL or any other).
3. Inside solution/, keep repository-relative paths. Files that complete or replace starter files keep the same path and filename. New files go in the task's folder. Keep every required filename, class name, function signature and input/output format.
4. Code must have no comments, no unnecessary blank lines, and no explanations, README files or other documentation. If the task asks for a written or non-code answer, put it in one answer file with a suitable extension in the task's folder.
5. $verify
6. Never put build outputs, compiled binaries, .class files, node_modules or caches in solution/.
7. Work only inside the current directory. Do not read or change anything outside it. Create and edit files with the Write and Edit tools, not shell redirection. Run one simple command per shell call.
8. Finally write result.json in the current directory (not inside solution/) with this shape:
{"task_found": true, "summary": "one sentence", "languages": ["..."], "verified": true, "verification": "commands run and their outcome"}
Set verified to false if you could not run or test the solution.
If the commit contains no question, assignment, exercise, TODO or project to solve, write {"task_found": false, "summary": "reason"} and leave solution/ empty.
"@
}

function New-Solution {
    param($Job, [string]$JobDir)
    $projectDir = Join-Path $JobDir 'project'
    $solutionDir = Join-Path $JobDir 'solution'
    $buildDir = Join-Path $JobDir 'build'
    New-Item -ItemType Directory -Force -Path $projectDir, $solutionDir, $buildDir | Out-Null
    $tar = Join-Path $JobDir 'snapshot.tar'
    Invoke-Git @('archive', '--format=tar', '-o', $tar, $Job.commit) -TimeoutSec 600 | Out-Null
    $x = Invoke-Native -FilePath $script:TarExe -Arguments @('-xf', $tar, '-C', $projectDir) -TimeoutSec 600
    if ($x.ExitCode -ne 0) { throw "Could not extract the commit snapshot: $($x.Err)" }
    Remove-Item -LiteralPath $tar -Force
    foreach ($p in @($config.IgnoredPaths) + @([string]$config.AnswersDir)) {
        $t = Join-Path $projectDir (([string]$p).TrimEnd('/') -replace '/', '\')
        if ((([string]$p).EndsWith('/') -or $p -eq $config.AnswersDir) -and (Test-Path -LiteralPath $t)) { Remove-Item -LiteralPath $t -Recurse -Force }
    }
    $body = (Invoke-Git @('log', '-1', '--format=%B', $Job.commit)).Out
    $prompt = Get-SolverPrompt $Job $body
    $tools = 'Read,Write,Edit,Glob,Grep'
    if ($config.AllowCodeExecution) { $tools += ',Bash' }
    $claudeArgs = @('-p', '--settings', $script:PermissionsFile, '--output-format', 'text')
    if ($script:ClaudeFeatures['--restricted']) { $claudeArgs += '--restricted' } else { $claudeArgs += @('--setting-sources', 'project') }
    if ($script:ClaudeFeatures['--tools']) { $claudeArgs += @('--tools', $tools) }
    if ($script:ClaudeFeatures['dontAsk']) { $claudeArgs += @('--permission-mode', 'dontAsk') } else { $claudeArgs += @('--permission-mode', 'acceptEdits') }
    if ($script:ClaudeFeatures['--permission-prompts']) { $claudeArgs += @('--permission-prompts', 'none') }
    if ($script:ClaudeFeatures['--strict-mcp-config']) { $claudeArgs += '--strict-mcp-config' }
    if ($script:ClaudeFeatures['--no-session-persistence']) { $claudeArgs += '--no-session-persistence' }
    if ($config.ClaudeModel) { $claudeArgs += @('--model', [string]$config.ClaudeModel) }
    Write-Log "Generating solution for $($Job.short) with Claude Code (attempt $($Job.attempts))"
    $started = Get-Date
    $r = Invoke-Native -FilePath $script:ClaudeExe -Arguments $claudeArgs -WorkingDirectory $JobDir -StdinText $prompt -TimeoutSec ([int]$config.ClaudeTimeoutMinutes * 60)
    $logFile = Join-Path $script:JobLogDir ('{0}-attempt{1}.log' -f $Job.short, $Job.attempts)
    $logText = "COMMIT $($Job.commit)`nSTARTED $started`nEXIT $($r.ExitCode) TIMEDOUT $($r.TimedOut)`n`n--- PROMPT ---`n$prompt`n`n--- STDOUT ---`n$($r.Out)`n`n--- STDERR ---`n$($r.Err)`n"
    [IO.File]::WriteAllText($logFile, $logText, $script:Utf8)
    $combined = $r.Out + "`n" + $r.Err
    if ($r.TimedOut) { throw "Claude timed out after $($config.ClaudeTimeoutMinutes) minutes. See $logFile" }
    if ($r.ExitCode -ne 0) {
        if ($combined -match '(?i)(usage limit|rate limit|limit reached|limit will reset|resets at|too many requests|overloaded_error|status 429)') {
            throw "USAGE_LIMIT: Claude usage or rate limit reached. See $logFile"
        }
        if ($combined -match '(?i)(not logged in|please run /login|authentication_error|invalid api key|oauth token has expired)') {
            throw "Claude is not authenticated. Run 'claude' once and log in. See $logFile"
        }
        $tail = ($combined.Trim() -split "`n" | Select-Object -Last 5) -join ' | '
        throw "Claude exited with code $($r.ExitCode): $tail"
    }
    $result = $null
    $resultFile = Join-Path $JobDir 'result.json'
    if (Test-Path -LiteralPath $resultFile) {
        try { $result = Get-Content -Raw -LiteralPath $resultFile | ConvertFrom-Json } catch { Write-Log "result.json for $($Job.short) is not valid JSON." 'WARN' }
        Copy-Item -LiteralPath $resultFile -Destination (Join-Path $script:JobLogDir ('{0}-result.json' -f $Job.short)) -Force
    }
    Remove-BuildArtifacts $solutionDir
    $count = @(Get-ChildItem -LiteralPath $solutionDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    $summary = $null
    $verified = $false
    $taskFound = $true
    if ($result) {
        if ($result.PSObject.Properties['summary']) { $summary = [string]$result.summary }
        if ($result.PSObject.Properties['verified']) { $verified = [bool]$result.verified }
        if ($result.PSObject.Properties['task_found']) { $taskFound = [bool]$result.task_found }
    }
    if ($count -eq 0) {
        if (-not $taskFound) { return [pscustomobject]@{ NoTask = $true; Summary = $summary; Verified = $false } }
        throw "Claude finished but produced no solution files. See $logFile"
    }
    return [pscustomobject]@{ NoTask = $false; Summary = $summary; Verified = $verified }
}

function Get-GitIdentity {
    $name = [string]$config.GitUserName
    $email = [string]$config.GitUserEmail
    if (-not $name) { $name = (Get-Lines (Invoke-Git @('config', 'user.name') -AllowFailure).Out | Select-Object -First 1) }
    if (-not $email) { $email = (Get-Lines (Invoke-Git @('config', 'user.email') -AllowFailure).Out | Select-Object -First 1) }
    if (-not $name) { $name = 'Practice Solver' }
    if (-not $email) { $email = 'practice-solver@localhost' }
    return @($name, $email)
}

function Publish-Solution {
    param($Job, [string]$SolutionDir, [string]$AnswerRel)
    $identity = Get-GitIdentity
    $verifiedText = 'no'
    if ($Job.verified) { $verifiedText = 'yes' }
    $message = "Add solution for $($Job.short): $($Job.subject)`n`nPractice-Solver-Source: $($Job.commit)`nPractice-Solver-Verified: $verifiedText`n"
    $msgFile = Join-Path $script:DataDir 'commit-message.txt'
    [IO.File]::WriteAllText($msgFile, $message, $script:Utf8)
    $lastError = ''
    for ($i = 1; $i -le 5; $i++) {
        try {
            Invoke-Git @('fetch', '--quiet', 'origin', $Branch) -TimeoutSec 180 | Out-Null
            if (Test-AnswerPublished $AnswerRel) { return 'existing' }
            Invoke-Git @('checkout', '--quiet', '-f', '-B', $Branch, $RemoteRef) | Out-Null
            Invoke-Git @('reset', '--quiet', '--hard', $RemoteRef) | Out-Null
            Invoke-Git @('clean', '-fdxq') | Out-Null
            $dest = Join-Path $script:MirrorDir ($AnswerRel -replace '/', '\')
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-Item -Path (Join-Path $SolutionDir '*') -Destination $dest -Recurse -Force
            Invoke-Git @('add', '-A', '-f', '--', $AnswerRel) | Out-Null
            $staged = Get-Lines (Invoke-Git @('diff', '--cached', '--name-only')).Out
            if ($staged.Count -eq 0) { throw 'Nothing to commit after copying the solution.' }
            Invoke-Git @('-c', "user.name=$($identity[0])", '-c', "user.email=$($identity[1])", 'commit', '--quiet', '--no-verify', '-F', $msgFile) | Out-Null
            $newCommit = @(Get-Lines (Invoke-Git @('rev-parse', 'HEAD')).Out)[0]
            $push = Invoke-Git @('push', '--quiet', 'origin', "HEAD:refs/heads/$Branch") -TimeoutSec 300 -AllowFailure
            if ($push.ExitCode -eq 0) {
                Invoke-Git @('fetch', '--quiet', 'origin', $Branch) -TimeoutSec 180 | Out-Null
                $check = Invoke-Git @('merge-base', '--is-ancestor', $newCommit, $RemoteRef) -AllowFailure
                if ($check.ExitCode -eq 0) { return $newCommit }
                $lastError = 'Push reported success but the commit is not on the remote branch.'
            }
            else {
                $lastError = ($push.Err + ' ' + $push.Out).Trim()
                if ($push.TimedOut) { $lastError = 'git push timed out' }
            }
        }
        catch { $lastError = $_.Exception.Message }
        Write-Log "Publish attempt $i for $($Job.short) failed: $lastError" 'WARN'
        Start-Sleep -Seconds ([Math]::Pow(2, $i))
    }
    throw "Publishing failed after 5 attempts: $lastError"
}

function Invoke-SolverJob {
    param($State, $Job)
    if (-not $Job.PSObject.Properties['workDir']) { $Job | Add-Member -NotePropertyName workDir -NotePropertyValue $null -Force }
    $jobDir = [string]$Job.workDir
    if (-not $jobDir) { $jobDir = Join-Path $script:JobsDir $Job.short }
    $solutionDir = Join-Path $jobDir 'solution'
    $answerRel = "$(([string]$config.AnswersDir).TrimEnd('/'))/solution-$($Job.short)"
    $Job.status = 'running'
    $Job.attempts = [int]$Job.attempts + 1
    Save-SolverState $State
    try {
        if (Test-AnswerPublished $answerRel) {
            $Job.status = 'done'; $Job.stage = 'published'; $Job.answerPath = $answerRel; $Job.finished = (Get-NowString)
            $Job.reason = 'answer directory already existed on the remote; left unchanged'
            Save-SolverState $State
            Write-Log "$($Job.short): $answerRel already exists on the remote; not overwriting."
            return
        }
        $haveSolution = ($Job.stage -eq 'generated') -and (Test-Path -LiteralPath $solutionDir) -and (@(Get-ChildItem -LiteralPath $solutionDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count -gt 0)
        if ($haveSolution) {
            Write-Log "$($Job.short): reusing previously generated solution; publishing only."
        }
        else {
            if (-not $script:ClaudeExe -or $script:ClaudeFeatures.Count -eq 0) { Initialize-ClaudeFeatures }
            if ($Job.workDir) { Remove-WorkDir $Job.workDir }
            $jobDir = Join-Path $script:JobsDir ('{0}-a{1}' -f $Job.short, $Job.attempts)
            $solutionDir = Join-Path $jobDir 'solution'
            Remove-WorkDir $jobDir
            $Job.workDir = $jobDir
            $Job.stage = 'generating'
            Save-SolverState $State
            $gen = New-Solution $Job $jobDir
            $Job.summary = $gen.Summary
            if ($gen.NoTask) {
                $Job.status = 'skipped'; $Job.stage = 'skipped'; $Job.finished = (Get-NowString)
                $Job.reason = "no task found by Claude: $($gen.Summary)"
                Save-SolverState $State
                Write-Log "$($Job.short): no question or project found ($($gen.Summary)); nothing published."
                Remove-WorkDir $jobDir
                return
            }
            $Job.stage = 'generated'
            $Job.verified = $gen.Verified
            Save-SolverState $State
            Write-Log "$($Job.short): solution generated (verified: $($gen.Verified)). $($gen.Summary)"
        }
        $published = Publish-Solution $Job $solutionDir $answerRel
        $Job.status = 'done'; $Job.stage = 'published'; $Job.answerPath = $answerRel; $Job.finished = (Get-NowString); $Job.lastError = $null
        if ($published -eq 'existing') { $Job.reason = 'answer directory appeared on the remote before publishing; left unchanged' }
        else { $Job.answerCommit = $published }
        Save-SolverState $State
        Write-Log "$($Job.short): published $answerRel ($published)."
        Remove-WorkDir $jobDir
    }
    catch {
        $err = $_.Exception.Message
        $Job.lastError = $err
        if ($err.StartsWith('USAGE_LIMIT:')) {
            $Job.attempts = [Math]::Max(0, [int]$Job.attempts - 1)
            $Job.status = 'pending'
            $Job.nextAttempt = (Get-Date).AddMinutes([int]$config.UsageLimitRetryMinutes).ToString('o')
            Write-Log "$($Job.short): $err Retrying at $($Job.nextAttempt)." 'WARN'
        }
        elseif ([int]$Job.attempts -ge [int]$config.MaxAttempts) {
            $Job.status = 'failed'
            Write-Log "$($Job.short): giving up after $($Job.attempts) attempts: $err. Use 'control.ps1 retry $($Job.short)' to try again." 'ERROR'
        }
        else {
            $delay = [Math]::Min(60, [Math]::Pow(2, [int]$Job.attempts - 1))
            $Job.status = 'pending'
            $Job.nextAttempt = (Get-Date).AddMinutes($delay).ToString('o')
            Write-Log "$($Job.short): attempt $($Job.attempts) failed: $err. Retrying in $delay minute(s)." 'ERROR'
        }
        Save-SolverState $State
    }
}

function Invoke-DueJobs {
    param($State)
    $now = Get-Date
    $due = @($State.jobs | Where-Object { $_.status -eq 'pending' -and (ConvertTo-Date $_.nextAttempt) -le $now } | Sort-Object { [int]$_.seq })
    foreach ($job in $due) {
        if (Test-Path -LiteralPath $script:StopFlag) { return }
        Invoke-SolverJob $State $job
    }
}

function Remove-OldLogs {
    $limit = (Get-Date).AddDays(-[int]$config.KeepLogDays)
    Get-ChildItem -LiteralPath $script:LogDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
}

try {
    Write-Log "Watcher starting (pid $PID) for $($config.RemoteUrl) branch $Branch, polling every $($config.PollSeconds)s."
    $state = Read-SolverState
    if (-not $state) {
        $state = [pscustomobject]@{ version = 1; remoteUrl = $config.RemoteUrl; branch = $Branch; baseline = $null; lastScanned = $null; nextSeq = 1; jobs = (New-Object System.Collections.ArrayList) }
    }
    foreach ($j in $state.jobs) {
        if ($j.status -eq 'running') { $j.status = 'pending'; $j.nextAttempt = (Get-NowString); Write-Log "$($j.short): was interrupted; re-queued." 'WARN' }
    }
    Save-SolverState $state
    try { Initialize-ClaudeFeatures } catch { Write-Log $_.Exception.Message 'ERROR' }
    $mirrorReady = $false
    $failures = 0
    $lastCleanup = [DateTime]::MinValue
    while ($true) {
        if (Test-Path -LiteralPath $script:StopFlag) { Write-Log 'stop.flag found; watcher exiting.'; break }
        try {
            if (-not $mirrorReady) { Initialize-Mirror; $mirrorReady = $true }
            $head = Get-RemoteHead
            if ($failures -gt 0) { Write-Log "Connection restored after $failures failed poll(s)." }
            $failures = 0
            Update-Queue $state $head
            Invoke-Requests $state
            Invoke-DueJobs $state
            [IO.File]::WriteAllText($script:HeartbeatFile, "$(Get-NowString) pid=$PID head=$head", $script:Utf8)
        }
        catch {
            $failures++
            if ($failures -eq 1 -or ($failures % 20) -eq 0) { Write-Log "Poll failed ($failures in a row): $($_.Exception.Message)" 'ERROR' }
            [IO.File]::WriteAllText($script:HeartbeatFile, "$(Get-NowString) pid=$PID error=$($_.Exception.Message)", $script:Utf8)
        }
        if (((Get-Date) - $lastCleanup).TotalHours -ge 24) { Remove-OldLogs; $lastCleanup = Get-Date }
        if ($Once) { break }
        for ($i = 0; $i -lt [int]$config.PollSeconds; $i++) {
            if (Test-Path -LiteralPath $script:StopFlag) { break }
            Start-Sleep -Seconds 1
        }
    }
}
catch {
    Write-Log "Watcher crashed: $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
}
