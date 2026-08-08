#Requires -Version 7.0

<#
.SYNOPSIS
    Start ComfyUI bound to the node's tailnet/LAN interface, with a proven-reachable /system_stats.

.DESCRIPTION
    Launch ComfyUI so a self-hosted subscriber's Canvas jobs can reach it. The Canvas image-generation
    router health-checks each registered node with GET /system_stats on a 3s timeout and routes the job
    there only if it answers — so this script's job is not merely "did the process start" but "can a
    peer reach /system_stats at the address we will advertise".

    BIND SCOPE: defaults to the node's tailnet IP (100.64.0.0/10) so ONLY mesh peers reach it — a
    private-bind discipline that keeps the unauthenticated ComfyUI API restricted to trusted network
    only. ComfyUI's API is UNAUTHENTICATED; binding it to 0.0.0.0 exposes tensor execution to anyone
    who can reach the port. Refuses a public bind unless -AllowPublicBind is explicitly passed (and even then warns).

    IDEMPOTENT: detects an already-listening ComfyUI on the port and reuses it (re-run to reconcile a
    crashed process). --Stop tears it down.

    Exit codes: 0 started+reachable | 1 start failed | 2 reachability unproven (listening check timed
                out) | 3 refused public bind | 5 param invalid | 10 install/venv missing (run 3250).

.PARAMETER InstallRoot
    ComfyUI install dir (from 3250). Default: $HOME\ComfyUI.

.PARAMETER ListenHost
    Address to bind. Default: auto-detect the tailnet IP (100.64.*), else the LAN IP (192.168.*).
    MUST be private unless -AllowPublicBind.

.PARAMETER Port
    Listen port. Default: 8188 (ComfyUI default; matches the resolver's nodeComfyUrl fallback).

.PARAMETER AllowPublicBind
    Permit a non-private ListenHost. Off by default; ComfyUI's API is unauthenticated.

.PARAMETER Stop
    Stop a ComfyUI started by this script (by port).

.PARAMETER DryRun
    Plan mode: show what would change, start nothing.

.EXAMPLE
    ./3252_Start-ComfyUI.ps1
.EXAMPLE
    ./3252_Start-ComfyUI.ps1 -ListenHost 100.64.0.9 -Port 8188

.NOTES
    Stage: Onboarding | Order: 3252 | Platform: Windows/pwsh
    Tags: comfyui, image-gen, self-host, tailnet, canvas
    Advertise the SAME (ListenHost, Port) to 3253_Register-ImageBackend — the Canvas router builds
    http://<address>:<port> (or reads metadata.comfyui_url) and must reach exactly this listener.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallRoot = (Join-Path $HOME 'ComfyUI'),
    [string]$ListenHost,
    [int]$Port = 8188,
    [switch]$AllowPublicBind,
    [switch]$Stop,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Log($m, $c = 'Cyan') { Write-Host ("[3252] " + $m) -ForegroundColor $c }
function LogSuccess($m) { Log $m 'Green' }
function LogWarn($m) { Log $m 'Yellow' }
function LogError($m) { Log $m 'Red' }
function LogSkip($m) { Log $m 'DarkGray' }

$IsWin = $IsWindows -or ($env:OS -eq 'Windows_NT')
$VenvPython = if ($IsWin) { Join-Path $InstallRoot '.venv\Scripts\python.exe' } else { Join-Path $InstallRoot '.venv/bin/python' }
$MainPy = Join-Path $InstallRoot 'main.py'

function Test-Private($addr) {
    return ($addr -match '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)')
}

function Resolve-ListenHost {
    if ($ListenHost) { return $ListenHost }
    $addrs = ([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' }).IPAddressToString
    $tailnet = $addrs | Where-Object { $_ -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' } | Select-Object -First 1
    if ($tailnet) { return $tailnet }
    $lan = $addrs | Where-Object { $_ -match '^192\.168\.' } | Select-Object -First 1
    if ($lan) { LogWarn "no tailnet IP found; binding LAN $lan (mesh peers off-LAN will not reach it)"; return $lan }
    LogWarn "no tailnet/LAN IP found; binding 127.0.0.1 (only this host reaches it)"
    return '127.0.0.1'
}

# Is something already listening on the port?
function Test-Listening($addr, $p) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($addr, $p, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(3000, $false)
        if ($ok -and $c.Connected) { $c.EndConnect($iar); $c.Close(); return $true }
        $c.Close(); return $false
    } catch { return $false }
}

# Does /system_stats actually answer? (the resolver's real health check)
function Test-SystemStats($addr, $p) {
    try {
        $r = Invoke-WebRequest -Uri "http://${addr}:${p}/system_stats" -TimeoutSec 5 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

if ($DryRun) { Log 'DRY RUN — nothing will be started/stopped' 'Magenta' }

if (-not (Test-Path $MainPy) -or -not (Test-Path $VenvPython)) {
    LogError "ComfyUI not installed at $InstallRoot (main.py or venv missing) — run 3250_Install-ComfyUI first"
    exit 10
}

$addr = Resolve-ListenHost

if ($Stop) {
    Log "stopping ComfyUI on port $Port"
    if (-not $DryRun) {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'ComfyUI' -and $_.CommandLine -match "--port\s+$Port" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Log "stopped PID $($_.ProcessId)" }
    }
    LogSuccess "stop requested"
    exit 0
}

if (-not (Test-Private $addr) -and -not $AllowPublicBind) {
    LogError "ListenHost '$addr' is not private and -AllowPublicBind was not given."
    LogError "ComfyUI's API is UNAUTHENTICATED — a public bind exposes tensor execution to the internet."
    exit 3
}
if (-not (Test-Private $addr)) { LogWarn "binding PUBLIC address $addr — the ComfyUI API is unauthenticated. You accept this risk." }

# Already up?
if (Test-Listening $addr $Port) {
    if (Test-SystemStats $addr $Port) { LogSuccess "ComfyUI already serving at http://${addr}:${Port} (/system_stats OK)"; exit 0 }
    LogWarn "something is listening on ${addr}:${Port} but /system_stats did not answer — not restarting it blindly"
    exit 2
}

Log "starting ComfyUI: $VenvPython main.py --listen $addr --port $Port"
if ($DryRun) { LogSuccess 'DRY RUN complete — start plan is valid'; exit 0 }

try {
    Start-Process -FilePath $VenvPython `
        -ArgumentList @('main.py', '--listen', $addr, '--port', "$Port") `
        -WorkingDirectory $InstallRoot -WindowStyle Hidden -PassThru | Out-Null
} catch { LogError "failed to launch ComfyUI: $_"; exit 1 }

# Poll /system_stats — cold start loads torch/CUDA, can take 20–40s.
Log "waiting for /system_stats (cold start loads CUDA; up to 60s)..."
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    if (Test-SystemStats $addr $Port) {
        LogSuccess "ComfyUI serving at http://${addr}:${Port} (/system_stats OK)"
        Log "next: 3253_Register-ImageBackend -Address $addr -Port $Port"
        exit 0
    }
    Start-Sleep -Seconds 3
}
LogError "ComfyUI did not answer /system_stats within 60s — start likely failed (check the ComfyUI console/log)."
exit 2
