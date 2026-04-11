#Requires -Version 7.0
<#
.SYNOPSIS
    Docker Desktop daemon watchdog — detects crashes and auto-recovers the AitherOS mesh.

.DESCRIPTION
    Runs as a persistent background loop that monitors Docker Desktop health.
    When the daemon dies (3 consecutive failed polls), the watchdog:
    1. Restarts Docker Desktop
    2. Waits for daemon readiness (up to 3 minutes)
    3. Brings the AitherOS service mesh back up via docker compose
    4. Logs all events to logs/docker-watchdog.log

    Designed to run as a Windows Scheduled Task via 0847_Setup-DockerWatchdog.ps1.

.PARAMETER Profile
    Docker Compose profile to bring up after recovery. Default: "core"

.PARAMETER PollInterval
    Seconds between health checks. Default: 30

.PARAMETER FailThreshold
    Consecutive failures before declaring Docker dead. Default: 3

.PARAMETER DaemonTimeout
    Max seconds to wait for Docker daemon after restart. Default: 180

.PARAMETER RecoveryCooldown
    Seconds to wait after a successful recovery before resuming polling. Default: 60

.PARAMETER LogFile
    Path to the watchdog log file. Default: <workspace>/logs/docker-watchdog.log

.EXAMPLE
    .\0846_DockerDaemon-Watchdog.ps1
    .\0846_DockerDaemon-Watchdog.ps1 -Profile all -PollInterval 15
#>

[CmdletBinding()]
param(
    [ValidateSet("minimal", "core", "full", "all")]
    [string]$Profile = "core",

    [int]$PollInterval = 30,
    [int]$FailThreshold = 3,
    [int]$DaemonTimeout = 180,
    [int]$RecoveryCooldown = 60,
    [string]$LogFile
)

$ErrorActionPreference = 'Continue'

# =============================================================================
# PATHS
# =============================================================================

$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$composeFile = Join-Path $workspaceRoot "docker-compose.aitheros.yml"

if (-not $LogFile) {
    $logsDir = Join-Path $workspaceRoot "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    $LogFile = Join-Path $logsDir "docker-watchdog.log"
}

# =============================================================================
# LOGGING
# =============================================================================

function Write-WatchdogLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "RECOVERY")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    # Console output with color
    $color = switch ($Level) {
        "INFO"     { "Gray" }
        "WARN"     { "Yellow" }
        "ERROR"    { "Red" }
        "RECOVERY" { "Green" }
    }
    Write-Host $entry -ForegroundColor $color

    # File output (append)
    try {
        $entry | Out-File -FilePath $LogFile -Append -Encoding utf8
    } catch {
        # Don't crash the watchdog if logging fails
    }
}

# =============================================================================
# DOCKER DESKTOP DISCOVERY
# =============================================================================

