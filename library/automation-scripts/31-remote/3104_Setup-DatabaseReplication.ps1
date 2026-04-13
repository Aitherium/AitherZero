#Requires -Version 7.0

<#
.SYNOPSIS
    Configure database replication between AitherOS core and remote nodes.

.DESCRIPTION
    Sets up bidirectional data synchronization across AitherMesh nodes:

    - PostgreSQL streaming replication (primary on core → replica on node)
    - Redis replication (master on core → replica on node, with sentinel failover)
    - Strata tier sync (via MeshAgent /strata/replicate endpoint)
    - Automated backup scheduling for disaster recovery

    This script is called AFTER a node has been deployed (3101) and joined the mesh.
    It configures the databases on both the core machine and the remote node.

    Replication Model:
    ┌──────────────────────────────────────────────────────────┐
    │  Core (Primary)           │  Node (Replica)              │
    │  ─────────────            │  ──────────────              │
    │  PostgreSQL (RW)    ────→ │  PostgreSQL (RO/Hot-Standby) │
    │  Redis Master       ────→ │  Redis Replica               │
    │  Strata (Hot tier)  ────→ │  Strata (Warm tier mirror)   │
    └──────────────────────────────────────────────────────────┘

    Exit Codes:
        0 - Success
        1 - Connection failure
        2 - PostgreSQL replication setup failed
        3 - Redis replication setup failed
        4 - Strata sync failed

.PARAMETER CoreHost
    Hostname/IP of the AitherOS core (primary) machine. Default: localhost.

.PARAMETER NodeHost
    Hostname/IP of the remote AitherNode to configure as replica. REQUIRED.

.PARAMETER Credential
    PSCredential for remote node access.

.PARAMETER PostgresPassword
    PostgreSQL replication password. Auto-generated if not provided.

.PARAMETER SkipPostgres
    Skip PostgreSQL replication setup.

.PARAMETER SkipRedis
    Skip Redis replication setup.

.PARAMETER SkipStrata
    Skip Strata tier sync.

.PARAMETER EnableSentinel
    Deploy Redis Sentinel on both sides for automatic failover.

.PARAMETER BackupSchedule
    Cron expression for automated PostgreSQL backups. Default: "0 3 * * *" (3 AM daily).

.PARAMETER DryRun
    Show what would be configured without making changes.

.NOTES
    Stage: Remote-Deploy
    Order: 3104
    Dependencies: 3101_Deploy-RemoteNode.ps1
    Tags: replication, database, postgres, redis, strata, failover
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CoreHost = "localhost",

    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$NodeHost,

    [PSCredential]$Credential,

    [string]$PostgresPassword,

    [switch]$SkipPostgres,
    [switch]$SkipRedis,
    [switch]$SkipStrata,
    [switch]$EnableSentinel,

    [string]$BackupSchedule = "0 3 * * *",

    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ═══════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════

$PostgresPort       = 5432
$RedisPort          = 6379
$StrataPort         = 8136
$MeshPort           = 8125
$ReplicationSlotName = "aither_node_$(($NodeHost -replace '[.\-:]','_'))"

if (-not $PostgresPassword) {
    # Generate a secure random password for replication
    $PostgresPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
}

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
    Write-Host "  [$Phase] $(switch($Status){'OK'{'[+]'}'WARN'{'[!]'}'ERROR'{'[-]'}'SKIP'{'[~]'}default{'[*]'}}) $Message" -ForegroundColor $color
}

