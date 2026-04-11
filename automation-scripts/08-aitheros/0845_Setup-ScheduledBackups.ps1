<#
.SYNOPSIS
    Setup automated scheduled backups for AitherOS disaster recovery.
.DESCRIPTION
    Configures AitherRecover with a backup directory and registers a nightly
    backup schedule via AitherScheduler. Also optionally enables GitHub sync.

    This script is IDEMPOTENT - safe to run multiple times.

    Backup schedule:
    - Nightly at 03:00 local time (full backup including Strata)
    - GitHub sync every 6 hours (if GITHUB_TOKEN is configured)

    What gets backed up:
    - Library/Data (conversations, sessions, codegraph)
    - Library/Training (training data, chronicle traces)
    - Library/Results (benchmark results)
    - Secrets vault (encrypted)
    - Config/personas
    - Strata tiered storage (hot/warm/cold)
.PARAMETER BackupDir
    Path to backup directory. Defaults to $env:AITHER_BACKUP_DIR or data/backups.
.PARAMETER SkipScheduler
    Skip registering with AitherScheduler (just configure backup dir).
.PARAMETER Force
    Re-register schedules even if they already exist.
.EXAMPLE
    Invoke-AitherScript 0845
    Invoke-AitherScript 0845 -BackupDir "E:/AitherBackups"
#>

[CmdletBinding()]
param(
    [string]$BackupDir,
    [switch]$SkipScheduler,
    [switch]$Force
)

# Import AitherZero helpers
$scriptRoot = $PSScriptRoot
$helperPath = Join-Path (Split-Path $scriptRoot -Parent) "AitherZero.psm1"
if (Test-Path $helperPath) {
    Import-Module $helperPath -Force -ErrorAction SilentlyContinue
}

Write-Host "`n" -NoNewline
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║            Setup Scheduled Backups                           ║" -ForegroundColor Cyan
Write-Host "║            Disaster Recovery Automation                      ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ==========================================================================
# 1. DETERMINE BACKUP DIRECTORY
# ==========================================================================

$aitherzeroRoot = $env:AITHERZERO_ROOT
if (-not $aitherzeroRoot) {
    $aitherzeroRoot = Split-Path (Split-Path (Split-Path $scriptRoot -Parent) -Parent) -Parent
}

if (-not $BackupDir) {
    $BackupDir = $env:AITHER_BACKUP_DIR
}
if (-not $BackupDir) {
    $BackupDir = Join-Path $aitherzeroRoot "data" "backups"
}

# Ensure backup directory exists
if (-not (Test-Path $BackupDir)) {
    New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
    Write-Host "[+] Created backup directory: $BackupDir" -ForegroundColor Green
} else {
    Write-Host "[*] Backup directory exists: $BackupDir" -ForegroundColor White
}

# Persist to environment for other services
$env:AITHER_BACKUP_DIR = $BackupDir

# ==========================================================================
# 2. CONFIGURE AITHERRECOVER
# ==========================================================================

$recoverPort = 8115
$recoverUrl = "http://localhost:$recoverPort"

Write-Host "[*] Configuring AitherRecover backup directory..." -ForegroundColor White

# Check if AitherRecover is running
$recoverHealth = $false
try {
    $response = Invoke-RestMethod -Uri "$recoverUrl/health" -TimeoutSec 5 -ErrorAction SilentlyContinue
    $recoverHealth = $true
    Write-Host "[+] AitherRecover is running on port $recoverPort" -ForegroundColor Green
} catch {
    Write-Host "[!] AitherRecover not running yet (port $recoverPort) - will configure on next boot" -ForegroundColor Yellow
}

if ($recoverHealth) {
    try {
        $body = @{ path = $BackupDir } | ConvertTo-Json
        $result = Invoke-RestMethod -Uri "$recoverUrl/config/backup-dir" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 10
        Write-Host "[+] Backup directory configured: $($result.path)" -ForegroundColor Green
    } catch {
        Write-Host "[!] Failed to configure backup dir via API: $_" -ForegroundColor Yellow
        Write-Host "[*] Will be configured on service restart via AITHER_BACKUP_DIR env var" -ForegroundColor White
    }
}

# ==========================================================================
# 3. REGISTER SCHEDULED BACKUP WITH AITHERSCHEDULER
# ==========================================================================

