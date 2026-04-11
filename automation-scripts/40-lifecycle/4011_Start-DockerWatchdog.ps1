#Requires -Version 7.0
<#
.SYNOPSIS
    AitherOS Docker Watchdog — auto-recovers Docker Desktop crashes and
    container outages so aitherium.com / demo.aitherium.com stay online.

.DESCRIPTION
    Runs a single health-check cycle (designed to be called by Task Scheduler
    every few minutes).  Detects and repairs the following failure modes:

      1. Docker Desktop daemon dead (\\.\pipe\docker_engine absent / unresponsive)
         → kills & restarts Docker Desktop, waits up to DockerStartTimeoutSec
      2. Core containers missing / stopped (Docker alive but services down)
         → `docker compose --profile core up -d`
      3. Cloudflare tunnel container unhealthy / stopped
         → `docker compose up -d aitheros-tunnel`
      4. Sends an SMTP alert on every recovery action.

    -Register / -Unregister manage the Windows Scheduled Task that calls
    this script automatically.  Everything else is a dry-run-safe one-shot.

    Exit Codes:
      0 - Healthy / nothing to do
      1 - Recovery attempted (one or more actions taken)
      2 - Recovery failed or unrecoverable error
      3 - Insufficient privileges for -Register / -Unregister

.PARAMETER Register
    Create (or replace) the "AitherOS-DockerWatchdog" Scheduled Task that
    runs this script every IntervalMinutes minutes.  Requires elevation.

.PARAMETER Unregister
    Remove the Scheduled Task.  Requires elevation.

.PARAMETER IntervalMinutes
    How often the Scheduled Task fires.  Default: 5.

.PARAMETER DockerStartTimeoutSec
    How long to wait for Docker Desktop to become responsive after a
    forced restart.  Default: 120.

.PARAMETER ComposeFile
    Path to the Docker Compose file.  Defaults to
    <workspace-root>\docker-compose.aitheros.yml.

.PARAMETER ComposeProfile
    Compose profile to bring up when containers are missing.  Default: core.

.PARAMETER AlertTo
    Comma-separated list of recipient e-mail addresses for recovery alerts.
    If omitted, falls back to the AITHER_SMTP_USER env var (send-to-self).

.PARAMETER EnvFile
    Path to the .env file that holds SMTP credentials.
    Defaults to <workspace-root>\.env.

.PARAMETER TaskName
    Scheduled task name.  Default: AitherOS-DockerWatchdog.

.PARAMETER LogFile
    Where to write the watchdog log.
    Default: $env:TEMP\AitherOS-DockerWatchdog.log.

.PARAMETER DryRun
    Show what would happen without making any changes.

.EXAMPLE
    # One-shot health check (safe, no side-effects unless things are broken)
    .\4011_Start-DockerWatchdog.ps1

.EXAMPLE
    # Register the scheduled task (runs every 5 minutes automatically)
    .\4011_Start-DockerWatchdog.ps1 -Register

.EXAMPLE
    # Register with a 3-minute interval
    .\4011_Start-DockerWatchdog.ps1 -Register -IntervalMinutes 3

.EXAMPLE
    # Remove the scheduled task
    .\4011_Start-DockerWatchdog.ps1 -Unregister

.EXAMPLE
    # Dry-run: see what the watchdog would do right now
    .\4011_Start-DockerWatchdog.ps1 -DryRun -Verbose

