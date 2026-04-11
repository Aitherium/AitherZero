#Requires -Version 7.0

<#
.SYNOPSIS
    Registers a Windows Task Scheduler task that wakes the PC periodically
    so AitherOS routines can run even when the machine sleeps.

.DESCRIPTION
    Creates a scheduled task "AitherOS-WakeTrigger" that:
      1. Wakes the computer from sleep at the configured interval
      2. Pings Genesis /health-check to confirm services are alive
      3. Waits for a grace period to let routines execute
      4. Optionally re-sleeps the machine after the grace window

    This ensures cron, interval, and daily routines don't miss their
    windows when the PC enters S3/S4 sleep or hibernation.

    When the PC is merely locked (screen off, not sleeping), Docker and
    the scheduler keep running — this task has no effect in that case.

    Exit Codes:
      0 - Success
      1 - Task registration failed
      2 - Insufficient privileges

.PARAMETER IntervalMinutes
    How often the task fires (and wakes the PC). Default: 30.

.PARAMETER GraceMinutes
    How long to stay awake after waking so routines can finish. Default: 15.

.PARAMETER ReSleep
    If set, puts the PC back to sleep after the grace period.
    Without this flag the PC stays awake until the user or OS sleeps it again.

.PARAMETER Unregister
    Removes the scheduled task instead of creating it.

.PARAMETER TaskName
    Name of the scheduled task. Default: "AitherOS-WakeTrigger".

.PARAMETER GenesisUrl
    Genesis health endpoint. Default: http://localhost:8001/health-check

.PARAMETER DryRun
    Show what would happen without making changes.

.EXAMPLE
    .\4008_Register-WakeTrigger.ps1
    # Register with defaults: wake every 30 min, 15 min grace, no re-sleep.

.EXAMPLE
    .\4008_Register-WakeTrigger.ps1 -IntervalMinutes 60 -ReSleep
    # Wake hourly, re-sleep after 15 min grace.

.EXAMPLE
    .\4008_Register-WakeTrigger.ps1 -Unregister
    # Remove the scheduled task.

.NOTES
    Stage: Lifecycle
    Order: 4008
    Dependencies: Docker, Genesis
    Tags: power, sleep, wake, scheduler, routines
    AllowParallel: false
    Platform: Windows only
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(5, 1440)]
    [int]$IntervalMinutes = 30,

    [ValidateRange(5, 120)]
    [int]$GraceMinutes = 15,

    [switch]$ReSleep,

    [switch]$Unregister,

    [string]$TaskName = "AitherOS-WakeTrigger",

    [string]$GenesisUrl = "http://localhost:8001/health-check",

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ── Platform guard ──────────────────────────────────────────
if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Write-Error "This script is Windows-only (Task Scheduler)."
    exit 2
}

# ── Elevation check ────────────────────────────────────────
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "⚠  Registering a wake-capable task requires elevation. Re-launching as admin…"
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
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

# ── Unregister path ────────────────────────────────────────
if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($DryRun) {
            Write-Host "[DRY-RUN] Would unregister task '$TaskName'"
        } else {
            if ($PSCmdlet.ShouldProcess($TaskName, "Unregister scheduled task")) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
                Write-Host "✅ Task '$TaskName' removed." -ForegroundColor Green
            }
        }
    } else {
        Write-Host "ℹ  Task '$TaskName' does not exist." -ForegroundColor Yellow
    }
    exit 0
}

# ── Build the inline action script ─────────────────────────
# This is the PowerShell that runs every time the task fires.
$actionScript = @"
# AitherOS Wake-Trigger Action
# Pings Genesis, waits for routines, optionally re-sleeps.

`$ErrorActionPreference = 'SilentlyContinue'
`$logFile = Join-Path `$env:TEMP 'AitherOS-WakeTrigger.log'

function Write-Log([string]`$msg) {
    `$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "`$ts  `$msg" | Out-File -Append -FilePath `$logFile -Encoding utf8
}

Write-Log '--- Wake trigger fired ---'

# 1. Wait a moment for network/Docker to come up after wake
Start-Sleep -Seconds 10

# 2. Ping Genesis
try {
    `$resp = Invoke-RestMethod -Uri '$GenesisUrl' -TimeoutSec 15
    Write-Log "Genesis health: `$(`$resp | ConvertTo-Json -Compress -Depth 2)"
} catch {
    Write-Log "Genesis unreachable: `$(`$_.Exception.Message)"
    # Try to bring Docker up
    try {
        docker start aitheros-genesis 2>`$null
        Write-Log 'Attempted docker start aitheros-genesis'
        Start-Sleep -Seconds 15
    } catch {
        Write-Log "Docker start failed: `$(`$_.Exception.Message)"
    }
}

# 3. Grace period — let scheduler loop run routines
Write-Log "Holding awake for $GraceMinutes minutes grace period…"
Start-Sleep -Seconds ($GraceMinutes * 60)

# 4. Optionally re-sleep
$(if ($ReSleep) {
@"
Write-Log 'Grace period over — re-sleeping the PC.'
rundll32.exe powrprof.dll,SetSuspendState 0,1,0
"@
} else {
    "Write-Log 'Grace period over — staying awake until next OS sleep.'"
})

Write-Log '--- Wake trigger complete ---'
"@

# ── Register the scheduled task ─────────────────────────────
Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  AitherOS Wake Trigger Registration" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Interval  : every $IntervalMinutes minutes" -ForegroundColor White
Write-Host "  Grace     : $GraceMinutes minutes" -ForegroundColor White
Write-Host "  Re-sleep  : $ReSleep" -ForegroundColor White
Write-Host "  Task name : $TaskName" -ForegroundColor White
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY-RUN] Would register task with the above settings." -ForegroundColor Yellow
    Write-Host "[DRY-RUN] Action script:`n$actionScript" -ForegroundColor DarkGray
    exit 0
}

# Remove old version if present
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  Replacing existing task…" -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Trigger: repeating interval
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

# Action: run pwsh with the inline script
$action = New-ScheduledTaskAction `
    -Execute "pwsh.exe" `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"$($actionScript -replace '"','\"')`""

# Settings: allow wake, run on battery, don't stop on idle
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -WakeToRun `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes ($GraceMinutes + 5)) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5)

# Principal: SYSTEM so it runs regardless of login state
$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

if ($PSCmdlet.ShouldProcess($TaskName, "Register wake-capable scheduled task")) {
    $task = Register-ScheduledTask `
        -TaskName  $TaskName `
        -Trigger   $trigger `
        -Action    $action `
        -Settings  $settings `
        -Principal $principal `
        -Description "Wakes the PC every $IntervalMinutes min so AitherOS routines can execute. Grace: $GraceMinutes min. Re-sleep: $ReSleep." `
        -Force

    Write-Host ""
    Write-Host "✅ Task '$TaskName' registered successfully." -ForegroundColor Green
    Write-Host ""
    Write-Host "  State    : $($task.State)" -ForegroundColor White
    Write-Host "  Next run : $($task.Triggers[0].StartBoundary)" -ForegroundColor White
    Write-Host "  Log file : $env:TEMP\AitherOS-WakeTrigger.log" -ForegroundColor White
    Write-Host ""
    Write-Host "  To remove: .\4008_Register-WakeTrigger.ps1 -Unregister" -ForegroundColor DarkGray
    Write-Host "  To check : Get-ScheduledTask -TaskName '$TaskName' | Format-List" -ForegroundColor DarkGray
    Write-Host ""
}

exit 0
