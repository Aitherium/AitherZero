#Requires -Version 7.0

<#
.SYNOPSIS
    Deploy AitherNode to a remote host with hot-failover configuration.

.DESCRIPTION
    Deploys or updates an AitherNode on a previously bootstrapped remote host.
    Unlike 3100_Setup-HyperVHost (which does full OS-level setup), this script
    handles the application-layer deployment:

    1. Copy/update docker-compose.node.yml and .env to the remote
    2. Pull latest container images
    3. Start/restart AitherNode services
    4. Register with AitherMesh for failover
    5. Configure failover priority and service replication

    Supports rolling updates with zero-downtime when multiple nodes are in the mesh.

    Exit Codes:
        0 - Success
        1 - Connection failure
        2 - Deploy failure
        3 - Health check failure

.PARAMETER ComputerName
    Target hostname or IP. REQUIRED.

.PARAMETER Credential
    PSCredential for auth. Prompts if not provided.

.PARAMETER UseSSH
    Use SSH transport.

.PARAMETER Profile
    Service profile: minimal, core, gpu, dashboard, mesh. Default: core.

.PARAMETER Rolling
    Perform a rolling update (drain → update → rejoin) for zero downtime.

.PARAMETER FailoverPriority
    Priority for this node in failover (1=highest). Default: 10.

.PARAMETER ReplicateServices
    Services to replicate to this node for hot failover. Default: @("Pulse","Chronicle","Strata").

.PARAMETER CoreUrl
    AitherOS Core URL for mesh registration.

.PARAMETER MeshToken
    Mesh authentication token.

.PARAMETER DryRun
    Preview only.

.PARAMETER PassThru
    Return result object.

.NOTES
    Stage: Remote-Deploy
    Order: 3101
    Dependencies: 3100
    Tags: remote, deploy, failover, mesh, node
    AllowParallel: true
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName,

    [PSCredential]$Credential,
    [switch]$UseSSH,

    [ValidateSet("minimal", "core", "gpu", "dashboard", "mesh", "all")]
    [string]$Profile = "core",

    [switch]$Rolling,

    [ValidateRange(1, 100)]
    [int]$FailoverPriority = 10,

    [string[]]$ReplicateServices = @("Pulse", "Chronicle", "Strata"),

    [string]$CoreUrl,
    [string]$MeshToken,

    [switch]$DryRun,
    [switch]$Force,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ═══════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════