.NOTES
    Stage: Lifecycle
    Order: 4011
    Dependencies: Docker Desktop, docker-compose.aitheros.yml
    Tags: docker, watchdog, recovery, cloudflare, tunnel, uptime
    AllowParallel: false
    Platform: Windows only
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Register,
    [switch]$Unregister,

    [ValidateRange(1, 60)]
    [int]$IntervalMinutes = 5,

    [ValidateRange(30, 600)]
    [int]$DockerStartTimeoutSec = 120,

    [string]$ComposeFile = "",

    [string]$ComposeProfile = "core",

    [string]$AlertTo = "",

    [string]$EnvFile = "",

    [string]$TaskName = "AitherOS-DockerWatchdog",

    [string]$LogFile = "",

    # VHDX paths Docker Desktop uses for WSL2 — auto-discovered if left empty.
    # Needed for the post-upgrade ACL-repair step.
    [string[]]$VhdxPaths = @(),

    # State file for persisting Docker version across cycles (upgrade detection).
    [string]$StateFile = "",

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0   # initialise before StrictMode can complain

# ─────────────────────────────────────────────────────────────────
# PATHS
# ─────────────────────────────────────────────────────────────────

$scriptPath     = $PSCommandPath
$scriptDir      = $PSScriptRoot
# Navigate up: 40-lifecycle → automation-scripts → library → AitherZero → workspace root
$workspaceRoot  = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent

if (-not $ComposeFile) {
    $ComposeFile = Join-Path $workspaceRoot "docker-compose.aitheros.yml"
}
if (-not $EnvFile) {
    $EnvFile = Join-Path $workspaceRoot ".env"
}
if (-not $LogFile) {
    $LogFile = Join-Path $env:TEMP "AitherOS-DockerWatchdog.log"
}
if (-not $StateFile) {
    $StateFile = Join-Path $env:TEMP "AitherOS-WatchdogState.json"
}
if ($VhdxPaths.Count -eq 0) {
    # Auto-discover all *.vhdx files under known Docker data roots
    $vhdxRoots = @(
        "D:\DockerData\wsl",
        "$env:LOCALAPPDATA\Docker\wsl",
        "$env:ProgramData\DockerDesktop\wsl"
    )
    $VhdxPaths = @(
        foreach ($root in $vhdxRoots) {
            if (Test-Path $root) {
                Get-ChildItem -Path $root -Recurse -Filter "*.vhdx" -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName
            }
        }
    )
}

$DockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"

# ─────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────

function Write-WLog {
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR","ACTION","DRY")]
        [string]$Level = "INFO"
    )
    $ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry  = "[$ts] [$Level] $Message"

    # Append to log file (don't crash watchdog if log write fails)
    try { $entry | Out-File -Append -FilePath $LogFile -Encoding utf8 } catch {}

    # Console colour
    if ($Level -ne "INFO" -or $VerbosePreference -ne 'SilentlyContinue') {
        $colour = switch ($Level) {
            "ERROR"  { "Red"     }
            "WARN"   { "Yellow"  }
            "OK"     { "Green"   }
            "ACTION" { "Cyan"    }
            "DRY"    { "Magenta" }
            default  { "Gray"    }
        }
        Write-Host $entry -ForegroundColor $colour
    }
}

# ─────────────────────────────────────────────────────────────────
# ENV FILE LOADER
# ─────────────────────────────────────────────────────────────────

function Get-EnvValue {
    param([string]$Key)
    if (-not (Test-Path $EnvFile)) { return $null }
    $line = Select-String -Path $EnvFile -Pattern "^\s*$Key\s*=" | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line.Line -split '=', 2)[1].Trim().Trim('"').Trim("'")
}

# ─────────────────────────────────────────────────────────────────
# SMTP ALERT
# ─────────────────────────────────────────────────────────────────