function Invoke-DockerOnHost {
    param(
        [string]$Host_,
        [string]$ContainerName,
        [string]$Command,
        [PSCredential]$Cred
    )

    if ($Host_ -eq "localhost" -or $Host_ -eq "127.0.0.1" -or $Host_ -eq $env:COMPUTERNAME) {
        return docker exec $ContainerName bash -c $Command 2>&1
    } else {
        $sessionParams = @{ ComputerName = $Host_; ErrorAction = 'Stop' }
        if ($Cred) { $sessionParams.Credential = $Cred }
        $session = New-PSSession @sessionParams
        try {
            return Invoke-Command -Session $session -ScriptBlock {
                docker exec $using:ContainerName bash -c $using:Command 2>&1
            }
        } finally {
            Remove-PSSession $session
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Blue
Write-Host "  ║    AitherOS — Database Replication Setup (3104)    ║" -ForegroundColor Blue
Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Blue
Write-Host ""
Write-Host "  Core (Primary):   $CoreHost" -ForegroundColor White
Write-Host "  Node (Replica):   $NodeHost" -ForegroundColor White
Write-Host "  Mode:             $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' })" -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'Green' })
Write-Host ""

if ($DryRun) {
    Write-Host "  [DRY RUN] Would configure:" -ForegroundColor Yellow
    if (-not $SkipPostgres) { Write-Host "    • PostgreSQL streaming replication" -ForegroundColor DarkGray }
    if (-not $SkipRedis)    { Write-Host "    • Redis master-replica replication" -ForegroundColor DarkGray }
    if ($EnableSentinel)    { Write-Host "    • Redis Sentinel failover" -ForegroundColor DarkGray }
    if (-not $SkipStrata)   { Write-Host "    • Strata tiered storage sync" -ForegroundColor DarkGray }
    Write-Host ""
    return
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 1: POSTGRESQL STREAMING REPLICATION
# ═══════════════════════════════════════════════════════════════════════

if (-not $SkipPostgres) {
    Write-Step "PG" "Configuring PostgreSQL streaming replication..."

    try {
        # 1a. Configure the PRIMARY (core) for replication
        Write-Step "PG" "Configuring primary (core) PostgreSQL..."

        # Create replication user
        $createUserSQL = @"
DO \`$\`$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'aither_replicator') THEN
        CREATE ROLE aither_replicator WITH REPLICATION LOGIN PASSWORD '$PostgresPassword';
    END IF;
END
\`$\`$;
"@
        Invoke-DockerOnHost -Host_ $CoreHost -ContainerName "aitheros-postgres-1" -Command "psql -U postgres -c `"$createUserSQL`"" -Cred $Credential
        Write-Step "PG" "Replication user 'aither_replicator' ensured" "OK"

        # Create replication slot
        $slotSQL = "SELECT pg_create_physical_replication_slot('$ReplicationSlotName', true) WHERE NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = '$ReplicationSlotName');"
        Invoke-DockerOnHost -Host_ $CoreHost -ContainerName "aitheros-postgres-1" -Command "psql -U postgres -c `"$slotSQL`"" -Cred $Credential
        Write-Step "PG" "Replication slot '$ReplicationSlotName' ensured" "OK"

        # Update pg_hba.conf to allow replication from node
        $hbaEntry = "host replication aither_replicator $NodeHost/32 scram-sha-256"
        $hbaCheck = Invoke-DockerOnHost -Host_ $CoreHost -ContainerName "aitheros-postgres-1" -Command "grep -c 'aither_replicator' /var/lib/postgresql/data/pg_hba.conf || echo 0" -Cred $Credential
        if ([int]($hbaCheck | Select-Object -Last 1) -eq 0) {
            Invoke-DockerOnHost -Host_ $CoreHost -ContainerName "aitheros-postgres-1" -Command "echo '$hbaEntry' >> /var/lib/postgresql/data/pg_hba.conf" -Cred $Credential
            # Reload config
            Invoke-DockerOnHost -Host_ $CoreHost -ContainerName "aitheros-postgres-1" -Command "psql -U postgres -c 'SELECT pg_reload_conf();'" -Cred $Credential
            Write-Step "PG" "pg_hba.conf updated for replication access" "OK"
        }

        # Ensure wal_level = replica and max_wal_senders >= 5
        $walConfig = @"
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET max_wal_senders = 5;
ALTER SYSTEM SET max_replication_slots = 5;
ALTER SYSTEM SET hot_standby = on;
ALTER SYSTEM SET wal_keep_size = '256MB';
SELECT pg_reload_conf();
"@
        Invoke-DockerOnHost -Host_ $CoreHost -ContainerName "aitheros-postgres-1" -Command "psql -U postgres -c `"$walConfig`"" -Cred $Credential
        Write-Step "PG" "WAL settings configured for streaming replication" "OK"

        # 1b. Configure the REPLICA (node) PostgreSQL
        Write-Step "PG" "Configuring replica (node) PostgreSQL..."

        # Create standby.signal and recovery config on the node
        $standbyConfig = @"
primary_conninfo = 'host=$CoreHost port=$PostgresPort user=aither_replicator password=$PostgresPassword application_name=$ReplicationSlotName'
primary_slot_name = '$ReplicationSlotName'
restore_command = ''
recovery_target_timeline = 'latest'
"@
        # Write config to node's postgres container
        $sessionParams = @{ ComputerName = $NodeHost; ErrorAction = 'Stop' }
        if ($Credential) { $sessionParams.Credential = $Credential }
        $nodeSession = New-PSSession @sessionParams

        Invoke-Command -Session $nodeSession -ScriptBlock {
            $config = $using:standbyConfig
            # Stop the node postgres, do a base backup, configure standby
            docker stop aitheros-postgres-1 2>&1 | Out-Null

            # Clear existing data and do a base backup from primary
            docker run --rm -v aitheros_postgres_data:/data -w /data postgres:16 `
                bash -c "rm -rf /data/* && PGPASSWORD='$using:PostgresPassword' pg_basebackup -h $using:CoreHost -p $using:PostgresPort -U aither_replicator -D /data -Fp -Xs -R -P" 2>&1

            # Write standby.signal
            docker run --rm -v aitheros_postgres_data:/data postgres:16 `
                bash -c "touch /data/standby.signal" 2>&1

            # Start replica
            docker start aitheros-postgres-1 2>&1 | Out-Null
        }
        Remove-PSSession $nodeSession

        Write-Step "PG" "PostgreSQL streaming replication configured" "OK"

        # Verify replication
        Start-Sleep -Seconds 5
        $repStatus = Invoke-DockerOnHost -Host_ $CoreHost -ContainerName "aitheros-postgres-1" -Command "psql -U postgres -c 'SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;'" -Cred $Credential
        Write-Step "PG" "Replication status:" "INFO"
        Write-Host "    $repStatus" -ForegroundColor DarkGray

    } catch {
        Write-Step "PG" "PostgreSQL replication setup failed: $_" "ERROR"
        if (-not $Force) { exit 2 }
    }
} else {
    Write-Step "PG" "PostgreSQL replication skipped" "SKIP"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 2: REDIS REPLICATION
# ═══════════════════════════════════════════════════════════════════════

if (-not $SkipRedis) {
    Write-Step "REDIS" "Configuring Redis replication..."

    try {
        # Configure the node's Redis as a replica of the core's Redis
        $sessionParams = @{ ComputerName = $NodeHost; ErrorAction = 'Stop' }
        if ($Credential) { $sessionParams.Credential = $Credential }
        $nodeSession = New-PSSession @sessionParams

        Invoke-Command -Session $nodeSession -ScriptBlock {
            # Set REPLICAOF on the node's Redis
            docker exec aitheros-redis-1 redis-cli REPLICAOF $using:CoreHost $using:RedisPort 2>&1 | Out-Null

            # Verify
            $info = docker exec aitheros-redis-1 redis-cli INFO replication 2>&1
            Write-Output $info
        }

        Write-Step "REDIS" "Redis replica configured (REPLICAOF $CoreHost)" "OK"

        # Optional: Deploy Redis Sentinel for automatic failover
        if ($EnableSentinel) {
            Write-Step "REDIS" "Deploying Redis Sentinel for automatic failover..."

            # Create sentinel config
            $sentinelConfig = @"
port 26379
sentinel monitor aitheros-master $CoreHost $RedisPort 2
sentinel down-after-milliseconds aitheros-master 10000
sentinel failover-timeout aitheros-master 30000
sentinel parallel-syncs aitheros-master 1
"@
            # Deploy sentinel on core
            Invoke-DockerOnHost -Host_ $CoreHost -ContainerName "aitheros-redis-1" -Command @"
cat > /tmp/sentinel.conf << 'EOF'
$sentinelConfig
EOF
redis-sentinel /tmp/sentinel.conf --daemonize yes
"@ -Cred $Credential

            # Deploy sentinel on node
            Invoke-Command -Session $nodeSession -ScriptBlock {
                $config = $using:sentinelConfig
                docker exec aitheros-redis-1 bash -c @"
cat > /tmp/sentinel.conf << 'EOF'
$config
EOF
redis-sentinel /tmp/sentinel.conf --daemonize yes
"@
            }

            Write-Step "REDIS" "Redis Sentinel deployed on both nodes" "OK"
        }

        Remove-PSSession $nodeSession

    } catch {
        Write-Step "REDIS" "Redis replication setup failed: $_" "ERROR"
        if (-not $Force) { exit 3 }
    }
} else {
    Write-Step "REDIS" "Redis replication skipped" "SKIP"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 3: STRATA TIER SYNC
# ═══════════════════════════════════════════════════════════════════════

if (-not $SkipStrata) {
    Write-Step "STRATA" "Configuring Strata tier sync via MeshAgent..."

    try {
        # Use the MeshAgent's built-in /strata/replicate endpoint
        $coreStrataUrl = "http://${CoreHost}:${MeshPort}"

        # Start replication sync from core → node
        $syncPayload = @{
            target_node  = $NodeHost
            tiers        = @("hot", "warm")
            mode         = "incremental"
            schedule     = $BackupSchedule
            auto_failover = $true
        } | ConvertTo-Json

        $response = Invoke-RestMethod -Uri "$coreStrataUrl/strata/replicate" `
            -Method POST `
            -Body $syncPayload `
            -ContentType "application/json" `
            -TimeoutSec 30 `
            -ErrorAction Stop

        Write-Step "STRATA" "Strata replication started: $($response.status ?? 'initiated')" "OK"

        # Also start the sync endpoint
        $syncResponse = Invoke-RestMethod -Uri "$coreStrataUrl/strata/sync/start" `
            -Method POST `
            -Body (@{ target = $NodeHost; tiers = @("hot","warm") } | ConvertTo-Json) `
            -ContentType "application/json" `
            -TimeoutSec 30 `
            -ErrorAction SilentlyContinue

        if ($syncResponse) {
            Write-Step "STRATA" "Strata continuous sync started" "OK"
        }

    } catch {
        Write-Step "STRATA" "Strata sync setup failed: $_" "WARN"
        Write-Step "STRATA" "This may require the MeshAgent to be running. Try after mesh join." "WARN"
        if (-not $Force) { exit 4 }
    }
} else {
    Write-Step "STRATA" "Strata tier sync skipped" "SKIP"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 4: BACKUP SCHEDULING
# ═══════════════════════════════════════════════════════════════════════

Write-Step "BACKUP" "Configuring automated backup schedule..."

try {
    # Create a backup script on the core that pg_dump to Strata cold tier
    $backupScript = @'
#!/bin/bash
# AitherOS PostgreSQL Backup Script (auto-generated by 3104)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/data/strata/cold/backups/postgres"
mkdir -p "$BACKUP_DIR"

# Full dump
pg_dumpall -U postgres | gzip > "$BACKUP_DIR/full_backup_${TIMESTAMP}.sql.gz"

# Rotate: keep last 7 daily backups
find "$BACKUP_DIR" -name "full_backup_*.sql.gz" -mtime +7 -delete

echo "Backup completed: full_backup_${TIMESTAMP}.sql.gz"
'@

    Invoke-DockerOnHost -Host_ $CoreHost -ContainerName "aitheros-postgres-1" `
        -Command "echo '$backupScript' > /var/lib/postgresql/backup.sh && chmod +x /var/lib/postgresql/backup.sh" `
        -Cred $Credential

    # Schedule via cron inside container (or host-level scheduled task)
    if ($CoreHost -eq "localhost" -or $CoreHost -eq "127.0.0.1") {
        # Use Windows Task Scheduler on the core
        $taskAction = New-ScheduledTaskAction -Execute "docker" -Argument "exec aitheros-postgres-1 bash /var/lib/postgresql/backup.sh"
        $taskTrigger = New-ScheduledTaskTrigger -Daily -At "3:00AM"
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        $existingTask = Get-ScheduledTask -TaskName "AitherOS-PostgresBackup" -ErrorAction SilentlyContinue
        if ($existingTask) {
            Set-ScheduledTask -TaskName "AitherOS-PostgresBackup" -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings | Out-Null
        } else {
            Register-ScheduledTask -TaskName "AitherOS-PostgresBackup" -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Description "AitherOS PostgreSQL daily backup" | Out-Null
        }
        Write-Step "BACKUP" "Scheduled daily PostgreSQL backup at 3:00 AM" "OK"
    } else {
        Write-Step "BACKUP" "Backup script created. Schedule on remote host with Task Scheduler." "WARN"
    }

} catch {
    Write-Step "BACKUP" "Backup scheduling failed: $_" "WARN"
}

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║    Database Replication Configuration Complete     ║" -ForegroundColor Green
Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Replication Summary:" -ForegroundColor Yellow
if (-not $SkipPostgres) {
    Write-Host "    PostgreSQL:  $CoreHost (primary) → $NodeHost (hot standby)" -ForegroundColor White
}
if (-not $SkipRedis) {
    Write-Host "    Redis:       $CoreHost (master) → $NodeHost (replica)" -ForegroundColor White
    if ($EnableSentinel) {
        Write-Host "    Sentinel:    Active on both nodes (quorum=2)" -ForegroundColor White
    }
}
if (-not $SkipStrata) {
    Write-Host "    Strata:      Hot+Warm tiers syncing continuously" -ForegroundColor White
}
Write-Host ""
Write-Host "  Monitor replication:" -ForegroundColor Cyan
Write-Host "    docker exec aitheros-postgres-1 psql -U postgres -c 'SELECT * FROM pg_stat_replication;'" -ForegroundColor DarkGray
Write-Host "    docker exec aitheros-redis-1 redis-cli INFO replication" -ForegroundColor DarkGray
Write-Host "    curl http://localhost:8125/strata/sync/status" -ForegroundColor DarkGray
Write-Host ""

exit 0
