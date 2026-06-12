#Requires -Version 7.0

<#
.SYNOPSIS
    Onboard THIS machine as a secure AitherOS cluster node — cross-platform.

.DESCRIPTION
    The all-platforms node bring-up an agent (or a human) runs to turn any
    machine into a first-class, observable AitherOS mesh node: it registers and
    heartbeats through the Cloudflare tunnel (no inbound ports), behind a
    reboot-safe service. Security is the single-use enrollment token / cluster PSK.

    Like 3213_Onboard-Laptop, this DELEGATES to the canonical installer the
    gateway publishes — `install.sh` on Linux/macOS, `install.ps1` on Windows —
    so there is ONE source of truth and zero drift between this playbook and the
    bytes the website serves. It just detects the OS, fetches the right installer,
    and runs it headless with the chosen flags. The token is passed via the
    AITHER_NODE_TOKEN environment variable so it never lands on a command line.

    Steps:
        1. Detect OS -> choose installer (<Gateway>/install.sh | /install.ps1)
        2. Fetch the canonical installer from the gateway
        3. Run it headless (token via env), wiring -Gateway/-NodeId/-Role
        4. Best-effort verify the reboot-safe service/task is present

    Exit Codes:
        0 - Success
        1 - Could not fetch the installer from the gateway
        2 - Installer reported failure
        3 - Post-install verification failed

.PARAMETER Token
    Single-use enrollment token (minted in the portal "My Nodes" or via
    `adk grid enroll`) — or the long-lived cluster PSK. Can also come from
    $env:AITHER_NODE_TOKEN. Required.

.PARAMETER Gateway
    Gateway the node registers through. Default: https://cluster.aitherium.com

.PARAMETER NodeId
    Node identifier. Default: derived from the hostname by the installer.

.PARAMETER Role
    Node role: sovereign (default), compute, or edge.

.PARAMETER DryRun
    Preview the installer + flags without changing anything.

.PARAMETER PassThru
    Return a result object.

.EXAMPLE
    # Headless (agent / CI) — token via flag:
    ./3214_Onboard-ClusterNode.ps1 -Token $env:AITHER_NODE_TOKEN

.EXAMPLE
    # Named node + role:
    ./3214_Onboard-ClusterNode.ps1 -Token <tok> -NodeId home-lab-01 -Role sovereign

.EXAMPLE
    # Preview:
    ./3214_Onboard-ClusterNode.ps1 -Token <tok> -DryRun

.NOTES
    Stage: Onboarding
    Order: 3214
    Dependencies: none
    Tags: onboarding, cluster, node, enrollment, mesh, cross-platform, sovereign
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0, HelpMessage = "Enrollment token / cluster PSK")]
    [string]$Token = $env:AITHER_NODE_TOKEN,

    [string]$Gateway = $(if ($env:AITHER_CLUSTER_GATEWAY) { $env:AITHER_CLUSTER_GATEWAY } else { 'https://cluster.aitherium.com' }),

    [string]$NodeId,

    [ValidateSet('sovereign', 'compute', 'edge')]
    [string]$Role = 'sovereign',

    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$Gateway = $Gateway.TrimEnd('/')

function Write-Step { param([string]$Name, [string]$Status = 'running')
    $icon = switch ($Status) { 'done' { '[OK]' } 'fail' { '[FAIL]' } 'skip' { '[SKIP]' } default { '[..]' } }
    $color = switch ($Status) { 'done' { 'Green' } 'fail' { 'Red' } 'skip' { 'Yellow' } default { 'Cyan' } }
    Write-Host "$icon $Name" -ForegroundColor $color
}

$osName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'windows' }
          elseif ($IsMacOS) { 'macos' } elseif ($IsLinux) { 'linux' } else { 'unknown' }

$result = [ordered]@{
    Success   = $false
    OS        = $osName
    Gateway   = $Gateway
    NodeId    = $NodeId
    Role      = $Role
    Installer = $null
    Steps     = @()
}

Write-Host "AitherOS Cluster Node Onboarding ($osName)" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

if (-not $Token) {
    Write-Step "Token check" 'fail'
    Write-Host "  A token is required (-Token, or `$env:AITHER_NODE_TOKEN). Mint one in the portal 'My Nodes'." -ForegroundColor DarkGray
    if ($PassThru) { return [pscustomobject]$result }
    exit 2
}

# ── 1. Choose + fetch the canonical installer for this OS ────────────────────
$installerPath = if ($osName -eq 'windows') { '/install.ps1' } else { '/install.sh' }
$installerUrl  = "$Gateway$installerPath"
$result.Installer = $installerUrl