if ($SkipScheduler) {
    Write-Host "[*] Skipping scheduler registration (-SkipScheduler)" -ForegroundColor White
} else {
    $schedulerPort = 8095
    $schedulerUrl = "http://localhost:$schedulerPort"

    Write-Host "[*] Registering nightly backup schedule with AitherScheduler..." -ForegroundColor White

    $schedulerHealth = $false
    try {
        $response = Invoke-RestMethod -Uri "$schedulerUrl/health" -TimeoutSec 5 -ErrorAction SilentlyContinue
        $schedulerHealth = $true
        Write-Host "[+] AitherScheduler is running on port $schedulerPort" -ForegroundColor Green
    } catch {
        Write-Host "[!] AitherScheduler not running yet - schedule will be registered on next boot" -ForegroundColor Yellow
    }

    if ($schedulerHealth) {
        # Check if schedule already exists
        $existingJobs = @()
        try {
            $existingJobs = Invoke-RestMethod -Uri "$schedulerUrl/jobs" -TimeoutSec 5 -ErrorAction SilentlyContinue
        } catch {}

        $backupJobExists = $existingJobs | Where-Object { $_.name -eq "nightly-backup" -or $_.job_id -eq "nightly-backup" }

        if ($backupJobExists -and -not $Force) {
            Write-Host "[*] Nightly backup schedule already registered (use -Force to re-register)" -ForegroundColor White
        } else {
            # Register nightly backup at 03:00
            $nightlyJob = @{
                job_id = "nightly-backup"
                name = "nightly-backup"
                description = "Nightly full backup including Strata tiered storage"
                cron = "0 3 * * *"
                action = @{
                    type = "http"
                    method = "POST"
                    url = "$recoverUrl/backup/full"
                    body = @{
                        include_strata = $true
                        include_github = $false
                    }
                }
                enabled = $true
                tags = @("backup", "disaster-recovery", "automated")
            } | ConvertTo-Json -Depth 5

            try {
                $result = Invoke-RestMethod -Uri "$schedulerUrl/jobs" -Method Post -Body $nightlyJob -ContentType "application/json" -TimeoutSec 10
                Write-Host "[+] Registered nightly backup schedule (03:00 daily)" -ForegroundColor Green
            } catch {
                Write-Host "[!] Failed to register nightly backup: $_" -ForegroundColor Yellow
            }
        }

        # Check for user backup job
        $userBackupExists = $existingJobs | Where-Object { $_.name -eq "nightly-user-backups" -or $_.job_id -eq "nightly-user-backups" }
        if ($userBackupExists -and -not $Force) {
            Write-Host "[*] Nightly user backups schedule already registered (use -Force to re-register)" -ForegroundColor White
        } else {
            # Register nightly user backups at 04:00
            $userBackupJob = @{
                job_id = "nightly-user-backups"
                name = "nightly-user-backups"
                description = "Nightly encrypted private cloud exports per user"
                cron = "0 4 * * *"
                action = @{
                    type = "http"
                    method = "POST"
                    url = "$recoverUrl/user-backup/all"
                }
                enabled = $true
                tags = @("backup", "users", "private", "automated")
            } | ConvertTo-Json -Depth 5

            try {
                $result = Invoke-RestMethod -Uri "$schedulerUrl/jobs" -Method Post -Body $userBackupJob -ContentType "application/json" -TimeoutSec 10
                Write-Host "[+] Registered nightly user backups schedule (04:00 daily)" -ForegroundColor Green
            } catch {
                Write-Host "[!] Failed to register user backups: $_" -ForegroundColor Yellow
            }
        }

        # Register GitHub sync if token available
        $githubToken = $env:GITHUB_TOKEN
        if ($githubToken) {
            $githubJobExists = $existingJobs | Where-Object { $_.name -eq "github-backup-sync" -or $_.job_id -eq "github-backup-sync" }

            if ($githubJobExists -and -not $Force) {
                Write-Host "[*] GitHub backup sync already registered" -ForegroundColor White
            } else {
                $githubJob = @{
                    job_id = "github-backup-sync"
                    name = "github-backup-sync"
                    description = "Sync critical data to GitHub backup repository"
                    cron = "0 */6 * * *"
                    action = @{
                        type = "http"
                        method = "POST"
                        url = "$recoverUrl/backup/github"
                    }
                    enabled = $true
                    tags = @("backup", "github", "offsite")
                } | ConvertTo-Json -Depth 5

                try {
                    $result = Invoke-RestMethod -Uri "$schedulerUrl/jobs" -Method Post -Body $githubJob -ContentType "application/json" -TimeoutSec 10
                    Write-Host "[+] Registered GitHub backup sync (every 6 hours)" -ForegroundColor Green
                } catch {
                    Write-Host "[!] Failed to register GitHub sync: $_" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "[*] GITHUB_TOKEN not set - GitHub sync not configured (optional)" -ForegroundColor White
        }
    }
}

# ==========================================================================
# 4. SUMMARY
# ==========================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║            Scheduled Backups Configured                      ║" -ForegroundColor Green
Write-Host "╠═══════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║  Backup Directory: $($BackupDir.PadRight(36))║" -ForegroundColor Green
Write-Host "║  System Schedule: Nightly at 03:00                           ║" -ForegroundColor Green
Write-Host "║  User Schedule: Nightly at 04:00 (Private Encrypted)         ║" -ForegroundColor Green
if ($env:GITHUB_TOKEN) {
Write-Host "║  GitHub Sync: Every 6 hours                                  ║" -ForegroundColor Green
} else {
Write-Host "║  GitHub Sync: Not configured (set GITHUB_TOKEN)              ║" -ForegroundColor Yellow
}
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║  Manual backup:                                              ║" -ForegroundColor Green
Write-Host "║    curl -X POST http://localhost:8115/backup/full             ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
