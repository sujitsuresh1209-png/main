# Practice Solver automation

Watches `origin/main` every 30 seconds. When a new commit adds or changes a practice question or project, it runs Claude Code headless with your existing subscription login, generates and tests the solution, and pushes it to `answers/solution-<12-char commit>/`.

## One-time setup (Windows)

```powershell
cd C:\Users\white\main
git pull origin main
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1
```

`install.ps1` checks git, tar and `claude`, verifies GitHub read access and a headless `claude -p` call, copies the scripts to `%LOCALAPPDATA%\PracticeSolver\bin`, registers the Task Scheduler task `PracticeSolverWatcher`, and starts it. The task starts at logon, re-checks every 5 minutes that it is alive, and restarts on failure. It needs no admin rights. If Task Scheduler refuses, it falls back to a Startup-folder shortcut.

Re-run `install.ps1` after pulling changes to these scripts.

## Control

```powershell
$c = "$env:LOCALAPPDATA\PracticeSolver\bin\control.ps1"
powershell -ExecutionPolicy Bypass -File $c status
powershell -ExecutionPolicy Bypass -File $c stop
powershell -ExecutionPolicy Bypass -File $c start
powershell -ExecutionPolicy Bypass -File $c restart
powershell -ExecutionPolicy Bypass -File $c logs
powershell -ExecutionPolicy Bypass -File $c retry <commit>
powershell -ExecutionPolicy Bypass -File $c solve <commit>
```

`stop` persists across reboots until `start`. `solve` processes a commit from before the baseline, for example `solve ccaee546` for the existing watcher test project. `uninstall.ps1` removes autostart; `-RemoveData` also deletes state and logs.

## How it works

- Baseline: on first start the current `origin/main` head is recorded and nothing older is processed.
- Every new commit is queued in order. Commits that only touch `answers/`, `scripts/`, `.gitignore` or `.gitattributes`, merge commits, deletions, and commits carrying the `Practice-Solver-Source:` trailer (the watcher's own answers) are skipped, so the watcher never loops on its own pushes.
- Each job extracts the commit snapshot into `%LOCALAPPDATA%\PracticeSolver\jobs\<commit>-a<attempt>\project`. Claude writes the answer to `solution\` and tests it in `build\`. Your local clone `C:\Users\white\main` is never touched. Publishing uses a private clone in `%LOCALAPPDATA%\PracticeSolver\repo`.
- A job is marked `done` only after its commit is confirmed on `origin/main`. Failures retry with backoff (1, 2, 4 ... 60 minutes, 12 attempts). Usage-limit errors retry every 30 minutes without using up attempts. A generated-but-unpublished answer is published on the next retry without regenerating it. Jobs interrupted by a restart are re-queued.
- An existing `answers/solution-<commit>/` folder is never overwritten.

## Files

| Path under `%LOCALAPPDATA%\PracticeSolver` | Purpose |
| --- | --- |
| `state.json` | baseline, last scanned commit, every job with status, attempts, errors, answer path and commit |
| `logs\watcher-YYYY-MM-DD.log` | watcher log |
| `logs\jobs\<commit>-attemptN.log` | full Claude prompt and output per attempt |
| `config.json` | settings (poll interval, model, timeouts, `AllowCodeExecution`) |
| `heartbeat.txt` | time of last successful poll |

## Permissions and limits

- Claude runs with `--restricted`, `--permission-mode dontAsk`, no MCP servers, no web tools, and the allowlist in `claude-permissions.json`. File tools are confined to the job folder. Shell commands are limited to compilers, interpreters and test runners. `git`, `curl`, `rm` and similar commands are denied. No permission-bypass flag is used.
- Allowed interpreters such as `python` and `node` can technically read files elsewhere on the PC when they run generated code. Set `"AllowCodeExecution": false` in `config.json` to disable all command execution; solutions are then reviewed but not run.
- It runs only while you are logged in and the PC is awake and online. It does not run while the PC is asleep or off; queued commits are processed when the PC is back.
- Each job consumes your Claude subscription usage. When the limit is reached, jobs wait and retry automatically.
- Pushes use your normal Git credentials (Git Credential Manager). If the credentials expire, publishing fails and is retried; run any `git push` once interactively to refresh them.