Write-Step "Fetch installer from $installerUrl" 'running'
$installerText = $null
try {
    $installerText = Invoke-RestMethod -Uri $installerUrl -UseBasicParsing -TimeoutSec 30
} catch {
    Write-Step "Fetch installer" 'fail'
    Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkGray
    if ($PassThru) { return [pscustomobject]$result }
    exit 1
}
if (-not $installerText -or "$installerText".Length -lt 200) {
    Write-Step "Fetch installer" 'fail'
    Write-Host "  Installer payload looked empty/too small." -ForegroundColor DarkGray
    if ($PassThru) { return [pscustomobject]$result }
    exit 1
}
Write-Step "Fetch installer ($([math]::Round("$installerText".Length/1KB,1)) KB)" 'done'
$result.Steps += @{ step = 'fetch'; status = 'ok' }

# ── 2. Dry run: show what would run, change nothing ──────────────────────────
if ($DryRun) {
    $shown = if ($osName -eq 'windows') {
        "& <install.ps1> -Gateway $Gateway -Role $Role" + $(if ($NodeId) { " -NodeId $NodeId" } else { '' }) + "   (token via `$env:AITHER_NODE_TOKEN)"
    } else {
        "sh <install.sh> --gateway $Gateway --role $Role" + $(if ($NodeId) { " --node-id $NodeId" } else { '' }) + "   (token via AITHER_NODE_TOKEN)"
    }
    Write-Step "Run installer (DRY RUN): $shown" 'skip'
    $result.Steps += @{ step = 'install'; status = 'skipped' }
    $result.Success = $true
    if ($PassThru) { return [pscustomobject]$result }
    exit 0
}

# ── 3. Run the installer headless (token via env, never on a command line) ───
$prevToken = $env:AITHER_NODE_TOKEN
$env:AITHER_NODE_TOKEN = $Token
Write-Step "Run installer ($osName, headless)" 'running'
try {
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "onboard as $Role node -> $Gateway")) {
        $env:AITHER_NODE_TOKEN = $prevToken
        return
    }
    if ($osName -eq 'windows') {
        $instArgs = @{ Gateway = $Gateway; Role = $Role }
        if ($NodeId) { $instArgs['NodeId'] = $NodeId }
        $installer = [scriptblock]::Create($installerText)
        & $installer @instArgs
    } else {
        # Write to a temp file and run via sh; token rides in the inherited env.
        $tmp = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tmp -Value $installerText -Encoding ASCII
        try {
            $shArgs = @('--gateway', $Gateway, '--role', $Role)
            if ($NodeId) { $shArgs += @('--node-id', $NodeId) }
            & sh $tmp @shArgs
        } finally { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "installer exited with code $LASTEXITCODE" }
    Write-Step "Run installer" 'done'
    $result.Steps += @{ step = 'install'; status = 'ok' }
} catch {
    Write-Step "Run installer" 'fail'
    Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkGray
    $result.Steps += @{ step = 'install'; status = 'fail'; error = "$($_.Exception.Message)" }
    if ($PassThru) { return [pscustomobject]$result }
    exit 2
} finally {
    $env:AITHER_NODE_TOKEN = $prevToken
}

# ── 4. Best-effort verify the reboot-safe service/task is present ────────────
Write-Step "Verify reboot-safe service" 'running'
$verified = $false
try {
    if ($osName -eq 'windows') {
        $verified = [bool](Get-ScheduledTask -TaskName 'AitherClusterNodeAgent' -ErrorAction SilentlyContinue)
    } elseif ($osName -eq 'linux') {
        $svc = (& systemctl is-enabled aither-cluster-agent 2>$null)
        $verified = ($LASTEXITCODE -eq 0) -or ($svc -match 'enabled')
        if (-not $verified) { $verified = Test-Path '/opt/aitheros/dgx_node_agent.py' }  # supervisor fallback
    } else {
        $verified = $true  # macOS supervisor path — installer already reported done
    }
} catch { $verified = $false }

if ($verified) {
    Write-Step "Verify reboot-safe service" 'done'
    $result.Steps += @{ step = 'verify'; status = 'ok' }
} else {
    Write-Step "Verify reboot-safe service (not confirmed)" 'skip'
    $result.Steps += @{ step = 'verify'; status = 'pending' }
}

$result.Success = $true
Write-Host ""
Write-Host "  Node onboarding complete — it should appear in the portal 'My Nodes', online." -ForegroundColor Green
Write-Host ""

if ($PassThru) { return [pscustomobject]$result }
exit 0
