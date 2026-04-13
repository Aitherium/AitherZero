#Requires -Version 7.0

<#
.SYNOPSIS
    Mesh failover watchdog — monitors node health and triggers automatic service failover.

.DESCRIPTION
    Continuously monitors the health of all nodes in the AitherMesh and triggers
    automatic failover when a node becomes unreachable. This is the LAN hot-failover
    brain that:

    1. Polls all registered mesh nodes at configurable intervals
    2. Tracks consecutive failures per node (configurable threshold)
    3. On failover trigger: promotes the highest-priority standby node
    4. Notifies the mesh of topology changes
    5. Handles node recovery and automatic failback (if configured)

    Can run as a background watchdog or one-shot health check.

    Exit Codes:
        0 - Success / All nodes healthy
        1 - Failover triggered (node down)
        2 - Configuration error
        3 - Mesh communication failure

.PARAMETER CoreUrl
    URL of the AitherOS Core instance. Default: http://localhost:8001

.PARAMETER MeshPort
    MeshCore port. Default: 8125

.PARAMETER PollIntervalSeconds
    Health check interval. Default: 15

.PARAMETER FailureThreshold
    Consecutive failures before failover. Default: 3

.PARAMETER Continuous
    Run as a continuous watchdog (background loop). If not set, runs once.

.PARAMETER EnableFailback
    Automatically restore original node when it recovers.

.PARAMETER DryRun
    Show what failover would do without executing.

.PARAMETER PassThru
    Return node status objects.

.NOTES
    Stage: Monitoring
    Order: 3102
    Dependencies: 3100, 3101
    Tags: failover, mesh, watchdog, ha, monitoring
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CoreUrl = "http://localhost:8001",
    [int]$MeshPort = 8125,
    [int]$PollIntervalSeconds = 15,
    [int]$FailureThreshold = 3,
    [switch]$Continuous,
    [switch]$EnableFailback,
    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ═══════════════════════════════════════════════════════════════════════
# STATE
# ═══════════════════════════════════════════════════════════════════════

$script:nodeFailureCounts = @{}
$script:failedOverNodes = @{}
$script:meshBaseUrl = $CoreUrl -replace ':\d+$', ":$MeshPort"

function Write-Watchdog {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "FAIL"  { "Magenta" }
        default { "Cyan" }
    }
    $icon = switch ($Level) {
        "OK"    { "✓" }
        "WARN"  { "⚠" }
        "ERROR" { "✗" }
        "FAIL"  { "⬤" }
        default { "●" }
    }
    Write-Host "  [$ts] $icon $Message" -ForegroundColor $color
}

function Get-MeshNodes {
    try {
        $response = Invoke-RestMethod -Uri "$script:meshBaseUrl/mesh/nodes" -TimeoutSec 5 -ErrorAction Stop
        if ($response.nodes) { return $response.nodes }
        if ($response -is [array]) { return $response }
        return @()
    }
    catch {
        Write-Watchdog "Cannot reach MeshCore at $script:meshBaseUrl — $($_.Exception.Message)" "WARN"
        return @()
    }
}

function Test-NodeHealth {
    param([string]$NodeUrl, [int]$TimeoutSec = 5)
    $endpoints = @("/health", "/mesh/heartbeat")
    foreach ($ep in $endpoints) {
        try {
            $r = Invoke-RestMethod -Uri "${NodeUrl}${ep}" -TimeoutSec $TimeoutSec -ErrorAction Stop
            return @{ Healthy = $true; Latency = 0; Detail = ($r.status ?? "ok") }
        }
        catch { continue }
    }
    return @{ Healthy = $false; Latency = -1; Detail = "All health endpoints unreachable" }
}

