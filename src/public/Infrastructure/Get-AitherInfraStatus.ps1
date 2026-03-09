#Requires -Version 7.0

<#
.SYNOPSIS
    Get a comprehensive infrastructure status overview for the AitherOS ecosystem.

.DESCRIPTION
    Aggregates status from AitherMesh nodes, database replication, container health,
    and service endpoints into a single unified view. This is the "control plane" 
    command for infrastructure operators and the AitherZero agent.

    Checks:
    - AitherMesh topology (via MeshCore:8125)
    - Container health (via Docker)
    - Database replication (PostgreSQL streaming, Redis, Strata sync)
    - Core service endpoints (Genesis, Pulse, Secrets, Chronicle, MicroScheduler)
    - Remote node connectivity (if any registered)

.PARAMETER CoreUrl
    AitherOS Core URL. Default: http://localhost:8001

.PARAMETER IncludeReplication
    Include database replication details (PostgreSQL, Redis, Strata).

.PARAMETER IncludeContainers
    Include per-container health from Docker.

.PARAMETER CheckRemoteNodes
    Ping registered remote nodes for connectivity.

.PARAMETER Format
    Output format: Table (default), Json, Summary.

.PARAMETER PassThru
    Return structured result objects instead of formatted output.

.INPUTS
    None.

.OUTPUTS
    PSCustomObject — Infrastructure status report.

.EXAMPLE
    Get-AitherInfraStatus
    Quick overview of mesh + core services.

.EXAMPLE
    Get-AitherInfraStatus -IncludeReplication -IncludeContainers
    Full infrastructure report with replication and container details.

.EXAMPLE
    Get-AitherInfraStatus -Format Json -PassThru | ConvertTo-Json -Depth 5
    Machine-readable output for dashboards or API responses.

.NOTES
    Part of AitherZero module — Infrastructure category.
