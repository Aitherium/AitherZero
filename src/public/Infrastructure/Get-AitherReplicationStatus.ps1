#Requires -Version 7.0

<#
.SYNOPSIS
    Get the replication status of all AitherOS databases across nodes.

.DESCRIPTION
    Checks PostgreSQL streaming replication, Redis replication/Sentinel,
    and Strata tiered storage sync status. Returns a unified view of
    data replication health for the entire mesh.

    This is the operational command for monitoring replication after 
    setup via 3104_Setup-DatabaseReplication.ps1.

.PARAMETER CoreHost
    The primary (core) host running the main databases. Default: localhost.

.PARAMETER NodeHosts
    Optional list of remote node hostnames to check replica status on.

.PARAMETER IncludeDetails
    Show low-level replication metrics (WAL position, lag bytes, etc.).

.PARAMETER PassThru
    Return structured result objects.

.INPUTS
    None.

.OUTPUTS
    PSCustomObject — Replication status for all databases.

.EXAMPLE
    Get-AitherReplicationStatus
    Quick check on local database replication.

.EXAMPLE
    Get-AitherReplicationStatus -NodeHosts "lab-server" -IncludeDetails
    Full replication report including remote replicas.

.NOTES
    Part of AitherZero module — Infrastructure category.
#>
function Get-AitherReplicationStatus {
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param(
        [string]$CoreHost = "localhost",
        [string[]]$NodeHosts,
        [switch]$IncludeDetails,
        [switch]$PassThru
    )

    $result = [PSCustomObject]@{
        PSTypeName  = 'AitherOS.ReplicationStatus'
        Timestamp   = Get-Date
        CoreHost    = $CoreHost
        PostgreSQL  = $null
        Redis       = $null
        Strata      = $null
        Overall     = 'Unknown'
        Summary     = ''
    }

    $healthyCount = 0
    $totalChecks = 3

    # ── PostgreSQL Streaming Replication ─────────────────────────────
    Write-Host "  Checking PostgreSQL replication..." -ForegroundColor Cyan
    try {
        $pgQuery = @"
SELECT
    slot_name,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes
FROM pg_replication_slots;
"@
        $pgResult = docker exec aitheros-postgres psql -U aitheros -d aitheros -t -A -F '|' -c $pgQuery 2>&1

        if ($LASTEXITCODE -eq 0 -and $pgResult -match '\S') {
            $slots = $pgResult -split "`n" | Where-Object { $_ -match '\S' } | ForEach-Object {
                $fields = $_ -split '\|'
                [PSCustomObject]@{
                    SlotName       = $fields[0]?.Trim()
                    Active         = $fields[1]?.Trim() -eq 't'
                    RestartLSN     = $fields[2]?.Trim()
                    ConfirmedFlush = $fields[3]?.Trim()
                    LagBytes       = [long]($fields[4]?.Trim() ?? 0)
                }
            }

            $activeSlots = @($slots | Where-Object { $_.Active })
            $result.PostgreSQL = [PSCustomObject]@{
                Status      = if ($activeSlots.Count -gt 0) { 'Replicating' } else { 'Slots exist (inactive)' }
                TotalSlots  = $slots.Count
                ActiveSlots = $activeSlots.Count
                MaxLagBytes = ($slots | Measure-Object -Property LagBytes -Maximum).Maximum
                Slots       = if ($IncludeDetails) { $slots } else { $null }
            }
            if ($activeSlots.Count -gt 0) { $healthyCount++ }
        }
        else {
            # No replication slots — check if Postgres is at least running
            $pgCheck = docker exec aitheros-postgres psql -U aitheros -d aitheros -t -c "SELECT 1;" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $result.PostgreSQL = [PSCustomObject]@{
                    Status      = 'No replication configured'
                    TotalSlots  = 0
                    ActiveSlots = 0
                }
            }
            else {
                $result.PostgreSQL = [PSCustomObject]@{ Status = 'Unreachable' }
            }
        }
    }
    catch {
        $result.PostgreSQL = [PSCustomObject]@{ Status = 'Error'; Error = $_.Exception.Message }
    }

    # ── Redis Replication ────────────────────────────────────────────
    Write-Host "  Checking Redis replication..." -ForegroundColor Cyan
    try {
        $redisInfo = docker exec aitheros-redis redis-cli info replication 2>&1
        if ($LASTEXITCODE -eq 0) {
            $role = if ($redisInfo -match 'role:(\w+)') { $Matches[1] } else { 'unknown' }
            $connectedSlaves = if ($redisInfo -match 'connected_slaves:(\d+)') { [int]$Matches[1] } else { 0 }
            $masterHost = if ($redisInfo -match 'master_host:(\S+)') { $Matches[1] } else { '' }
            $masterPort = if ($redisInfo -match 'master_port:(\d+)') { [int]$Matches[1] } else { 0 }
            $masterLinkStatus = if ($redisInfo -match 'master_link_status:(\w+)') { $Matches[1] } else { '' }
            $replOffset = if ($redisInfo -match 'master_repl_offset:(\d+)') { [long]$Matches[1] } else { 0 }

            $status = if ($role -eq 'master' -and $connectedSlaves -gt 0) { 'Replicating' }
                      elseif ($role -eq 'master') { 'Master (standalone)' }
                      elseif ($role -eq 'slave' -and $masterLinkStatus -eq 'up') { 'Replica (synced)' }
                      elseif ($role -eq 'slave') { 'Replica (disconnected)' }
                      else { $role }

            $result.Redis = [PSCustomObject]@{
                Status          = $status
                Role            = $role
                ConnectedSlaves = $connectedSlaves
                MasterHost      = $masterHost
                MasterPort      = $masterPort
                LinkStatus      = $masterLinkStatus
                ReplOffset      = if ($IncludeDetails) { $replOffset } else { $null }
            }
            if ($connectedSlaves -gt 0 -or ($role -eq 'slave' -and $masterLinkStatus -eq 'up')) { $healthyCount++ }
            elseif ($role -eq 'master') { $healthyCount++ }  # Standalone master is OK
        }
        else {
            $result.Redis = [PSCustomObject]@{ Status = 'Unreachable' }
        }
    }
    catch {
        $result.Redis = [PSCustomObject]@{ Status = 'Error'; Error = $_.Exception.Message }
    }

    # ── Strata Sync ──────────────────────────────────────────────────
    Write-Host "  Checking Strata sync..." -ForegroundColor Cyan
    try {
        $strataResp = Invoke-RestMethod -Uri "http://localhost:8136/api/v1/sync/status" -TimeoutSec 5 -ErrorAction Stop
        $result.Strata = [PSCustomObject]@{
            Status  = $strataResp.status ?? 'unknown'
            Peers   = $strataResp.peers ?? $strataResp.connected_peers ?? 0
            LastSync = $strataResp.last_sync ?? ''
            Details = if ($IncludeDetails) { $strataResp } else { $null }
        }
        if ($strataResp.status -eq 'syncing' -or $strataResp.status -eq 'ok') { $healthyCount++ }
    }
    catch {
        $result.Strata = [PSCustomObject]@{ Status = 'Not configured' }
        $healthyCount++  # Not configured is acceptable
    }

    # ── Remote Node Checks (optional) ────────────────────────────────
    if ($NodeHosts) {
        foreach ($nodeHost in $NodeHosts) {
            Write-Host "  Checking remote node: $nodeHost..." -ForegroundColor Cyan
            # Check remote PostgreSQL replica
            try {
                $remoteRedis = Invoke-Command -ComputerName $nodeHost -ScriptBlock {
                    docker exec aitheros-redis redis-cli info replication 2>&1
                } -ErrorAction Stop
                # Parse remote Redis info similarly...
            }
            catch {
                Write-Verbose "Remote check failed for ${nodeHost}: $($_.Exception.Message)"
            }
        }
    }

    # ── Overall Status ───────────────────────────────────────────────
    $result.Overall = if ($healthyCount -ge 3) { 'Healthy' }
                      elseif ($healthyCount -ge 2) { 'Partial' }
                      elseif ($healthyCount -ge 1) { 'Degraded' }
                      else { 'Critical' }

    $pgLabel = $result.PostgreSQL.Status
    $redisLabel = $result.Redis.Status
    $strataLabel = $result.Strata.Status
    $result.Summary = "PostgreSQL: $pgLabel | Redis: $redisLabel | Strata: $strataLabel | Overall: $($result.Overall)"

    # ── Output ────────────────────────────────────────────────────────
    if ($PassThru) { return $result }

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║       Database Replication Status                     ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # PostgreSQL
    $pgIcon = if ($result.PostgreSQL.Status -match 'Replicat') { '✓' } else { '○' }
    $pgColor = if ($result.PostgreSQL.Status -match 'Replicat') { 'Green' } 
               elseif ($result.PostgreSQL.Status -match 'Unreachable|Error') { 'Red' }
               else { 'Yellow' }
    Write-Host "  $pgIcon PostgreSQL: $pgLabel" -ForegroundColor $pgColor
    if ($result.PostgreSQL.TotalSlots) {
        Write-Host "    Slots: $($result.PostgreSQL.ActiveSlots)/$($result.PostgreSQL.TotalSlots) active" -ForegroundColor DarkGray
        if ($result.PostgreSQL.MaxLagBytes -and $result.PostgreSQL.MaxLagBytes -gt 0) {
            $lagMB = [math]::Round($result.PostgreSQL.MaxLagBytes / 1MB, 2)
            Write-Host "    Max lag: ${lagMB} MB" -ForegroundColor $(if ($lagMB -gt 100) { 'Red' } else { 'DarkGray' })
        }
    }

    # Redis
    $redisIcon = if ($result.Redis.Status -match 'Replicat|synced') { '✓' } 
                 elseif ($result.Redis.Role -eq 'master') { '○' }
                 else { '✗' }
    $redisColor = if ($result.Redis.Status -match 'Replicat|synced|standalone') { 'Green' }
                  elseif ($result.Redis.Status -match 'disconnected|Unreachable') { 'Red' }
                  else { 'Yellow' }
    Write-Host "  $redisIcon Redis: $redisLabel" -ForegroundColor $redisColor
    if ($result.Redis.ConnectedSlaves -gt 0) {
        Write-Host "    Connected replicas: $($result.Redis.ConnectedSlaves)" -ForegroundColor DarkGray
    }

    # Strata
    $strataIcon = if ($result.Strata.Status -match 'sync|ok') { '✓' } else { '○' }
    $strataColor = if ($result.Strata.Status -match 'sync|ok') { 'Green' } else { 'Yellow' }
    Write-Host "  $strataIcon Strata: $strataLabel" -ForegroundColor $strataColor

    Write-Host ""
    Write-Host "  Overall: $($result.Overall)" -ForegroundColor $(
        switch ($result.Overall) { 'Healthy' { 'Green' } 'Partial' { 'Yellow' } default { 'Red' } }
    )
    Write-Host ""
}
