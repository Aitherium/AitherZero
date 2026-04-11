#Requires -Version 7.0
<#
.SYNOPSIS
    Manages ring-based deployments and promotions for AitherOS.

.DESCRIPTION
    Interactive ring deployment manager that:
    - Shows status of all rings (dev, staging, prod)
    - Runs promotion gates (health, tests, build)
    - Promotes deployments between rings (dev → staging → prod)
    - Views deployment history
    - Integrates with GitHub Actions for prod deployments
    - Integrates with GHCR for Docker image promotion

    This is the CLI entry point. For programmatic use:
    - Import-Module AitherZero; Get-AitherRingStatus
    - Or use the AitherVeil dashboard at /deployments

.PARAMETER Action
    What to do:
    - "status"  : Show ring status (default)
    - "promote" : Promote between rings
    - "history" : Show deployment history
    - "rollback": Rollback a ring to previous

.PARAMETER From
    Source ring for promotion (dev, staging). Default: dev

.PARAMETER To
    Target ring for promotion (staging, prod). Default: staging

.PARAMETER Ring
    Target ring for status/history/rollback (dev, staging, prod)

.PARAMETER Approve
    Auto-approve promotion (skip manual gate)

.PARAMETER SkipTests
    Skip test gate during promotion

.PARAMETER SkipBuild
    Skip build validation gate during promotion

.PARAMETER DryRun
    Show what would happen without executing

.PARAMETER Force
    Force action even if gates fail

.EXAMPLE
    .\3025_Ring-Deploy.ps1                                          # Show status
    .\3025_Ring-Deploy.ps1 -Action promote                          # Promote dev → staging
    .\3025_Ring-Deploy.ps1 -Action promote -To prod                 # Promote dev → staging → prod (2-step)
    .\3025_Ring-Deploy.ps1 -Action promote -From staging -To prod   # Promote staging → prod
    .\3025_Ring-Deploy.ps1 -Action promote -Approve -SkipTests      # Quick promote dev → staging
    .\3025_Ring-Deploy.ps1 -Action history -Ring staging             # Staging history

.NOTES
    Category: deploy
    Dependencies: Docker, GitHub CLI (optional), SSH (optional)
    Platform: Windows, Linux, macOS
    Script: 3025
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("status", "promote", "history", "rollback")]
    [string]$Action = "status",

    [ValidateSet("dev", "staging")]
    [string]$From = "dev",

    [ValidateSet("staging", "prod")]
    [string]$To = "staging",

    [ValidateSet("dev", "staging", "prod", "all")]
    [string]$Ring = "all",

    [switch]$Approve,
    [switch]$SkipTests,
    [switch]$SkipBuild,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ═══════════════════════════════════════════════════════════════
# INIT
# ═══════════════════════════════════════════════════════════════

. "$PSScriptRoot/../_init.ps1"

# Try to import the ring deployment module
$ringModule = Join-Path $PSScriptRoot "../../../src/public/Deployment/Invoke-AitherRingDeployment.ps1"
if (Test-Path $ringModule) {
    . $ringModule
}

# Auto-detect CI
if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true' -or $env:AITHEROS_NONINTERACTIVE -eq '1') {
    $NonInteractive = $true
    $Approve = $true
}

# ═══════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         AITHEROS RING DEPLOYMENT MANAGER                 ║" -ForegroundColor Cyan
Write-Host "╠═══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Action: $($Action.PadRight(47))║" -ForegroundColor White
if ($Action -eq "promote") {
    Write-Host "║  From:   $($From.PadRight(47))║" -ForegroundColor White
    Write-Host "║  To:     $($To.PadRight(47))║" -ForegroundColor White
} else {
    Write-Host "║  Ring:   $($Ring.PadRight(47))║" -ForegroundColor White
}
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ═══════════════════════════════════════════════════════════════
# EXECUTE
# ═══════════════════════════════════════════════════════════════