function Send-RecoveryAlert {
    param([string]$Subject, [string]$Body)

    $smtpHost = Get-EnvValue 'AITHER_SMTP_HOST'
    $smtpPort = Get-EnvValue 'AITHER_SMTP_PORT'
    $smtpUser = Get-EnvValue 'AITHER_SMTP_USER'
    $smtpPass = Get-EnvValue 'AITHER_SMTP_PASS'
    $smtpFrom = Get-EnvValue 'AITHER_SMTP_FROM'

    if (-not $smtpHost -or -not $smtpUser -or -not $smtpPass) {
        Write-WLog "SMTP not configured — skipping alert" "WARN"
        return
    }

    $toList = if ($AlertTo) {
        $AlertTo -split ',' | ForEach-Object { $_.Trim() }
    } else {
        @($smtpUser)
    }

    $portNum = if ($smtpPort) { [int]$smtpPort } else { 587 }
    $from    = if ($smtpFrom) { $smtpFrom } else { $smtpUser }

    try {
        $cred = [System.Management.Automation.PSCredential]::new(
            $smtpUser,
            (ConvertTo-SecureString $smtpPass -AsPlainText -Force)
        )
        $params = @{
            SmtpServer             = $smtpHost
            Port                   = $portNum
            UseSsl                 = $true
            Credential             = $cred
            From                   = $from
            To                     = $toList
            Subject                = $Subject
            Body                   = $Body
            BodyAsHtml             = $false
        }
        Send-MailMessage @params -ErrorAction Stop
        Write-WLog "Alert sent → $($toList -join ', ')" "OK"
    } catch {
        Write-WLog "Alert send failed: $($_.Exception.Message)" "WARN"
    }
}

# ─────────────────────────────────────────────────────────────────
# DOCKER HEALTH HELPERS
# ─────────────────────────────────────────────────────────────────

