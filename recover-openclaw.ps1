[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$ForceGatewayRestart,
    [switch]$NoUiHint
)

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Get-GatewayListenerPid {
    $line = netstat -ano | Select-String ':18789' | Select-String 'LISTENING' | Select-Object -First 1
    if (-not $line) {
        return $null
    }
    return (($line.ToString() -split '\s+')[-1])
}

function Test-GatewayHealth {
    param(
        [string]$NodePath,
        [string]$CliPath,
        [string]$GatewayToken
    )

    try {
        $raw = & $NodePath $CliPath gateway health --json --token $GatewayToken 2>$null
        if (-not $raw) {
            return [pscustomobject]@{ Ok = $false; Raw = $null; Json = $null }
        }

        $json = $raw | ConvertFrom-Json
        return [pscustomobject]@{ Ok = [bool]$json.ok; Raw = $raw; Json = $json }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Raw = $null; Json = $null; Error = $_.Exception.Message }
    }
}

function Test-Reranker {
    try {
        $response = Invoke-RestMethod 'http://127.0.0.1:8780/health' -TimeoutSec 5
        return [pscustomobject]@{
            Ok = ($response.status -eq 'ok')
            Detail = ($response | ConvertTo-Json -Compress)
        }
    }
    catch {
        return [pscustomobject]@{
            Ok = $false
            Detail = $_.Exception.Message
        }
    }
}

function Get-DockerContainerStatus {
    param([string]$Name)

    try {
        $status = docker ps --filter "name=^/$Name$" --format "{{.Status}}" 2>$null
        if ([string]::IsNullOrWhiteSpace($status)) {
            return [pscustomobject]@{ Name = $Name; Running = $false; Status = 'not running' }
        }

        return [pscustomobject]@{ Name = $Name; Running = $true; Status = $status.Trim() }
    }
    catch {
        return [pscustomobject]@{ Name = $Name; Running = $false; Status = $_.Exception.Message }
    }
}

$StateDir = 'C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw'
$Workspace = 'C:\Users\TacIm\AppData\Roaming\atomicbot-desktop\openclaw\workspace'
$ConfigPath = Join-Path $StateDir 'openclaw.json'
$CliPath = 'C:\Users\TacIm\AppData\Local\Programs\atomicbot-desktop\resources\openclaw\openclaw.mjs'
$NodePath = 'C:\Users\TacIm\AppData\Local\Programs\atomicbot-desktop\resources\node\win32-x64\node.exe'
$PidPath = Join-Path $StateDir 'gateway.pid'
$StdoutPath = Join-Path $StateDir 'gateway.stdout.log'
$StderrPath = Join-Path $StateDir 'gateway.stderr.log'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Missing config: $ConfigPath"
}

if (-not (Test-Path -LiteralPath $CliPath)) {
    throw "Missing bundled CLI: $CliPath"
}

if (-not (Test-Path -LiteralPath $NodePath)) {
    throw "Missing bundled Node: $NodePath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$token = $config.gateway.auth.token

if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Gateway token missing in openclaw.json'
}

$env:OPENCLAW_STATE_DIR = $StateDir
$env:OPENCLAW_CONFIG_PATH = $ConfigPath

Write-Section 'Context'
Write-Host "Workspace: $Workspace"
Write-Host "StateDir : $StateDir"
Write-Host "CLI      : $CliPath"
Write-Host "Node     : $NodePath"

$pidFileValue = $null
if (Test-Path -LiteralPath $PidPath) {
    $pidFileValue = (Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1)
}

$listenerPid = Get-GatewayListenerPid
$gatewayHealth = Test-GatewayHealth -NodePath $NodePath -CliPath $CliPath -GatewayToken $token

Write-Section 'Gateway Before Recovery'
Write-Host "Pid file     : $pidFileValue"
Write-Host "Listener pid : $listenerPid"
Write-Host "Health ok    : $($gatewayHealth.Ok)"
if ($gatewayHealth.Raw) {
    Write-Host "Health raw   : $($gatewayHealth.Raw)"
}
elseif ($gatewayHealth.Error) {
    Write-Host "Health error : $($gatewayHealth.Error)"
}

if (-not $gatewayHealth.Ok -and -not $CheckOnly) {
    Write-Section 'Attempting Clean Restart'
    try {
        & $NodePath $CliPath gateway stop --token $token | Out-Host
    }
    catch {
        Write-Host "Stop warning : $($_.Exception.Message)" -ForegroundColor Yellow
    }

    try {
        & $NodePath $CliPath gateway start --token $token | Out-Host
    }
    catch {
        Write-Host "Start warning: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Start-Sleep -Seconds 2
    $listenerPid = Get-GatewayListenerPid
    $gatewayHealth = Test-GatewayHealth -NodePath $NodePath -CliPath $CliPath -GatewayToken $token
}

if (-not $gatewayHealth.Ok -and $ForceGatewayRestart) {
    Write-Section 'Attempting Forced Listener Cleanup'
    $listenerPid = Get-GatewayListenerPid
    if ($listenerPid) {
        Write-Host "Stopping listener pid $listenerPid"
        Stop-Process -Id $listenerPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue

    try {
        & $NodePath $CliPath gateway start --token $token | Out-Host
    }
    catch {
        Write-Host "Forced start warning: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Start-Sleep -Seconds 2
    $listenerPid = Get-GatewayListenerPid
    $gatewayHealth = Test-GatewayHealth -NodePath $NodePath -CliPath $CliPath -GatewayToken $token
}

$reranker = Test-Reranker
$qdrant = Get-DockerContainerStatus -Name 'codee-qdrant-memory'
$rerankerContainer = Get-DockerContainerStatus -Name 'codee-memory-reranker'

Write-Section 'Memory Sidecars'
Write-Host "Reranker health : $($reranker.Ok) [$($reranker.Detail)]"
Write-Host "Reranker docker : $($rerankerContainer.Status)"
Write-Host "Qdrant docker   : $($qdrant.Status)"

Write-Section 'Gateway After Recovery'
Write-Host "Listener pid : $listenerPid"
Write-Host "Health ok    : $($gatewayHealth.Ok)"
if ($gatewayHealth.Raw) {
    Write-Host "Health raw   : $($gatewayHealth.Raw)"
}

if (-not $gatewayHealth.Ok) {
    if (Test-Path -LiteralPath $StderrPath) {
        Write-Host ""
        Write-Host "Recent gateway stderr:" -ForegroundColor Yellow
        Get-Content -LiteralPath $StderrPath -Tail 20
    }

    if (Test-Path -LiteralPath $StdoutPath) {
        Write-Host ""
        Write-Host "Recent gateway stdout:" -ForegroundColor Yellow
        Get-Content -LiteralPath $StdoutPath -Tail 20
    }
}

if (-not $NoUiHint) {
    Write-Section 'UI Hint'
    Write-Host 'If backend health is good but Atomic Bot still says "gateway down", fully close and reopen Atomic Bot once.'
}

if ($gatewayHealth.Ok) {
    Write-Section 'Result'
    Write-Host 'Gateway recovery check passed.' -ForegroundColor Green
    exit 0
}

Write-Section 'Result'
Write-Host 'Gateway recovery check failed.' -ForegroundColor Red
exit 1