switch ($Action) {
    "status" {
        if (Get-Command Get-AitherRingStatus -ErrorAction SilentlyContinue) {
            Get-AitherRingStatus -Ring $Ring
        } else {
            # Inline status check
            Write-Host ""
            Write-Host "  Checking rings..." -ForegroundColor Gray

            # Dev ring
            if ($Ring -in @("all", "dev")) {
                Write-Host ""
                Write-Host "  🔧 Ring 0: Development (local)" -ForegroundColor White
                try {
                    $watchData = Invoke-RestMethod -Uri "http://localhost:8082/status" -TimeoutSec 10
                    Write-Host "  ├─ Status:   ✓ healthy" -ForegroundColor Green
                    Write-Host "  ├─ Services: $($watchData.summary.online)/$($watchData.summary.total) online" -ForegroundColor Green
                } catch {
                    Write-Host "  ├─ Status:   ✗ offline" -ForegroundColor Red
                }
                try {
                    Invoke-WebRequest -Uri "http://localhost:3000" -TimeoutSec 5 -UseBasicParsing | Out-Null
                    Write-Host "  ├─ Veil:     ✓ online" -ForegroundColor Green
                } catch {
                    Write-Host "  ├─ Veil:     ✗ offline" -ForegroundColor Red
                }
                Write-Host "  └─ Endpoint: http://localhost:3000" -ForegroundColor DarkGray
            }

            # Staging ring
            if ($Ring -in @("all", "staging")) {
                Write-Host ""
                Write-Host "  🧪 Ring 1: Staging (demo.aitherium.com)" -ForegroundColor White
                try {
                    $resp = Invoke-WebRequest -Uri "https://demo.aitherium.com" -TimeoutSec 15 -UseBasicParsing
                    Write-Host "  ├─ Status:   ✓ healthy (HTTP $($resp.StatusCode))" -ForegroundColor Green
                } catch {
                    Write-Host "  ├─ Status:   ✗ offline or degraded" -ForegroundColor Red
                }
                Write-Host "  └─ Endpoint: https://demo.aitherium.com" -ForegroundColor DarkGray
            }

            # Prod ring
            if ($Ring -in @("all", "prod")) {
                Write-Host ""
                Write-Host "  🚀 Ring 2: Production (stable release)" -ForegroundColor White
                try {
                    $resp = Invoke-WebRequest -Uri "https://demo.aitherium.com" -TimeoutSec 15 -UseBasicParsing
                    Write-Host "  ├─ Status:   ✓ healthy (HTTP $($resp.StatusCode))" -ForegroundColor Green
                } catch {
                    Write-Host "  ├─ Status:   ✗ offline or degraded" -ForegroundColor Red
                }
                Write-Host "  └─ Endpoint: https://demo.aitherium.com" -ForegroundColor DarkGray
            }
            Write-Host ""
        }
    }

    "promote" {
        if (Get-Command Invoke-AitherRingPromotion -ErrorAction SilentlyContinue) {
            $params = @{
                From = $From
                To = $To
            }
            if ($Approve) { $params.Approve = $true }
            if ($SkipTests) { $params.SkipTests = $true }
            if ($SkipBuild) { $params.SkipBuild = $true }
            if ($DryRun) { $params.DryRun = $true }
            if ($Force) { $params.Force = $true }

            Invoke-AitherRingPromotion @params
        } else {
            Write-Host ""
            Write-Host "  Ring promotion module not loaded." -ForegroundColor Yellow
            Write-Host "  Run: Import-Module AitherZero" -ForegroundColor Gray
            Write-Host "  Or:  . '$ringModule'" -ForegroundColor Gray
            exit 1
        }
    }

    "history" {
        if (Get-Command Get-AitherRingHistory -ErrorAction SilentlyContinue) {
            Get-AitherRingHistory -Ring $Ring -Last 20
        } else {
            $logFile = Join-Path $projectRoot "logs/ring-deployments.jsonl"
            if (Test-Path $logFile) {
                Write-Host ""
                Write-Host "  Recent Deployments:" -ForegroundColor Cyan
                Get-Content $logFile | Select-Object -Last 20 | ForEach-Object {
                    try {
                        $e = $_ | ConvertFrom-Json
                        $icon = if ($e.status -eq "success") { "✓" } else { "✗" }
                        $color = if ($e.status -eq "success") { "Green" } else { "Red" }
                        Write-Host "  $icon $($e.timestamp) | $($e.ring) | $($e.action) | v$($e.version) | $($e.status)" -ForegroundColor $color
                    } catch {}
                }
            } else {
                Write-Host "  No deployment history found." -ForegroundColor Yellow
            }
            Write-Host ""
        }
    }

    "rollback" {
        Write-Host ""
        Write-Host "  Rolling back $Ring ring..." -ForegroundColor Yellow

        if ($Ring -eq "prod") {
            # For prod, we need to re-deploy the previous GitHub Pages version
            Write-Host "  → Prod rollback requires re-running the previous deploy-veil workflow" -ForegroundColor Gray
            if (Get-Command gh -ErrorAction SilentlyContinue) {
                Write-Host "  → Listing recent deployments..." -ForegroundColor Gray
                gh run list --workflow=deploy-veil.yml --limit=5 2>&1 | ForEach-Object {
                    Write-Host "    $_" -ForegroundColor White
                }
                if (-not $DryRun) {
                    $runId = Read-Host "  Enter run ID to re-deploy (or press Enter to cancel)"
                    if ($runId) {
                        gh run rerun $runId 2>&1
                        Write-Host "  ✓ Re-running workflow $runId" -ForegroundColor Green
                    }
                }
            } else {
                Write-Host "  ⚠ GitHub CLI (gh) not available. Rollback manually:" -ForegroundColor Yellow
                Write-Host "    gh run list --workflow=deploy-veil.yml --limit=5" -ForegroundColor Gray
                Write-Host "    gh run rerun <run-id>" -ForegroundColor Gray
            }
        }
        elseif ($Ring -eq "staging") {
            # For staging, redeploy the previous staging image tag
            Write-Host "  → Rolling back staging deployment..." -ForegroundColor Gray
            $historyFile = Join-Path $projectRoot "logs/ring-deployments.jsonl"
            if (Test-Path $historyFile) {
                $prevStaging = Get-Content $historyFile | ForEach-Object {
                    try { $_ | ConvertFrom-Json } catch {}
                } | Where-Object { $_.ring -eq "staging" -and $_.status -eq "success" } | Select-Object -Last 2 | Select-Object -First 1

                if ($prevStaging) {
                    Write-Host "  → Previous successful staging deploy: v$($prevStaging.version) @ $($prevStaging.commit)" -ForegroundColor Gray
                    if (-not $DryRun) {
                        # Try to trigger ring-deploy for the previous commit
                        if (Get-Command gh -ErrorAction SilentlyContinue) {
                            gh workflow run ring-deploy.yml -f target_ring=staging 2>&1
                            Write-Host "  ✓ Staging rollback workflow triggered" -ForegroundColor Green
                        } else {
                            Write-Host "  ⚠ Use: gh workflow run ring-deploy.yml -f target_ring=staging" -ForegroundColor Yellow
                        }
                    }
                } else {
                    Write-Host "  ⚠ No previous staging deployment found in history" -ForegroundColor Yellow
                }
            }
        }
        else {
            # For dev, rollback Docker containers
            $rollbackScript = Join-Path $PSScriptRoot "../40-lifecycle/4005_Rollback-Deployment.ps1"
            if (Test-Path $rollbackScript) {
                & $rollbackScript -Confirm:$Approve
            } else {
                Write-Host "  → Restarting dev services with previous images..." -ForegroundColor Gray
                if (-not $DryRun) {
                    docker compose -f docker-compose.aitheros.yml down 2>&1 | Out-Null
                    docker compose -f docker-compose.aitheros.yml up -d 2>&1
                }
            }
        }

        Write-RingHistory -Ring $Ring -Action "rollback" -Status "success" `
            -Version (Get-Content "VERSION" -Raw).Trim() `
            -Commit (git rev-parse --short HEAD 2>$null)

        Write-Host ""
    }
}

exit 0