function Test-DockerAlive {
    # Check named pipe first (instant), then try docker info
    if (-not (Test-Path '\\.\pipe\docker_engine')) { return $false }
    try {
        $null = docker info 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Wait-DockerAlive {
    param([int]$TimeoutSec = $DockerStartTimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-WLog "Waiting up to ${TimeoutSec}s for Docker engine to become responsive…" "INFO"
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerAlive) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Restart-DockerDesktop {
    Write-WLog "Killing Docker Desktop processes…" "ACTION"
    Get-Process -Name "Docker Desktop","com.docker.backend","com.docker.proxy","dockerd" `
        -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    if (-not (Test-Path $DockerDesktopExe)) {
        Write-WLog "Docker Desktop not found at '$DockerDesktopExe'" "ERROR"
        return $false
    }

    Write-WLog "Starting Docker Desktop…" "ACTION"
    Start-Process -FilePath $DockerDesktopExe

    return (Wait-DockerAlive)
}

function Get-RunningContainerNames {
    try {
        $names = docker ps --format "{{.Names}}" 2>&1
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($names | Where-Object { $_ -match 'aither' })
    } catch { return @() }
}

function Test-CoreContainersUp {
    # Minimum viable: Pulse + Chronicle must be running (they start with any profile)
    $running = Get-RunningContainerNames
    return ($running -contains "aitheros-pulse") -and ($running -contains "aitheros-chronicle")
}

function Test-TunnelUp {
    $running = Get-RunningContainerNames
    return ($running -contains "aitheros-tunnel")
}

function Test-TunnelServing {
    <#
    .SYNOPSIS
        End-to-end probe: hit demo.aitherium.com through Cloudflare to verify
        the tunnel is actually serving traffic (not just container-running).
        Returns $true if we get a non-502/503/504/1033 response.
    #>
    $probeUrls = @("https://demo.aitherium.com", "https://blog.aitherium.com")
    foreach ($url in $probeUrls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -lt 500) {
                return $true
            }
        } catch {
            $msg = $_.Exception.Message
            # Cloudflare error pages come back as exceptions with status in body
            if ($msg -match '502|503|504|1033') {
                Write-WLog "Tunnel probe $url returned CF error: $msg" "WARN"
                continue
            }
            # Other errors (DNS, timeout) — tunnel is genuinely down
            Write-WLog "Tunnel probe $url failed: $msg" "WARN"
            continue
        }
    }
    return $false
}

function Restart-TunnelContainer {
    <#
    .SYNOPSIS
        Hard-restart the tunnel container to force fresh QUIC connections
        to Cloudflare edge. Fixes stale sessions after Docker recovery.
    #>
    param([string]$Compose)
    Write-WLog "Hard-restarting aitheros-tunnel to flush QUIC sessions…" "ACTION"
    docker restart aitheros-tunnel 2>&1 | Out-Null
    Start-Sleep -Seconds 15
    # Verify it reconnected
    $logs = docker logs aitheros-tunnel --since 20s 2>&1
    if ($logs -match 'Registered tunnel connection') {
        Write-WLog "Tunnel re-registered with Cloudflare edge ✅" "OK"
        return $true
    } else {
        Write-WLog "Tunnel may not have reconnected — check logs" "WARN"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────
# VHDX / WSL UPGRADE-RECOVERY HELPERS
# ─────────────────────────────────────────────────────────────────

function Get-DockerDesktopVersion {
    if (-not (Test-Path $DockerDesktopExe)) { return $null }
    try { return (Get-Item $DockerDesktopExe).VersionInfo.ProductVersion } catch { return $null }
}

function Get-WatchdogState {
    if (-not (Test-Path $StateFile)) { return @{} }
    try {
        $raw = Get-Content $StateFile -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json
        # Convert PSCustomObject to hashtable
        $ht = @{}
        $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        return $ht
    } catch { return @{} }
}

function Save-WatchdogState {
    param([hashtable]$State)
    try { $State | ConvertTo-Json -Depth 3 | Set-Content $StateFile -Encoding utf8 } catch {}
}

function Test-VhdxVmPermission {
    param([string]$VhdxPath)
    if (-not (Test-Path $VhdxPath)) { return $true }  # missing = not our problem
    try {
        $acl = Get-Acl -Path $VhdxPath -ErrorAction Stop
        $hasAccess = $acl.Access | Where-Object {
            $_.IdentityReference -match 'Virtual Machine' -and
            ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl)
        }
        return ($null -ne $hasAccess)
    } catch {
        Write-WLog "Cannot read ACL for '$VhdxPath': $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Repair-WslVhdxPermissions {
    [OutputType([bool])]
    param()

    if ($VhdxPaths.Count -eq 0) {
        Write-WLog "No VHDX paths found — skipping VHDX ACL repair." "WARN"
        return $false
    }

    # 1. Shut down WSL to release any file locks on the VHDXs
    Write-WLog "Shutting down WSL to release VHDX locks…" "ACTION"
    $wslOut = wsl --shutdown 2>&1
    Write-WLog "wsl --shutdown: $wslOut" "INFO"
    Start-Sleep -Seconds 5

    # Kill stray WSL host processes
    Get-Process -Name "vmmemWSL","wslhost","wsl" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # 2. Grant the Hyper-V / HCS Virtual Machine account FullControl on each VHDX
    $allOk = $true
    foreach ($vhdx in $VhdxPaths) {
        if (-not (Test-Path $vhdx)) {
            Write-WLog "VHDX not found (skip): $vhdx" "WARN"
            continue
        }
        Write-WLog "Repairing ACL: $vhdx" "ACTION"
        $icaclsOut = icacls $vhdx /grant "NT VIRTUAL MACHINE\Virtual Machines:(F)" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-WLog "icacls failed on '$vhdx' (exit $LASTEXITCODE): $icaclsOut" "ERROR"
            $allOk = $false
        } else {
            Write-WLog "ACL fixed ✅: $vhdx" "OK"
        }
    }
    return $allOk
}

# ─────────────────────────────────────────────────────────────────
# SCHEDULED TASK MANAGEMENT
# ─────────────────────────────────────────────────────────────────

function Assert-Elevation {
    $id   = [Security.Principal.WindowsIdentity]::GetCurrent()
    $prin = [Security.Principal.WindowsPrincipal]$id
    if (-not $prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning "⚠  -Register / -Unregister require elevation. Re-launching as admin…"
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath)
        foreach ($p in $PSBoundParameters.GetEnumerator()) {
            if ($p.Value -is [switch]) {
                if ($p.Value) { $argList += "-$($p.Key)" }
            } else {
                $argList += "-$($p.Key)"
                $argList += "$($p.Value)"
            }
        }
        Start-Process pwsh -ArgumentList $argList -Verb RunAs -Wait
        exit $LASTEXITCODE
    }
}

function Register-WatchdogTask {
    Assert-Elevation

    # Inline action: calls this very script (no -Register flag, just run once)
    $action = New-ScheduledTaskAction `
        -Execute  "pwsh.exe" `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$scriptPath`" -ComposeFile `"$ComposeFile`" -EnvFile `"$EnvFile`""

    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration ([TimeSpan]::MaxValue)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes ([Math]::Max(5, $IntervalMinutes * 2))) `
        -RestartCount 2 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal `
        -UserId   "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel  Highest

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-WLog "Replacing existing task '$TaskName'…" "WARN"
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if ($DryRun) {
        Write-WLog "[DRY-RUN] Would register task '$TaskName' (every ${IntervalMinutes} min)" "DRY"
        return
    }

    if ($PSCmdlet.ShouldProcess($TaskName, "Register watchdog scheduled task")) {
        $task = Register-ScheduledTask `
            -TaskName   $TaskName `
            -Trigger    $trigger `
            -Action     $action `
            -Settings   $settings `
            -Principal  $principal `
            -Description "AitherOS Docker Watchdog — auto-recovers Docker/containers every ${IntervalMinutes} min." `
            -Force

        Write-WLog "✅ Task '$TaskName' registered (every ${IntervalMinutes} min, runs as SYSTEM)" "OK"
        Write-Host ""
        Write-Host "  State    : $($task.State)" -ForegroundColor White
        Write-Host "  Log file : $LogFile"        -ForegroundColor White
        Write-Host "  To check : Get-ScheduledTaskInfo -TaskName '$TaskName' | Select-Object LastRunTime,LastTaskResult" -ForegroundColor DarkGray
        Write-Host "  To stop  : .\4011_Start-DockerWatchdog.ps1 -Unregister" -ForegroundColor DarkGray
        Write-Host ""
    }
}

function Unregister-WatchdogTask {
    Assert-Elevation
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-WLog "Task '$TaskName' does not exist — nothing to remove." "WARN"
        return
    }
    if ($DryRun) {
        Write-WLog "[DRY-RUN] Would unregister task '$TaskName'" "DRY"
        return
    }
    if ($PSCmdlet.ShouldProcess($TaskName, "Unregister watchdog scheduled task")) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-WLog "✅ Task '$TaskName' removed." "OK"
    }
}

# ─────────────────────────────────────────────────────────────────
# MAIN WATCHDOG CYCLE
# ─────────────────────────────────────────────────────────────────

function Invoke-WatchdogCycle {
    $actions   = [System.Collections.Generic.List[string]]::new()
    $exitCode  = 0

    Write-WLog "─── Watchdog cycle start ───" "INFO"

    # ── 0. VHDX ACL guard (post-upgrade E_ACCESSDENIED prevention) ────────
    $state        = Get-WatchdogState
    $lastVersion  = if ($state.ContainsKey('DockerVersion')) { $state['DockerVersion'] } else { $null }
    $currVersion  = Get-DockerDesktopVersion

    # Check whether any VHDX is already missing the HCS VM permission
    $vhdxBroken = ($VhdxPaths.Count -gt 0) -and (
        @($VhdxPaths | Where-Object { Test-Path $_ } |
          Where-Object { -not (Test-VhdxVmPermission $_) }).Count -gt 0
    )

    # Also treat a version change as a trigger (upgrade resets permissions)
    $upgradeDetected = $currVersion -and $lastVersion -and ($currVersion -ne $lastVersion)

    if ($vhdxBroken) {
        Write-WLog "⚠  VHDX missing HCS VM permission — post-upgrade E_ACCESSDENIED signature detected." "WARN"
        if ($DryRun) {
            Write-WLog "[DRY-RUN] Would repair VHDX ACLs on: $($VhdxPaths -join ', ')" "DRY"
        } elseif ($PSCmdlet.ShouldProcess("VHDX files", "Repair WSL2 ACLs")) {
            $fixed = Repair-WslVhdxPermissions
            if ($fixed) {
                Write-WLog "VHDX ACLs restored ✅" "OK"
                $actions.Add("VHDX ACLs repaired (E_ACCESSDENIED post-upgrade fix)")
                $exitCode = 1
            } else {
                Write-WLog "VHDX ACL repair failed — Docker Desktop may not start." "ERROR"
            }
        }
    } elseif ($upgradeDetected) {
        Write-WLog "Docker Desktop upgraded $lastVersion → $currVersion — pre-emptively fixing VHDX ACLs." "WARN"
        if (-not $DryRun -and $PSCmdlet.ShouldProcess("VHDX files", "Pre-emptive ACL fix after upgrade")) {
            $null = Repair-WslVhdxPermissions
            $actions.Add("VHDX ACLs pre-emptively fixed after upgrade ($lastVersion → $currVersion)")
            $exitCode = 1
        } elseif ($DryRun) {
            Write-WLog "[DRY-RUN] Would pre-emptively fix VHDX ACLs (upgrade $lastVersion → $currVersion)" "DRY"
        }
    } else {
        Write-WLog "VHDX permissions: OK ✅" "OK"
    }

    # ── 1. Docker engine alive? ────────────────────────────────
    if (-not (Test-DockerAlive)) {
        Write-WLog "Docker engine is UNRESPONSIVE — pipe missing or daemon crashed." "ERROR"

        if ($DryRun) {
            Write-WLog "[DRY-RUN] Would restart Docker Desktop and bring up --profile $ComposeProfile" "DRY"
            Write-WLog "─── Watchdog cycle end (dry-run) ───" "INFO"
            return 0
        }

        if ($PSCmdlet.ShouldProcess("Docker Desktop", "Force restart")) {
            $recovered = Restart-DockerDesktop
        } else {
            $recovered = $false
        }

        if (-not $recovered) {
            Write-WLog "Docker Desktop did not recover within ${DockerStartTimeoutSec}s — GIVING UP." "ERROR"
            Send-RecoveryAlert `
                -Subject "⛔ AitherOS CRITICAL: Docker failed to recover on $(hostname)" `
                -Body    "The Docker watchdog attempted to restart Docker Desktop but the engine did not come online within ${DockerStartTimeoutSec} seconds.`n`nTimestamp: $(Get-Date -Format 'u')`nHost: $(hostname)`nLog: $LogFile"
            return 2
        }

        Write-WLog "Docker Desktop recovered ✅ — waiting 20 s for bridge network…" "OK"
        Start-Sleep -Seconds 20
        $actions.Add("Docker Desktop restarted")
        $exitCode = 1
    } else {
        Write-WLog "Docker engine: responsive ✅" "OK"
        # Persist the current version so next cycle can detect upgrades
        $state['DockerVersion'] = $currVersion
        $state['LastHealthyTs'] = (Get-Date -Format 'u')
        Save-WatchdogState $state
    }

    # ── 2. Core containers up? ─────────────────────────────────
    if (-not (Test-CoreContainersUp)) {
        Write-WLog "Core containers are down — running: docker compose --profile $ComposeProfile up -d" "ACTION"

        if ($DryRun) {
            Write-WLog "[DRY-RUN] Would run: docker compose -f `"$ComposeFile`" --profile $ComposeProfile up -d" "DRY"
        } elseif ($PSCmdlet.ShouldProcess("docker compose", "Start --profile $ComposeProfile")) {
            $output = docker compose -f "$ComposeFile" --profile $ComposeProfile up -d 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-WLog "docker compose up failed (exit $LASTEXITCODE):`n$output" "ERROR"
                $exitCode = 2
            } else {
                Write-WLog "docker compose --profile $ComposeProfile up -d completed ✅" "OK"
                $actions.Add("Compose profile '$ComposeProfile' brought up")
                $exitCode = [Math]::Max($exitCode, 1)
                # Give containers a moment before checking tunnel
                Start-Sleep -Seconds 30
            }
        }
    } else {
        Write-WLog "Core containers: running ✅" "OK"
    }

    # ── 3. Cloudflare tunnel container up? ────────────────────
    if (-not (Test-TunnelUp)) {
        Write-WLog "aitheros-tunnel is down — restarting…" "ACTION"

        if ($DryRun) {
            Write-WLog "[DRY-RUN] Would run: docker compose -f `"$ComposeFile`" up -d aitheros-tunnel" "DRY"
        } elseif ($PSCmdlet.ShouldProcess("aitheros-tunnel", "docker compose up")) {
            $output = docker compose -f "$ComposeFile" up -d aitheros-tunnel 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-WLog "Tunnel restart failed (exit $LASTEXITCODE):`n$output" "ERROR"
                $exitCode = [Math]::Max($exitCode, 2)
            } else {
                Write-WLog "aitheros-tunnel restarted ✅" "OK"
                $actions.Add("aitheros-tunnel restarted")
                $exitCode = [Math]::Max($exitCode, 1)
            }
        }
    } else {
        Write-WLog "Cloudflare tunnel container: running ✅" "OK"
    }

    # ── 3b. Tunnel serving traffic? (detect stale QUIC sessions) ──
    if ((Test-TunnelUp) -and -not (Test-TunnelServing)) {
        Write-WLog "Tunnel container running but NOT serving (stale QUIC?) — restarting…" "ACTION"

        if ($DryRun) {
            Write-WLog "[DRY-RUN] Would restart aitheros-tunnel for stale QUIC" "DRY"
        } elseif ($PSCmdlet.ShouldProcess("aitheros-tunnel", "restart for stale QUIC")) {
            $ok = Restart-TunnelContainer -Compose $ComposeFile
            if ($ok) {
                $actions.Add("aitheros-tunnel restarted (stale QUIC flush)")
                $exitCode = [Math]::Max($exitCode, 1)
            } else {
                Write-WLog "Tunnel restart did not fix serving — may need manual intervention" "ERROR"
                $exitCode = [Math]::Max($exitCode, 2)
            }
        }
    } elseif (Test-TunnelUp) {
        Write-WLog "Tunnel end-to-end probe: serving ✅" "OK"
    }

    # ── 4. Send recovery alert if anything was fixed ──────────
    if ($actions.Count -gt 0) {
        $summary = $actions -join "`n  - "
        $host_   = hostname
        $ts_     = Get-Date -Format 'u'
        Send-RecoveryAlert `
            -Subject "✅ AitherOS Auto-Recovered on $host_" `
            -Body    "The Docker watchdog performed the following recovery actions:`n`n  - $summary`n`nTimestamp : $ts_`nHost      : $host_`nLog       : $LogFile"
    }

    Write-WLog "─── Watchdog cycle end (exit $exitCode) ───" "INFO"
    return $exitCode
}

# ─────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────

Write-WLog "AitherOS Docker Watchdog v1.0 — $(Get-Date -Format 'u')" "INFO"

if ($Register) {
    Register-WatchdogTask
    exit 0
}

if ($Unregister) {
    Unregister-WatchdogTask
    exit 0
}

if (-not $IsWindows) {
    Write-WLog "This watchdog is Windows-only (Docker Desktop + Task Scheduler)." "ERROR"
    exit 2
}

$result = Invoke-WatchdogCycle
exit $result
