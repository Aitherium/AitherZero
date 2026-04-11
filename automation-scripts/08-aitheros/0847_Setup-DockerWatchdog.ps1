#Requires -Version 7.0
<#
.SYNOPSIS
    Register the Docker Daemon Watchdog as a Windows Scheduled Task.

.DESCRIPTION
    Creates a scheduled task "AitherOS-DockerWatchdog" that runs the
    0846_DockerDaemon-Watchdog.ps1 script at system startup and user logon.

    The task runs hidden in the background and auto-restarts Docker Desktop
    if the daemon crashes, then brings the AitherOS mesh back up.

    This script is IDEMPOTENT — safe to run multiple times.

.PARAMETER Profile
    Docker Compose profile passed to the watchdog. Default: "core"

.PARAMETER Uninstall
    Remove the scheduled task instead of creating it.

.PARAMETER Force
    Overwrite existing task even if it already exists.

.EXAMPLE
    .\0847_Setup-DockerWatchdog.ps1
    .\0847_Setup-DockerWatchdog.ps1 -Profile all
    .\0847_Setup-DockerWatchdog.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet("minimal", "core", "full", "all")]
    [string]$Profile = "core",

    [switch]$Uninstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$taskName = "AitherOS-DockerWatchdog"
$watchdogScript = Join-Path $PSScriptRoot "0846_DockerDaemon-Watchdog.ps1"

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     AitherOS Docker Daemon Watchdog — Task Manager           ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# UNINSTALL
# =============================================================================

if ($Uninstall) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "[+] Removed scheduled task: $taskName" -ForegroundColor Green
    } else {
        Write-Host "[*] Task '$taskName' does not exist — nothing to remove" -ForegroundColor Yellow
    }
    return
}

# =============================================================================
# VALIDATION
# =============================================================================

if (-not (Test-Path $watchdogScript)) {
    Write-Host "[!] Watchdog script not found: $watchdogScript" -ForegroundColor Red
    exit 1
}

# Check if running as admin (required for scheduled task creation)
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Host "[!] This script requires Administrator privileges to create scheduled tasks." -ForegroundColor Red
    Write-Host "    Right-click PowerShell and select 'Run as Administrator', then retry." -ForegroundColor Yellow
    exit 1
}

# =============================================================================
# CHECK EXISTING TASK
# =============================================================================

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    Write-Host "[*] Scheduled task '$taskName' already exists (use -Force to overwrite)" -ForegroundColor Yellow

    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    if ($taskInfo) {
        Write-Host "    Last run: $($taskInfo.LastRunTime)" -ForegroundColor Gray
        Write-Host "    Status:   $($existing.State)" -ForegroundColor Gray
    }
    return
}

if ($existing -and $Force) {
    Write-Host "[*] Removing existing task for re-registration..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# =============================================================================
# FIND PWSH
# =============================================================================

$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) {
    $pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
}
if (-not (Test-Path $pwshPath)) {
    Write-Host "[!] PowerShell 7 (pwsh) not found at: $pwshPath" -ForegroundColor Red
    exit 1
}

# =============================================================================
# CREATE SCHEDULED TASK
# =============================================================================

Write-Host "[*] Creating scheduled task: $taskName" -ForegroundColor White

# Build the action — run the watchdog script hidden
$arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogScript`" -Profile $Profile"
$action = New-ScheduledTaskAction -Execute $pwshPath -Argument $arguments

# Triggers: at startup + at logon
$triggerStartup = New-ScheduledTaskTrigger -AtStartup
$triggerLogon   = New-ScheduledTaskTrigger -AtLogOn

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365) `
    -MultipleInstances IgnoreNew

# Principal — run as current user with highest privileges
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -RunLevel Highest `
    -LogonType Interactive

# Register
$task = Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($triggerStartup, $triggerLogon) `
    -Settings $settings `
    -Principal $principal `
    -Description "Monitors Docker Desktop daemon health and auto-recovers the AitherOS service mesh on crash. Profile: $Profile"

Write-Host "[+] Scheduled task registered successfully!" -ForegroundColor Green

# =============================================================================
# START IT NOW
# =============================================================================

Write-Host "[*] Starting watchdog now..." -ForegroundColor White
Start-ScheduledTask -TaskName $taskName

Start-Sleep -Seconds 2
$info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
$state = (Get-ScheduledTask -TaskName $taskName).State

# =============================================================================
# SUMMARY
# =============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     Docker Watchdog Installed                                ║" -ForegroundColor Green
Write-Host "╠═══════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║  Task:     $($taskName.PadRight(44))║" -ForegroundColor Green
Write-Host "║  Profile:  $($Profile.PadRight(44))║" -ForegroundColor Green
Write-Host "║  Status:   $($state.ToString().PadRight(44))║" -ForegroundColor Green
Write-Host "║  Triggers: At startup + At logon                             ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║  When Docker Desktop crashes, the watchdog will:             ║" -ForegroundColor Green
Write-Host "║    1. Detect the dead daemon (within ~90s)                   ║" -ForegroundColor Green
Write-Host "║    2. Restart Docker Desktop automatically                   ║" -ForegroundColor Green
Write-Host "║    3. Bring the AitherOS mesh back up                        ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║  Logs: logs/docker-watchdog.log                              ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║  Manage:                                                     ║" -ForegroundColor Green
Write-Host "║    Stop:      Stop-ScheduledTask AitherOS-DockerWatchdog     ║" -ForegroundColor Green
Write-Host "║    Start:     Start-ScheduledTask AitherOS-DockerWatchdog    ║" -ForegroundColor Green
Write-Host "║    Remove:    .\0847_Setup-DockerWatchdog.ps1 -Uninstall     ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