function Write-Step {
    param([string]$Phase, [string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "SKIP"  { "DarkGray" }
        default { "Cyan" }
    }
    $icon = switch ($Status) {
        "OK"    { "✓" }
        "WARN"  { "⚠" }
        "ERROR" { "✗" }
        "SKIP"  { "→" }
        default { "●" }
    }
    Write-Host "  [$Phase] $icon $Message" -ForegroundColor $color
}

# ═══════════════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     AitherNode Remote Deploy (3101)                ║" -ForegroundColor Cyan
Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Target:  $ComputerName | Profile: $Profile | Priority: $FailoverPriority"
Write-Host ""

if ($DryRun) {
    Write-Host "  [DRY RUN] Would deploy AitherNode to $ComputerName" -ForegroundColor Yellow
    Write-Host "    Profile: $Profile" -ForegroundColor DarkGray
    Write-Host "    Failover priority: $FailoverPriority" -ForegroundColor DarkGray
    Write-Host "    Replicated services: $($ReplicateServices -join ', ')" -ForegroundColor DarkGray
    Write-Host "    Rolling update: $Rolling" -ForegroundColor DarkGray
    if ($PassThru) { return [PSCustomObject]@{ Status = 'DryRun'; ComputerName = $ComputerName } }
    return
}

# ═══════════════════════════════════════════════════════════════════════
# CONNECT
# ═══════════════════════════════════════════════════════════════════════

if (-not $Credential) {
    $Credential = Get-Credential -Message "Credentials for $ComputerName"
}

$sessionParams = @{ ComputerName = $ComputerName; Credential = $Credential }
if ($UseSSH) { $sessionParams.SSHTransport = $true }

try {
    $session = New-PSSession @sessionParams
    Write-Step "CONNECT" "Session established" "OK"
}
catch {
    Write-Step "CONNECT" "Failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════
# ROLLING UPDATE: DRAIN IF REQUESTED
# ═══════════════════════════════════════════════════════════════════════

if ($Rolling) {
    Write-Step "DRAIN" "Draining node from mesh before update..."
    try {
        $drainUrl = "http://${ComputerName}:8125/mesh/drain"
        Invoke-RestMethod -Uri $drainUrl -Method POST -TimeoutSec 10 -ErrorAction SilentlyContinue
        Write-Step "DRAIN" "Node drained — traffic rerouted" "OK"
        Start-Sleep -Seconds 5  # Let in-flight requests complete
    }
    catch {
        Write-Step "DRAIN" "Drain skipped (node may not be in mesh yet)" "SKIP"
    }
}

# ═══════════════════════════════════════════════════════════════════════
# DEPLOY
# ═══════════════════════════════════════════════════════════════════════

Write-Step "DEPLOY" "Updating AitherNode on $ComputerName..."

$remoteDeployDir = "C:\AitherOS"

# Copy compose file
$composeSource = Join-Path $PSScriptRoot ".." ".." ".." ".." "docker-compose.node.yml"
if (-not (Test-Path $composeSource)) {
    $composeSource = Join-Path $PSScriptRoot ".." ".." ".." "docker-compose.node.yml"
}
if (Test-Path $composeSource) {
    Invoke-Command -Session $session -ScriptBlock {
        param($dir)
        if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    } -ArgumentList $remoteDeployDir
    Copy-Item -Path $composeSource -Destination "$remoteDeployDir\docker-compose.node.yml" -ToSession $session -Force
    Write-Step "DEPLOY" "Compose file synced" "OK"
}

# Update .env with failover config
Invoke-Command -Session $session -ScriptBlock {
    param($deployDir, $coreUrl, $token, $priority, $replicateServices, $profile)

    $envPath = Join-Path $deployDir ".env"
    $env = @{}
    if (Test-Path $envPath) {
        Get-Content $envPath | Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } | ForEach-Object {
            $k, $v = $_ -split '=', 2
            $env[$k.Trim()] = $v.Trim()
        }
    }

    # Update/add failover settings
    if ($coreUrl)  { $env['AITHER_CORE_URL'] = $coreUrl }
    if ($token)    { $env['AITHER_NODE_TOKEN'] = $token }
    $env['AITHER_MESH_ENABLED'] = 'true'
    $env['AITHER_DOCKER_MODE'] = 'true'
    $env['AITHER_FAILOVER_PRIORITY'] = $priority.ToString()
    $env['AITHER_REPLICATE_SERVICES'] = ($replicateServices -join ',')
    $env['AITHER_NODE_PROFILE'] = $profile
    $env['COMPOSE_PROJECT_NAME'] = 'aithernode'

    $envContent = ($env.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
    Set-Content -Path $envPath -Value $envContent -Force
} -ArgumentList $remoteDeployDir, $CoreUrl, $MeshToken, $FailoverPriority, $ReplicateServices, $Profile

# Pull and restart
$deployOutput = Invoke-Command -Session $session -ScriptBlock {
    param($deployDir, $profile)

    Set-Location $deployDir
    $profiles = @("--profile", "mesh")
    if ($profile -eq "gpu" -or $profile -eq "all") { $profiles += @("--profile", "gpu") }
    if ($profile -eq "dashboard" -or $profile -eq "all") { $profiles += @("--profile", "dashboard") }

    $baseArgs = @("-f", "docker-compose.node.yml") + $profiles

    # Pull latest
    & docker compose @baseArgs pull 2>&1 | Select-Object -Last 3

    # Recreate with latest images
    & docker compose @baseArgs up -d --remove-orphans 2>&1 | Select-Object -Last 5

    Start-Sleep -Seconds 10

    # Status
    & docker compose @baseArgs ps --format "table {{.Name}}\t{{.Status}}" 2>&1
} -ArgumentList $remoteDeployDir, $Profile

$deployOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
Write-Step "DEPLOY" "Containers updated" "OK"

# ═══════════════════════════════════════════════════════════════════════
# HEALTH CHECK
# ═══════════════════════════════════════════════════════════════════════

Write-Step "HEALTH" "Running health checks..."
Start-Sleep -Seconds 5

$healthResults = @(
    @{ Name = "Genesis"; Port = 8001; Path = "/health" },
    @{ Name = "Pulse";   Port = 8081; Path = "/health" },
    @{ Name = "Watch";   Port = 8082; Path = "/health" },
    @{ Name = "Mesh";    Port = 8125; Path = "/health" }
) | ForEach-Object {
    $url = "http://${ComputerName}:$($_.Port)$($_.Path)"
    try {
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 5 -ErrorAction Stop
        [PSCustomObject]@{ Service = $_.Name; Port = $_.Port; Status = "Healthy"; Detail = ($r.status ?? "ok") }
    }
    catch {
        [PSCustomObject]@{ Service = $_.Name; Port = $_.Port; Status = "Unhealthy"; Detail = $_.Exception.Message.Substring(0, [Math]::Min(60, $_.Exception.Message.Length)) }
    }
}

$healthResults | ForEach-Object {
    $s = if ($_.Status -eq "Healthy") { "OK" } else { "WARN" }
    Write-Step "HEALTH" "$($_.Service):$($_.Port) — $($_.Status)" $s
}

# ═══════════════════════════════════════════════════════════════════════
# MESH REJOIN (after rolling update)
# ═══════════════════════════════════════════════════════════════════════

if ($Rolling) {
    Write-Step "REJOIN" "Rejoining mesh after update..."
    try {
        $rejoinUrl = "http://${ComputerName}:8125/mesh/rejoin"
        Invoke-RestMethod -Uri $rejoinUrl -Method POST -TimeoutSec 10 -ErrorAction SilentlyContinue
        Write-Step "REJOIN" "Node active in mesh" "OK"
    }
    catch {
        Write-Step "REJOIN" "Auto-rejoin will happen via heartbeat" "WARN"
    }
}

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════

Remove-PSSession $session -ErrorAction SilentlyContinue

$healthy = ($healthResults | Where-Object { $_.Status -eq "Healthy" }).Count
$total = $healthResults.Count
$statusMsg = if ($healthy -eq $total) { "All services healthy" } else { "$healthy/$total healthy" }

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║       AitherNode Deploy Complete                   ║" -ForegroundColor Green
Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "  $ComputerName — $statusMsg — Priority $FailoverPriority" -ForegroundColor White
Write-Host ""

if ($PassThru) {
    return [PSCustomObject]@{
        PSTypeName       = 'AitherOS.NodeDeployResult'
        Status           = if ($healthy -eq $total) { 'Success' } else { 'PartialFailure' }
        ComputerName     = $ComputerName
        Profile          = $Profile
        FailoverPriority = $FailoverPriority
        HealthResults    = $healthResults
        HealthySvcs      = $healthy
        TotalSvcs        = $total
        Timestamp        = Get-Date
    }
}
