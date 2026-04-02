# RECOVERY.md

Use this when the agent crashes, disappears, loses continuity, or AtomicBot says the gateway is down.

The goal is simple:

1. re-establish ground truth
2. restore gateway health
3. verify memory sidecars
4. resume from checkpoints, not vibes

## Ground Truth Paths

- State dir: `C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw`
- Workspace: `C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw\workspace`
- Config: `C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw\openclaw.json`
- Gateway stdout log: `C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw\gateway.stdout.log`
- Gateway stderr log: `C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw\gateway.stderr.log`
- Gateway pid file: `C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw\gateway.pid`
- Bundled CLI: `C:\Users\TacIm\AppData\Local\Programs\atomicbot-desktop\resources\openclaw\openclaw.mjs`
- Bundled Node: `C:\Users\TacIm\AppData\Local\Programs\atomicbot-desktop\resources\node\win32-x64\node.exe`
- Gateway port: `127.0.0.1:18789`
- Reranker health: `http://127.0.0.1:8780/health`
- Reranker container: `codee-memory-reranker`
- Qdrant container: `codee-qdrant-memory`

## First Principle

- Trust files, processes, logs, and health checks over conversational memory.
- Do not say "back up" until there is proof.
- Do not re-enable heartbeat unless there is explicit proof it is stable.

## Recovery Setup

Fast path:

```powershell
.\recover-openclaw.ps1
```

If the gateway listener is wedged and the clean restart path fails:

```powershell
.\recover-openclaw.ps1 -ForceGatewayRestart
```

Open PowerShell and set the recovery variables:

```powershell
$StateDir = 'C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw'
$Workspace = 'C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw\workspace'
$Config = Join-Path $StateDir 'openclaw.json'
$Cli = 'C:\Users\TacIm\AppData\Local\Programs\atomicbot-desktop\resources\openclaw\openclaw.mjs'
$Node = 'C:\Users\TacIm\AppData\Local\Programs\atomicbot-desktop\resources\node\win32-x64\node.exe'
$Token = (Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json).gateway.auth.token
$env:OPENCLAW_STATE_DIR = $StateDir
$env:OPENCLAW_CONFIG_PATH = $Config
```

Do not print or paste the token into notes or chat.

## Step 1: Rebuild Context

Read these before touching runtime:

1. `AGENTS.md`
2. `SOUL.md`
3. `USER.md`
4. `memory/YYYY-MM-DD.md` for today and yesterday
5. `MEMORY.md` if this is the main/private session

Then identify the last concrete checkpoint:

- last changed file
- last commit hash if any
- last verified service or endpoint
- exact next task that was pending

If there is no checkpoint, say so plainly and rebuild from files only.

## Step 2: Quick Health Triage

Check whether the gateway is actually listening:

```powershell
netstat -ano | findstr ":18789"
```

Healthy sign:

- a `LISTENING` row on `127.0.0.1:18789` or `[::1]:18789`

Check gateway health:

```powershell
& $Node $Cli gateway health --json --token $Token
```

Check reranker:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8780/health'
docker ps --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}" | Select-String 'codee-memory-reranker|codee-qdrant-memory'
```

Notes:

- Qdrant is API-key protected; a raw unauthenticated HTTP call can return `401` and still mean the container is up.
- Container status plus local port binding is acceptable proof for Qdrant unless a keyed check is needed.

## Step 3: If the Gateway Is Down or Stuck

First try the clean path:

```powershell
& $Node $Cli gateway stop --token $Token
& $Node $Cli gateway start --token $Token
& $Node $Cli gateway health --json --token $Token
```

If that fails, inspect the evidence:

```powershell
Get-Content -LiteralPath (Join-Path $StateDir 'gateway.stderr.log')
Get-Content -LiteralPath (Join-Path $StateDir 'gateway.stdout.log')
netstat -ano | findstr ":18789"
```

Known failure patterns on this install:

- stale lock / "gateway already running"
- port `18789` already in use
- pid file and live listener disagree

If pid and listener disagree, trust the live listener and logs over the pid file.

If a stale listener is blocking restart and the gateway health check still fails, stop only that listener process, then retry the clean start:

```powershell
$ListenerPid = netstat -ano | findstr ":18789" | Select-String 'LISTENING' | ForEach-Object { ($_ -split '\s+')[-1] } | Select-Object -First 1
if ($ListenerPid) { Stop-Process -Id $ListenerPid -Force }
Remove-Item -LiteralPath (Join-Path $StateDir 'gateway.pid') -Force -ErrorAction SilentlyContinue
& $Node $Cli gateway start --token $Token
& $Node $Cli gateway health --json --token $Token
```

Only do the forced stop if the clean path failed and you have proof the existing listener is unhealthy.

## Step 4: Verify AtomicBot Reconnected

After gateway health succeeds, check for an established local connection:

```powershell
netstat -ano | findstr ":18789"
```

Healthy sign:

- one `LISTENING` row for the gateway
- one `ESTABLISHED` local connection from `AtomicBot.exe` or another local client

If the backend is healthy but the UI still says "gateway down", fully close and reopen Atomic Bot once.

## Step 5: Memory Stack Checks

Do not assume memory is fine just because chat is back.

Check:

- reranker health endpoint returns `status: ok`
- reranker container is healthy
- Qdrant container is up
- `memory-rerank.json` still points at the local reranker endpoint
- any upgrade-fragile OpenClaw patch still exists if memory reranking is expected

If the app was updated, re-check the patched runtime files before claiming reranking still works.

## Step 6: Resume the Work Safely

Before resuming:

1. state what failed
2. state what was restored
3. state the proof
4. state the next exact task

Use the truth labels from `AGENTS.md`:

- `planned`
- `implemented`
- `verified`
- `pushed`

Do not upgrade a claim without evidence.

## Step 7: Leave a Recovery Checkpoint

Write a short checkpoint to the relevant memory file or work artifact that includes:

- failure mode
- fix applied
- proof of health
- what remains pending

Recovery is not complete until there is a written checkpoint.

## Things Not To Do

- Do not rely on chat recap as the source of truth.
- Do not say "it's probably fine" without a health check.
- Do not re-enable heartbeat during recovery.
- Do not paste secrets into notes, markdown, commits, or messages.
- Do not claim implementation progress that only exists as a plan.