function Find-DockerDesktopExe {
    $paths = @(
        "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# =============================================================================
# DOCKER HEALTH CHECK
# =============================================================================

function Test-DockerDaemon {
    <#
    .SYNOPSIS
        Returns $true if docker daemon is responsive, $false otherwise.
    #>
    try {
        $null = docker info 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# =============================================================================
# RECOVERY LOGIC
# =============================================================================

function Restart-DockerDesktop {
    <#
    .SYNOPSIS
        Kills any zombie Docker processes, starts Docker Desktop, waits for readiness.
        Returns $true if daemon is responsive after restart.
    #>
    param([int]$Timeout = 180)

    Write-WatchdogLog "Attempting to restart Docker Desktop..." -Level RECOVERY

    # Kill any zombie Docker processes
    $dockerProcesses = @("Docker Desktop", "com.docker.backend", "com.docker.proxy")
    foreach ($procName in $dockerProcesses) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($procs) {
            Write-WatchdogLog "Killing zombie process: $procName (PID: $($procs.Id -join ', '))" -Level WARN
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 5

    # Find and launch Docker Desktop
    $dockerExe = Find-DockerDesktopExe
    if (-not $dockerExe) {
        Write-WatchdogLog "Docker Desktop executable not found!" -Level ERROR
        return $false
    }

    Write-WatchdogLog "Starting: $dockerExe" -Level INFO
    Start-Process -FilePath $dockerExe -WindowStyle Hidden

    # Wait for daemon
    Write-WatchdogLog "Waiting for Docker daemon (up to ${Timeout}s)..." -Level INFO
    $waited = 0
    while ($waited -lt $Timeout) {
        Start-Sleep -Seconds 5
        $waited += 5

        if (Test-DockerDaemon) {
            Write-WatchdogLog "Docker daemon is responsive after ${waited}s" -Level RECOVERY
            return $true
        }

        if (($waited % 30) -eq 0) {
            Write-WatchdogLog "Still waiting... ${waited}s / ${Timeout}s" -Level INFO
        }
    }

    Write-WatchdogLog "Docker daemon failed to start within ${Timeout}s" -Level ERROR
    return $false
}

function Recover-AitherOSMesh {
    <#
    .SYNOPSIS
        Brings the AitherOS service mesh back up after Docker recovery.
        Containers with restart: unless-stopped should auto-start,
        but we force `up -d` as belt-and-suspenders.
    #>
    param([string]$ComposeProfile = "core")

    Write-WatchdogLog "Recovering AitherOS mesh (profile: $ComposeProfile)..." -Level RECOVERY

    if (-not (Test-Path $composeFile)) {
        Write-WatchdogLog "Compose file not found: $composeFile" -Level ERROR
        return $false
    }

    # Give Docker a moment to fully initialize networking
    Start-Sleep -Seconds 10

    try {
        $output = docker compose -f $composeFile --profile $ComposeProfile up -d 2>&1
        $exitCode = $LASTEXITCODE

        # Log any errors from compose
        $output | ForEach-Object {
            $line = $_.ToString()
            if ($line -match "error|Error|ERROR|failed|Failed") {
                Write-WatchdogLog "Compose: $line" -Level WARN
            }
        }

        if ($exitCode -eq 0) {
            Write-WatchdogLog "AitherOS mesh recovered successfully" -Level RECOVERY
            return $true
        } else {
            Write-WatchdogLog "docker compose exited with code $exitCode" -Level ERROR
            return $false
        }
    } catch {
        Write-WatchdogLog "Mesh recovery failed: $_" -Level ERROR
        return $false
    }
}

# =============================================================================
# MAIN WATCHDOG LOOP
# =============================================================================

Write-WatchdogLog "========================================" -Level INFO
Write-WatchdogLog "AitherOS Docker Watchdog starting" -Level INFO
Write-WatchdogLog "  Profile:        $Profile" -Level INFO
Write-WatchdogLog "  Poll interval:  ${PollInterval}s" -Level INFO
Write-WatchdogLog "  Fail threshold: $FailThreshold" -Level INFO
Write-WatchdogLog "  Daemon timeout: ${DaemonTimeout}s" -Level INFO
Write-WatchdogLog "  Cooldown:       ${RecoveryCooldown}s" -Level INFO
Write-WatchdogLog "  Compose file:   $composeFile" -Level INFO
Write-WatchdogLog "  Log file:       $LogFile" -Level INFO
Write-WatchdogLog "========================================" -Level INFO

$consecutiveFailures = 0
$totalRecoveries = 0
$lastRecoveryTime = $null

while ($true) {
    $healthy = Test-DockerDaemon

    if ($healthy) {
        # Reset failure counter on success
        if ($consecutiveFailures -gt 0) {
            Write-WatchdogLog "Docker daemon healthy (cleared $consecutiveFailures failure(s))" -Level INFO
        }
        $consecutiveFailures = 0
    } else {
        $consecutiveFailures++
        Write-WatchdogLog "Docker daemon unresponsive ($consecutiveFailures / $FailThreshold)" -Level WARN

        if ($consecutiveFailures -ge $FailThreshold) {
            Write-WatchdogLog "*** DOCKER DAEMON DECLARED DEAD — INITIATING RECOVERY ***" -Level ERROR

            $daemonRestored = Restart-DockerDesktop -Timeout $DaemonTimeout

            if ($daemonRestored) {
                $meshRestored = Recover-AitherOSMesh -ComposeProfile $Profile
                $totalRecoveries++
                $lastRecoveryTime = Get-Date

                if ($meshRestored) {
                    Write-WatchdogLog "======= FULL RECOVERY COMPLETE (total: $totalRecoveries) =======" -Level RECOVERY
                } else {
                    Write-WatchdogLog "Docker restored but mesh recovery had issues (total: $totalRecoveries)" -Level WARN
                }

                # Cooldown to avoid rapid restart loops
                Write-WatchdogLog "Cooldown: ${RecoveryCooldown}s before resuming polling" -Level INFO
                Start-Sleep -Seconds $RecoveryCooldown
            } else {
                Write-WatchdogLog "Docker daemon restart FAILED — will retry next cycle" -Level ERROR
                # Extra backoff on failed recovery
                Start-Sleep -Seconds ($RecoveryCooldown * 2)
            }

            $consecutiveFailures = 0
        }
    }

    Start-Sleep -Seconds $PollInterval
}