function Invoke-Failover {
    param([object]$DownNode, [object[]]$StandbyNodes)

    $target = $StandbyNodes | Sort-Object { 
        [int]($_.failover_priority ?? $_.priority ?? 99) 
    } | Select-Object -First 1

    if (-not $target) {
        Write-Watchdog "NO STANDBY NODES AVAILABLE for failover!" "ERROR"
        return $false
    }

    $nodeId = $DownNode.node_id ?? $DownNode.id ?? "unknown"
    $targetId = $target.node_id ?? $target.id ?? "unknown"

    Write-Watchdog "FAILOVER: $nodeId → promoting $targetId (priority: $($target.failover_priority ?? $target.priority ?? '?'))" "FAIL"

    if ($DryRun) {
        Write-Watchdog "[DRY RUN] Would promote $targetId and migrate services from $nodeId" "WARN"
        return $true
    }

    try {
        # Notify mesh of topology change
        $promotePayload = @{
            action       = "failover"
            failed_node  = $nodeId
            promote_node = $targetId
            timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        } | ConvertTo-Json

        Invoke-RestMethod -Uri "$script:meshBaseUrl/mesh/topology/update" -Method POST `
            -Body $promotePayload -ContentType "application/json" -TimeoutSec 10 -ErrorAction SilentlyContinue

        # Attempt to promote the standby node's role
        $targetUrl = $target.node_url ?? $target.url ?? "http://$targetId"
        try {
            Invoke-RestMethod -Uri "${targetUrl}/mesh/promote" -Method POST `
                -Body (@{ role = "primary"; reason = "failover_from_$nodeId" } | ConvertTo-Json) `
                -ContentType "application/json" -TimeoutSec 10 -ErrorAction SilentlyContinue
        }
        catch {
            Write-Watchdog "Promote call to $targetId returned error (may already be handling)" "WARN"
        }

        $script:failedOverNodes[$nodeId] = @{
            FailedAt     = Get-Date
            PromotedNode = $targetId
            OriginalRole = $DownNode.role ?? "compute"
        }

        Write-Watchdog "Failover complete: $targetId is now handling traffic" "OK"
        return $true
    }
    catch {
        Write-Watchdog "Failover execution failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Invoke-Failback {
    param([string]$NodeId, [object]$RecoveredNode)

    $failoverInfo = $script:failedOverNodes[$NodeId]
    if (-not $failoverInfo) { return }

    Write-Watchdog "FAILBACK: $NodeId recovered — restoring original role" "OK"

    if ($DryRun) {
        Write-Watchdog "[DRY RUN] Would restore $NodeId and demote $($failoverInfo.PromotedNode)" "WARN"
        $script:failedOverNodes.Remove($NodeId)
        return
    }

    try {
        $nodeUrl = $RecoveredNode.node_url ?? $RecoveredNode.url
        if ($nodeUrl) {
            Invoke-RestMethod -Uri "${nodeUrl}/mesh/rejoin" -Method POST `
                -Body (@{ role = $failoverInfo.OriginalRole; reason = "failback" } | ConvertTo-Json) `
                -ContentType "application/json" -TimeoutSec 10 -ErrorAction SilentlyContinue
        }

        $script:failedOverNodes.Remove($NodeId)
        Write-Watchdog "Failback complete for $NodeId" "OK"
    }
    catch {
        Write-Watchdog "Failback error: $($_.Exception.Message)" "WARN"
    }
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     AitherMesh Failover Watchdog (3102)            ║" -ForegroundColor Cyan
Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Core: $CoreUrl | Mesh: $script:meshBaseUrl" -ForegroundColor DarkGray
Write-Host "  Poll: ${PollIntervalSeconds}s | Threshold: $FailureThreshold failures" -ForegroundColor DarkGray
Write-Host "  Mode: $(if ($Continuous) { 'Continuous' } else { 'One-shot' }) | Failback: $EnableFailback" -ForegroundColor DarkGray
Write-Host ""

$allResults = @()

do {
    $nodes = Get-MeshNodes

    if ($nodes.Count -eq 0) {
        Write-Watchdog "No nodes registered in mesh" "WARN"
        if (-not $Continuous) { break }
        Start-Sleep -Seconds $PollIntervalSeconds
        continue
    }

    foreach ($node in $nodes) {
        $nodeId = $node.node_id ?? $node.id ?? "unknown"
        $nodeUrl = $node.node_url ?? $node.url

        if (-not $nodeUrl) {
            Write-Watchdog "Node $nodeId has no URL, skipping" "WARN"
            continue
        }

        $health = Test-NodeHealth -NodeUrl $nodeUrl
        $nodeResult = [PSCustomObject]@{
            NodeId     = $nodeId
            NodeUrl    = $nodeUrl
            Healthy    = $health.Healthy
            Detail     = $health.Detail
            Failures   = 0
            Timestamp  = Get-Date
        }

        if ($health.Healthy) {
            # Reset failure counter
            $script:nodeFailureCounts[$nodeId] = 0
            $nodeResult.Failures = 0

            # Check for failback
            if ($EnableFailback -and $script:failedOverNodes.ContainsKey($nodeId)) {
                Invoke-Failback -NodeId $nodeId -RecoveredNode $node
            }

            Write-Watchdog "$nodeId — healthy" "OK"
        }
        else {
            # Increment failure counter
            if (-not $script:nodeFailureCounts.ContainsKey($nodeId)) {
                $script:nodeFailureCounts[$nodeId] = 0
            }
            $script:nodeFailureCounts[$nodeId]++
            $failures = $script:nodeFailureCounts[$nodeId]
            $nodeResult.Failures = $failures

            if ($failures -ge $FailureThreshold) {
                if (-not $script:failedOverNodes.ContainsKey($nodeId)) {
                    Write-Watchdog "$nodeId — UNREACHABLE ($failures/$FailureThreshold) — TRIGGERING FAILOVER" "FAIL"

                    # Get healthy standby nodes
                    $standbyNodes = $nodes | Where-Object {
                        $id = $_.node_id ?? $_.id
                        $id -ne $nodeId -and -not $script:failedOverNodes.ContainsKey($id)
                    } | Where-Object {
                        $url = $_.node_url ?? $_.url
                        $url -and (Test-NodeHealth -NodeUrl $url -TimeoutSec 3).Healthy
                    }

                    Invoke-Failover -DownNode $node -StandbyNodes $standbyNodes
                }
                else {
                    Write-Watchdog "$nodeId — still down (already failed over)" "ERROR"
                }
            }
            else {
                Write-Watchdog "$nodeId — unhealthy ($failures/$FailureThreshold before failover)" "WARN"
            }
        }

        $allResults += $nodeResult
    }

    if ($Continuous) {
        Start-Sleep -Seconds $PollIntervalSeconds
    }

} while ($Continuous)

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY (one-shot mode)
# ═══════════════════════════════════════════════════════════════════════

if (-not $Continuous) {
    $healthy = ($allResults | Where-Object { $_.Healthy }).Count
    $total = $allResults.Count

    Write-Host ""
    if ($healthy -eq $total -and $total -gt 0) {
        Write-Host "  All $total nodes healthy ✓" -ForegroundColor Green
    }
    elseif ($total -eq 0) {
        Write-Host "  No nodes in mesh" -ForegroundColor Yellow
    }
    else {
        Write-Host "  $healthy/$total nodes healthy" -ForegroundColor $(if ($healthy -gt 0) { "Yellow" } else { "Red" })
    }
    Write-Host ""
}

if ($PassThru) {
    return [PSCustomObject]@{
        PSTypeName     = 'AitherOS.FailoverWatchdogResult'
        NodesChecked   = $allResults.Count
        HealthyNodes   = ($allResults | Where-Object { $_.Healthy }).Count
        FailedOver     = $script:failedOverNodes.Keys.Count
        NodeResults    = $allResults
        Timestamp      = Get-Date
    }
}
