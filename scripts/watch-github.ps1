
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$Branch = "main"
$RemoteUrl = "https://github.com/sujitsuresh1209-png/main.git"
$StateDir = Join-Path $env:LOCALAPPDATA "GitHubPracticeWatcher"
$StateFile = Join-Path $StateDir "last-successful.txt"
$LogFile = Join-Path $StateDir "watcher.log"
$Interval = 30
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
function Log($Message) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
}
function Git([string[]]$GitArgs) {
    $Result = & git @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $($Result -join ' ')" }
    return $Result
}
function RemoteHead {
    Git @("fetch","origin",$Branch) | Out-Null
    return ((Git @("rev-parse","origin/$Branch") | Select-Object -Last 1).ToString().Trim())
}
function ChangedFiles($Commit) {
    return @(Git @("diff-tree","--root","--no-commit-id","--name-only","-r","-m",$Commit) | Where-Object { $_ -and $_.Trim() })
}
function ProjectFiles($Commit) {
    return @(ChangedFiles $Commit | Where-Object { $_ -notmatch '^(answers|scripts)/' })
}
function PublishSolution($Commit,$Short,$OutputDir) {
    $PublishDir = Join-Path $StateDir "publish-$Short"
    try {
        Remove-Item $PublishDir -Recurse -Force -ErrorAction SilentlyContinue
        Git @("clone","--branch",$Branch,"--single-branch",$RemoteUrl,$PublishDir) | Out-Null
        $Relative = "answers/solution-$Short"
        $Destination = Join-Path $PublishDir $Relative
        if (Test-Path $Destination) {
            Log "Solution already exists for $Commit."
            return
        }
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        $Generated = @(Get-ChildItem -LiteralPath $OutputDir -Recurse -File)
        if ($Generated.Count -eq 0) { throw "No solution files to publish." }
        foreach ($File in $Generated) {
            $Rel = $File.FullName.Substring($OutputDir.Length).TrimStart('\','/')
            $Target = Join-Path $Destination $Rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Target) | Out-Null
            Copy-Item -LiteralPath $File.FullName -Destination $Target
        }
        Git @("-C",$PublishDir,"add","--",$Relative) | Out-Null
        Git @("-C",$PublishDir,"-c","user.name=Sujit","-c","user.email=sujitsuresh1209@gmail.com","commit","-m","Add solution for $Short") | Out-Null
        for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
            try {
                Git @("-C",$PublishDir,"push","origin","HEAD:refs/heads/$Branch") | Out-Null
                Log "Published solution for $Commit."
                return
            }
            catch {
                if ($Attempt -eq 3) { throw }
                Git @("-C",$PublishDir,"pull","--rebase","origin",$Branch) | Out-Null
                Start-Sleep -Seconds 2
            }
        }
    }
    finally {
        Remove-Item $PublishDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function ProcessCommit($Commit) {
    $Files = ProjectFiles $Commit
    if ($Files.Count -eq 0) {
        Log "Skipped non-project commit $Commit."
        return
    }
    $Short = $Commit.Substring(0,8)
    $Existing = @(Git @("ls-tree","-r","--name-only","origin/$Branch","--","answers/solution-$Short"))
    if ($Existing.Count -gt 0) {
        Log "Solution already exists for $Commit."
        return
    }
    $Temp = Join-Path $StateDir "job-$Short"
    $ProjectDir = Join-Path $Temp "project"
    $OutputDir = Join-Path $Temp "solution"
    try {
        Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $ProjectDir,$OutputDir | Out-Null
        $Archive = Join-Path $Temp "project.tar"
        Git @("-C",$Repo,"archive","--format=tar",$Commit,"-o",$Archive) | Out-Null
        & tar -xf $Archive -C $ProjectDir
        if ($LASTEXITCODE -ne 0) { throw "Could not extract project snapshot." }
        $Prompt = @"
Inspect the project snapshot in: $ProjectDir
Files changed in this commit:
$($Files -join "`n")
Create the complete, correct, working solution files.
Write generated files only inside: $OutputDir
Never modify original files in the snapshot.
Do not create explanations, README files, documentation, or reports.
Do not include comments in code.
Do not add unnecessary blank lines or extra spaces.
Preserve necessary filenames and relative folder structure.
Use only the provided snapshot. Do not access credentials or unrelated files.
"@
        Push-Location $Temp
        try {
            $Prompt | & claude -p --permission-mode acceptEdits --tools "Read,Write,Edit,Glob,Grep"
            if ($LASTEXITCODE -ne 0) { throw "Claude failed to generate the solution." }
        }
        finally {
            Pop-Location
        }
        $Generated = @(Get-ChildItem -LiteralPath $OutputDir -Recurse -File)
        if ($Generated.Count -eq 0) { throw "Claude generated no solution files." }
        PublishSolution $Commit $Short $OutputDir
    }
    finally {
        Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Set-Location $Repo
Log "Watcher started."
while ($true) {
    try {
        $Head = RemoteHead
        if (-not (Test-Path $StateFile)) {
            Set-Content -Path $StateFile -Value $Head
            Log "Initialized baseline at $Head. Existing commits will not be processed."
        }
        else {
            $Checkpoint = (Get-Content $StateFile -Raw).Trim()
            if ($Head -ne $Checkpoint) {
                $Commits = @(Git @("rev-list","--reverse","$Checkpoint..$Head"))
                foreach ($Commit in $Commits) {
                    ProcessCommit $Commit
                    Set-Content -Path $StateFile -Value $Commit
                }
            }
        }
    }
    catch {
        Log "ERROR: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $Interval
}
