#Requires -Version 7.0

<#
.SYNOPSIS
    Get the status of all nodes in the AitherMesh, including failover state.

.DESCRIPTION
    Queries the AitherMesh for registered nodes and their health status.
    Shows connectivity, failover priority, replicated services, and role.

    Can also manage nodes: drain, rejoin, promote, remove.

.PARAMETER Action
    Action to perform: Status (default), Drain, Rejoin, Promote, Remove.

.PARAMETER NodeId
    Target node for Drain/Rejoin/Promote/Remove actions.

.PARAMETER CoreUrl
    AitherOS Core URL. Default: http://localhost:8001

.PARAMETER MeshPort
    MeshCore port. Default: 8125

.PARAMETER Detailed
    Show per-service health for each node.

.PARAMETER PassThru
    Return result objects.

.INPUTS
    None.

.OUTPUTS
    PSCustomObject — Mesh status.

.EXAMPLE
    Get-AitherMeshStatus

.EXAMPLE
    Get-AitherMeshStatus -Detailed

.EXAMPLE
    Get-AitherMeshStatus -Action Drain -NodeId "lab-server"

.NOTES
    Part of AitherZero module — Deployment category.
#>
function Get-AitherMeshStatus {
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param(
        [ValidateSet("Status", "Drain", "Rejoin", "Promote", "Remove")]
        [string]$Action = "Status",

        [string]$NodeId,

        [string]$CoreUrl = "http://localhost:8001",
        [int]$MeshPort = 8125,

        [switch]$Detailed,
        [switch]$PassThru
    )

    $meshUrl = $CoreUrl -replace ':\d+$', ":$MeshPort"

    # ── Actions that target a specific node ──────────────────
    if ($Action -ne "Status") {
        if (-not $NodeId) {
            throw "NodeId is required for action '$Action'"
        }

        $endpoint = switch ($Action) {
            "Drain"   { "/mesh/drain" }
            "Rejoin"  { "/mesh/rejoin" }
            "Promote" { "/mesh/promote" }
            "Remove"  { "/mesh/nodes/$NodeId" }
        }
        $method = if ($Action -eq "Remove") { "DELETE" } else { "POST" }
        $body = @{ node_id = $NodeId; action = $Action.ToLower() } | ConvertTo-Json

        try {
            $result = Invoke-RestMethod -Uri "${meshUrl}${endpoint}" -Method $method `
                -Body $body -ContentType "application/json" -TimeoutSec 10
            Write-Host "  ✓ $Action on $NodeId — $($result.status ?? 'ok')" -ForegroundColor Green
            if ($PassThru) { return $result }
            return
        }
        catch {
            Write-Host "  ✗ $Action on $NodeId failed: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    # ── Status display ───────────────────────────────────────

    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          AitherMesh Status                         ║" -ForegroundColor Cyan
    Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "  Mesh endpoint: $meshUrl" -ForegroundColor DarkGray
    Write-Host ""

    # Get mesh nodes
    try {
        $meshData = Invoke-RestMethod -Uri "$meshUrl/mesh/nodes" -TimeoutSec 10 -ErrorAction Stop
        $nodes = if ($meshData.nodes) { $meshData.nodes } elseif ($meshData -is [array]) { $meshData } else { @() }
    }
    catch {
        Write-Host "  ✗ Cannot reach MeshCore at $meshUrl" -ForegroundColor Red
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Is AitherOS Core running? Try:" -ForegroundColor Yellow
        Write-Host "    docker ps --filter name=aitheros-meshcore" -ForegroundColor DarkGray
        Write-Host ""
        if ($PassThru) { return [PSCustomObject]@{ Status = 'Unreachable'; Nodes = @() } }
        return
    }

    if ($nodes.Count -eq 0) {
        Write-Host "  No nodes registered in mesh" -ForegroundColor Yellow
        Write-Host "  Deploy a node: Invoke-AitherElysiumDeploy -ComputerName <host>" -ForegroundColor DarkGray
        Write-Host ""
        if ($PassThru) { return [PSCustomObject]@{ Status = 'Empty'; Nodes = @() } }
        return
    }

    # Display each node
    $nodeResults = @()
    foreach ($node in $nodes) {
        $nid = $node.node_id ?? $node.id ?? "unknown"
        $nurl = $node.node_url ?? $node.url ?? ""
        $role = $node.role ?? "compute"
        $priority = $node.failover_priority ?? $node.priority ?? "?"
        $lastSeen = $node.last_heartbeat ?? $node.last_seen ?? ""

        # Check health
        $healthy = $false
        if ($nurl) {
            try {
                Invoke-RestMethod -Uri "$nurl/health" -TimeoutSec 3 -ErrorAction Stop | Out-Null
                $healthy = $true
            }
            catch { }
        }

        $statusIcon = if ($healthy) { "●" } else { "○" }
        $statusColor = if ($healthy) { "Green" } else { "Red" }
        $statusText = if ($healthy) { "ONLINE" } else { "OFFLINE" }

        Write-Host "  $statusIcon $nid" -ForegroundColor $statusColor -NoNewline
        Write-Host " — $statusText" -ForegroundColor $statusColor -NoNewline
        Write-Host " | Role: $role | Priority: $priority" -ForegroundColor DarkGray
        if ($nurl) {
            Write-Host "    URL: $nurl" -ForegroundColor DarkGray
        }
        if ($lastSeen) {
            Write-Host "    Last seen: $lastSeen" -ForegroundColor DarkGray
        }

        if ($Detailed -and $healthy -and $nurl) {
            $services = @(
                @{ Name = "Genesis"; Port = 8001 },
                @{ Name = "Pulse";   Port = 8081 },
                @{ Name = "Watch";   Port = 8082 },
                @{ Name = "Mesh";    Port = 8125 },
                @{ Name = "Strata";  Port = 8136 }
            )
            $baseUrl = $nurl -replace ':\d+$', ''
            foreach ($svc in $services) {
                try {
                    Invoke-RestMethod -Uri "${baseUrl}:$($svc.Port)/health" -TimeoutSec 2 -ErrorAction Stop | Out-Null
                    Write-Host "      ✓ $($svc.Name):$($svc.Port)" -ForegroundColor Green
                }
                catch {
                    Write-Host "      ✗ $($svc.Name):$($svc.Port)" -ForegroundColor Red
                }
            }
        }

        $nodeResults += [PSCustomObject]@{
            NodeId   = $nid
            NodeUrl  = $nurl
            Role     = $role
            Priority = $priority
            Healthy  = $healthy
            LastSeen = $lastSeen
        }
        Write-Host ""
    }

    $onlineCount = ($nodeResults | Where-Object { $_.Healthy }).Count
    Write-Host "  Summary: $onlineCount/$($nodeResults.Count) nodes online" -ForegroundColor $(if ($onlineCount -eq $nodeResults.Count) { "Green" } else { "Yellow" })
    Write-Host ""

    if ($PassThru) {
        return [PSCustomObject]@{
            PSTypeName  = 'AitherOS.MeshStatus'
            Status      = if ($onlineCount -eq $nodeResults.Count) { 'AllHealthy' } elseif ($onlineCount -gt 0) { 'Degraded' } else { 'AllDown' }
            OnlineNodes = $onlineCount
            TotalNodes  = $nodeResults.Count
            Nodes       = $nodeResults
            MeshUrl     = $meshUrl
            Timestamp   = Get-Date
        }
    }
}