#>
function Get-AitherInfraStatus {
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param(
        [string]$CoreUrl = "http://localhost:8001",
        [switch]$IncludeReplication,
        [switch]$IncludeContainers,
        [switch]$CheckRemoteNodes,
        [ValidateSet("Table", "Json", "Summary")]
        [string]$Format = "Table",
        [switch]$PassThru
    )

    $result = [PSCustomObject]@{
        PSTypeName          = 'AitherOS.InfrastructureStatus'
        Timestamp           = Get-Date
        CoreUrl             = $CoreUrl
        MeshStatus          = $null
        CoreServices        = @()
        Containers          = @()
        Replication         = $null
        RemoteNodes         = @()
        OverallHealth       = 'Unknown'
        Summary             = ''
    }

    $healthy = 0
    $total = 0

    # ── 1. Core Service Health Checks ────────────────────────────────
    Write-Host "  Checking core services..." -ForegroundColor Cyan
    $services = @(
        @{ Name = "Genesis";        Port = 8001; Path = "/health" }
        @{ Name = "Pulse";          Port = 8081; Path = "/health" }
        @{ Name = "Watch";          Port = 8082; Path = "/health" }
        @{ Name = "Secrets";        Port = 8111; Path = "/health" }
        @{ Name = "Chronicle";      Port = 8121; Path = "/health" }
        @{ Name = "MeshCore";       Port = 8125; Path = "/health" }
        @{ Name = "Strata";         Port = 8136; Path = "/health" }
        @{ Name = "MicroScheduler"; Port = 8150; Path = "/health" }
        @{ Name = "SecurityCore";   Port = 8117; Path = "/health" }
    )

    foreach ($svc in $services) {
        $total++
        $svcResult = [PSCustomObject]@{
            Name     = $svc.Name
            Port     = $svc.Port
            Status   = 'Offline'
            Latency  = $null
            Details  = ''
        }

        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $resp = Invoke-RestMethod -Uri "http://localhost:$($svc.Port)$($svc.Path)" -TimeoutSec 5 -ErrorAction Stop
            $sw.Stop()
            $svcResult.Status = 'Healthy'
            $svcResult.Latency = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
            $svcResult.Details = if ($resp.status) { $resp.status } elseif ($resp.ok) { 'ok' } else { 'responsive' }
            $healthy++
        }
        catch {
            $svcResult.Status = 'Offline'
            $svcResult.Details = $_.Exception.Message -replace '.*: ', ''
        }

        $result.CoreServices += $svcResult
    }

    # ── 2. AitherMesh Topology ───────────────────────────────────────
    Write-Host "  Checking mesh topology..." -ForegroundColor Cyan
    try {
        $meshNodes = Invoke-RestMethod -Uri "http://localhost:8125/mesh/nodes" -TimeoutSec 5 -ErrorAction Stop
        $nodeList = if ($meshNodes.nodes) { $meshNodes.nodes } else { @($meshNodes) }
        $result.MeshStatus = [PSCustomObject]@{
            Connected = $true
            NodeCount = $nodeList.Count
            Nodes     = $nodeList | ForEach-Object {
                [PSCustomObject]@{
                    NodeId   = $_.node_id ?? $_.id ?? 'unknown'
                    Role     = $_.role ?? 'node'
                    Status   = $_.status ?? 'unknown'
                    Priority = $_.failover_priority ?? $_.priority ?? 99
                    LastSeen = $_.last_heartbeat ?? $_.last_seen ?? ''
                }
            }
        }
    }
    catch {
        $result.MeshStatus = [PSCustomObject]@{
            Connected = $false
            NodeCount = 0
            Nodes     = @()
            Error     = $_.Exception.Message -replace '.*: ', ''
        }
    }

    # ── 3. Container Health (optional) ───────────────────────────────
    if ($IncludeContainers) {
        Write-Host "  Checking containers..." -ForegroundColor Cyan
        try {
            $containers = docker ps --filter "name=aitheros" --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1
            if ($LASTEXITCODE -eq 0 -and $containers) {
                $result.Containers = $containers | ForEach-Object {
                    $parts = $_ -split '\t'
                    [PSCustomObject]@{
                        Name   = $parts[0]
                        Status = $parts[1]
                        Ports  = $parts[2]
                        Health = if ($parts[1] -match 'healthy') { 'Healthy' }
                                 elseif ($parts[1] -match 'Up') { 'Running' }
                                 else { 'Unhealthy' }
                    }
                }
            }
        }
        catch {
            Write-Warning "Docker not available: $($_.Exception.Message)"
        }
    }

    # ── 4. Database Replication Status (optional) ────────────────────
    if ($IncludeReplication) {
        Write-Host "  Checking replication..." -ForegroundColor Cyan
        $repl = [PSCustomObject]@{
            PostgreSQL = $null
            Redis      = $null
            Strata     = $null
        }

        # PostgreSQL — check replication slots
        try {
            $pgCheck = docker exec aitheros-postgres psql -U aitheros -d aitheros -t -c "SELECT slot_name, active FROM pg_replication_slots;" 2>&1
            if ($LASTEXITCODE -eq 0 -and $pgCheck -match '\S') {
                $repl.PostgreSQL = [PSCustomObject]@{
                    Status = 'Active'
                    Slots  = ($pgCheck -split "`n" | Where-Object { $_ -match '\S' }).Count
                    Details = $pgCheck.Trim()
                }
            }
            else {
                $repl.PostgreSQL = [PSCustomObject]@{ Status = 'No slots'; Slots = 0 }
            }
        }
        catch {
            $repl.PostgreSQL = [PSCustomObject]@{ Status = 'Unreachable'; Error = $_.Exception.Message }
        }

        # Redis — check replication info
        try {
            $redisInfo = docker exec aitheros-redis redis-cli info replication 2>&1
            if ($LASTEXITCODE -eq 0) {
                $role = if ($redisInfo -match 'role:(\w+)') { $Matches[1] } else { 'unknown' }
                $connectedSlaves = if ($redisInfo -match 'connected_slaves:(\d+)') { [int]$Matches[1] } else { 0 }
                $repl.Redis = [PSCustomObject]@{
                    Status          = if ($role -eq 'master' -and $connectedSlaves -gt 0) { 'Replicating' }
                                      elseif ($role -eq 'master') { 'Master (no replicas)' }
                                      else { "Replica of $role" }
                    Role            = $role
                    ConnectedSlaves = $connectedSlaves
                }
            }
        }
        catch {
            $repl.Redis = [PSCustomObject]@{ Status = 'Unreachable' }
        }

        # Strata — check sync status
        try {
            $strataSync = Invoke-RestMethod -Uri "http://localhost:8136/api/v1/sync/status" -TimeoutSec 5 -ErrorAction Stop
            $repl.Strata = [PSCustomObject]@{
                Status  = $strataSync.status ?? 'unknown'
                Peers   = $strataSync.peers ?? 0
                Details = $strataSync
            }
        }
        catch {
            $repl.Strata = [PSCustomObject]@{ Status = 'Not configured' }
        }

        $result.Replication = $repl
    }

    # ── 5. Remote Node Connectivity (optional) ───────────────────────
    if ($CheckRemoteNodes) {
        Write-Host "  Pinging remote nodes..." -ForegroundColor Cyan
        $meshNodes = $result.MeshStatus.Nodes | Where-Object {
            $_.NodeId -ne 'local' -and $_.NodeId -ne (hostname)
        }
        foreach ($node in $meshNodes) {
            $nodeHost = $node.NodeId
            $pingResult = [PSCustomObject]@{
                NodeId      = $nodeHost
                Reachable   = $false
                Latency     = $null
                Services    = @()
            }
            try {
                $ping = Test-Connection -TargetName $nodeHost -Count 1 -TimeoutSeconds 3 -ErrorAction Stop
                $pingResult.Reachable = $true
                $pingResult.Latency = $ping.Latency
            }
            catch {
                $pingResult.Reachable = $false
            }
            $result.RemoteNodes += $pingResult
        }
    }

    # ── Overall Health ────────────────────────────────────────────────
    $healthPct = if ($total -gt 0) { [math]::Round(($healthy / $total) * 100) } else { 0 }
    $result.OverallHealth = if ($healthPct -ge 90) { 'Healthy' }
                            elseif ($healthPct -ge 50) { 'Degraded' }
                            elseif ($healthPct -gt 0)  { 'Critical' }
                            else                       { 'Offline' }

    $meshCount = $result.MeshStatus.NodeCount
    $result.Summary = "$healthy/$total services healthy ($healthPct%) | $meshCount mesh node(s) | Health: $($result.OverallHealth)"

    # ── Output ────────────────────────────────────────────────────────
    if ($PassThru) { return $result }

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║       AitherOS Infrastructure Status                 ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  $($result.Summary)" -ForegroundColor $(
        switch ($result.OverallHealth) { 'Healthy' { 'Green' } 'Degraded' { 'Yellow' } default { 'Red' } }
    )
    Write-Host ""

    # Services table
    Write-Host "  Core Services:" -ForegroundColor White
    foreach ($svc in $result.CoreServices) {
        $icon = if ($svc.Status -eq 'Healthy') { '✓' } else { '✗' }
        $color = if ($svc.Status -eq 'Healthy') { 'Green' } else { 'Red' }
        $latency = if ($svc.Latency) { " (${($svc.Latency)}ms)" } else { '' }
        Write-Host "    $icon $($svc.Name.PadRight(18)) :$($svc.Port)  $($svc.Status)$latency" -ForegroundColor $color
    }

    # Mesh
    if ($result.MeshStatus.Connected) {
        Write-Host ""
        Write-Host "  Mesh Nodes ($meshCount):" -ForegroundColor White
        foreach ($node in $result.MeshStatus.Nodes) {
            $roleLabel = "[$($node.Role)]".PadRight(10)
            Write-Host "    • $($node.NodeId) $roleLabel Priority: $($node.Priority)" -ForegroundColor DarkGray
        }
    }

    # Replication
    if ($result.Replication) {
        Write-Host ""
        Write-Host "  Replication:" -ForegroundColor White
        Write-Host "    PostgreSQL: $($result.Replication.PostgreSQL.Status)" -ForegroundColor DarkGray
        Write-Host "    Redis:      $($result.Replication.Redis.Status)" -ForegroundColor DarkGray
        Write-Host "    Strata:     $($result.Replication.Strata.Status)" -ForegroundColor DarkGray
    }

    Write-Host ""
}
