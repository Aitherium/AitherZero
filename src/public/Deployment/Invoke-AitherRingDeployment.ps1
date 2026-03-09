#Requires -Version 7.0
<#
.SYNOPSIS
    Manages ring-based deployments for AitherOS.

.DESCRIPTION
    Provides functions to query ring status, promote between rings,
    rollback deployments, and view deployment history.

    Rings (progressive deployment):
    - Ring 0 (dev):     Local Docker Compose — all changes land here
    - Ring 1 (staging): demo.aitherium.com — Docker containers on remote host
    - Ring 2 (prod):    Stable release — GitHub Pages + remote backend

    Promotion paths:
    - dev → staging:  Build + push Docker images, deploy to remote host
    - staging → prod: After soak time, promote to stable release
    - dev → prod:     Goes through staging automatically (2-step)

    This module integrates with:
    - AitherWatch (health checks)
    - AitherFlow (GitHub workflow triggers)
    - Atlas (pipeline orchestration)
    - Strata (deployment history ingestion)
    - GHCR (Docker image registry)

.EXAMPLE
    Get-AitherRingStatus
    Get-AitherRingStatus -Ring staging

.EXAMPLE
    Invoke-AitherRingPromotion -From dev -To staging -Approve
    Invoke-AitherRingPromotion -From staging -To prod -Approve

.EXAMPLE
    Get-AitherRingHistory -Ring staging -Last 10

.NOTES
    Category: Deployment
    Dependencies: Docker, GitHub CLI (for prod promotion), SSH (for staging)
#>

# ═══════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════

function Get-RingConfig {
    <#
    .SYNOPSIS
        Loads the ring deployment configuration from rings.yaml.
    #>
    [CmdletBinding()]
    param()

    $configPath = Join-Path $PSScriptRoot "../../../../AitherOS/config/rings.yaml"
    if (-not (Test-Path $configPath)) {
        # Try from workspace root
        $roots = @(
            (Join-Path $env:AITHEROS_ROOT "config/rings.yaml"),
            (Join-Path (Get-Location) "AitherOS/config/rings.yaml")
        )
        foreach ($r in $roots) {
            if (Test-Path $r) { $configPath = $r; break }
        }
    }

    if (-not (Test-Path $configPath)) {
        Write-Error "Ring config not found. Expected at: AitherOS/config/rings.yaml"
        return $null
    }

    # Use PowerShell-YAML if available, otherwise parse manually
    try {
        if (Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue) {
            Import-Module powershell-yaml -ErrorAction Stop
            return Get-Content $configPath -Raw | ConvertFrom-Yaml
        }
    } catch {}

    # Fallback: return raw content for callers to parse
    return @{
        _raw = Get-Content $configPath -Raw
        _path = $configPath
    }
}


function Get-AitherRingStatus {
    <#
    .SYNOPSIS
        Shows the current status of all deployment rings or a specific ring.

    .PARAMETER Ring
        Specific ring to check: dev, staging, prod. If omitted, shows all.

    .PARAMETER Detailed
        Show detailed health check info per service.

    .EXAMPLE
        Get-AitherRingStatus
        Get-AitherRingStatus -Ring staging -Detailed
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("dev", "staging", "prod", "all")]
        [string]$Ring = "all",

        [switch]$Detailed
    )

    $rings = @()

    # ── Ring 0: Dev (local) ──
    if ($Ring -in @("all", "dev")) {
        $devStatus = @{
            Ring        = "dev"
            Name        = "Development"
            Id          = 0
            Emoji       = "🔧"
            Status      = "unknown"
            Services    = @{ Online = 0; Total = 0 }
            Veil        = "unknown"
            LastDeploy  = $null
            Endpoint    = "http://localhost:3000"
        }

        # Check Watch for service health
        try {
            $watchUrl = "http://localhost:8082/status"
            $watchData = Invoke-RestMethod -Uri $watchUrl -TimeoutSec 10 -ErrorAction Stop
            $devStatus.Services.Online = $watchData.summary.online
            $devStatus.Services.Total = $watchData.summary.total
            $devStatus.Status = if ($watchData.summary.online -gt 0) { "healthy" } else { "degraded" }
        } catch {
            $devStatus.Status = "offline"
        }

        # Check Veil
        try {
            $veilResp = Invoke-WebRequest -Uri "http://localhost:3000" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            $devStatus.Veil = if ($veilResp.StatusCode -eq 200) { "online" } else { "error" }
        } catch {
            $devStatus.Veil = "offline"
        }

        # Check last deploy from history
        $historyFile = Join-Path (Get-Location) "logs/ring-deployments.jsonl"
        if (Test-Path $historyFile) {
            $lastDev = Get-Content $historyFile | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { $_.ring -eq "dev" } | Select-Object -Last 1
            if ($lastDev) {
                $devStatus.LastDeploy = $lastDev.timestamp
            }
        }

        $rings += [PSCustomObject]$devStatus
    }

    # ── Ring 1: Staging (demo.aitherium.com Docker) ──
    if ($Ring -in @("all", "staging")) {
        $stagingStatus = @{
            Ring        = "staging"
            Name        = "Staging"
            Id          = 1
            Emoji       = "🧪"
            Status      = "unknown"
            Services    = @{ Online = "N/A"; Total = "N/A" }
            Veil        = "unknown"
            LastDeploy  = $null
            Endpoint    = "https://demo.aitherium.com"
        }

        # Check staging Veil
        try {
            $stagingResp = Invoke-WebRequest -Uri "https://demo.aitherium.com" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
            $stagingStatus.Veil = if ($stagingResp.StatusCode -eq 200) { "online" } else { "error" }
            $stagingStatus.Status = "healthy"
        } catch {
            $stagingStatus.Veil = "offline"
            $stagingStatus.Status = "offline"
        }

        # Try to get remote service count via staging API
        try {
            $stagingWatch = Invoke-RestMethod -Uri "https://demo.aitherium.com/api/watch/status" -TimeoutSec 10 -ErrorAction Stop
            $stagingStatus.Services.Online = $stagingWatch.summary.online
            $stagingStatus.Services.Total = $stagingWatch.summary.total
        } catch {
            # Staging watch may not be exposed — that's OK
        }

        # Check last staging deploy from history
        $historyFile = Join-Path (Get-Location) "logs/ring-deployments.jsonl"
        if (Test-Path $historyFile) {
            $lastStaging = Get-Content $historyFile | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { $_.ring -eq "staging" } | Select-Object -Last 1
            if ($lastStaging) {
                $stagingStatus.LastDeploy = $lastStaging.timestamp
            }
        }

        $rings += [PSCustomObject]$stagingStatus
    }

    # ── Ring 2: Prod ──
    if ($Ring -in @("all", "prod")) {
        $prodStatus = @{
            Ring        = "prod"
            Name        = "Production"
            Id          = 2
            Emoji       = "🚀"
            Status      = "unknown"
            Services    = @{ Online = "N/A"; Total = "N/A" }
            Veil        = "unknown"
            LastDeploy  = $null
            Endpoint    = "https://demo.aitherium.com"
        }

        # Check prod Veil
        try {
            $prodResp = Invoke-WebRequest -Uri "https://demo.aitherium.com" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
            $prodStatus.Veil = if ($prodResp.StatusCode -eq 200) { "online" } else { "error" }
            $prodStatus.Status = "healthy"
        } catch {
            $prodStatus.Veil = "offline"
            $prodStatus.Status = "offline"
        }

        # Check last prod deploy from history
        $historyFile = Join-Path (Get-Location) "logs/ring-deployments.jsonl"
        if (Test-Path $historyFile) {
            $lastProd = Get-Content $historyFile | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { $_.ring -eq "prod" } | Select-Object -Last 1
            if ($lastProd) {
                $prodStatus.LastDeploy = $lastProd.timestamp
            }
        }

        $rings += [PSCustomObject]$prodStatus
    }

    # ── Display ──
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║           AITHEROS RING DEPLOYMENT STATUS                ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

    foreach ($r in $rings) {
        $statusColor = switch ($r.Status) {
            "healthy"  { "Green" }
            "degraded" { "Yellow" }
            "offline"  { "Red" }
            default    { "Gray" }
        }
        $statusIcon = switch ($r.Status) {
            "healthy"  { "✓" }
            "degraded" { "⚠" }
            "offline"  { "✗" }
            default    { "?" }
        }

        Write-Host ""
        Write-Host "  $($r.Emoji) Ring $($r.Id): $($r.Name)" -ForegroundColor White
        Write-Host "  ├─ Status:   $statusIcon $($r.Status)" -ForegroundColor $statusColor
        Write-Host "  ├─ Veil:     $($r.Veil)" -ForegroundColor $(if ($r.Veil -eq "online") { "Green" } else { "Red" })

        if ($r.Ring -eq "dev") {
            Write-Host "  ├─ Services: $($r.Services.Online)/$($r.Services.Total) online" -ForegroundColor $(if ($r.Services.Online -gt 0) { "Green" } else { "Yellow" })
        }

        Write-Host "  ├─ Endpoint: $($r.Endpoint)" -ForegroundColor DarkGray
        Write-Host "  └─ Last:     $(if ($r.LastDeploy) { $r.LastDeploy } else { 'never' })" -ForegroundColor DarkGray
    }

    Write-Host ""
    return $rings
}


function Invoke-AitherRingPromotion {
    <#
    .SYNOPSIS
        Promotes a deployment from one ring to another.

    .DESCRIPTION
        Runs promotion gates (health check, tests, build validation),
        then triggers the target ring deployment.

        Promotion paths:
        - dev → staging: Builds Docker images, pushes to GHCR, deploys to remote host
        - staging → prod: Verifies staging health, triggers GitHub Pages deploy, tags release
        - dev → prod: Automatically goes through staging first (2-step promotion)

    .PARAMETER From
        Source ring (default: dev)

    .PARAMETER To
        Target ring (default: staging)

    .PARAMETER Approve
        Auto-approve the manual gate (skip interactive prompt)

    .PARAMETER SkipTests
        Skip test gate (use with caution)

    .PARAMETER SkipBuild
        Skip build validation gate

    .PARAMETER DryRun
        Show what would happen without executing

    .EXAMPLE
        Invoke-AitherRingPromotion -From dev -To staging -Approve
        Invoke-AitherRingPromotion -From staging -To prod -Approve
        Invoke-AitherRingPromotion -From dev -To prod -Approve   # 2-step
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet("dev", "staging")]
        [string]$From = "dev",

        [ValidateSet("staging", "prod")]
        [string]$To = "staging",

        [switch]$Approve,
        [switch]$SkipTests,
        [switch]$SkipBuild,
        [switch]$DryRun,
        [switch]$Force
    )

    # ── Handle dev → prod as 2-step ──
    if ($From -eq "dev" -and $To -eq "prod") {
        Write-Host "`n  ℹ dev → prod promotion goes through staging automatically." -ForegroundColor Cyan
        Write-Host "  Step 1: dev → staging" -ForegroundColor White
        Write-Host "  Step 2: staging → prod" -ForegroundColor White
        Write-Host ""

        # Step 1: dev → staging
        $step1Params = @{ From = "dev"; To = "staging" }
        if ($Approve) { $step1Params.Approve = $true }
        if ($SkipTests) { $step1Params.SkipTests = $true }
        if ($SkipBuild) { $step1Params.SkipBuild = $true }
        if ($DryRun) { $step1Params.DryRun = $true }
        if ($Force) { $step1Params.Force = $true }

        Invoke-AitherRingPromotion @step1Params
        if (-not $DryRun -and $LASTEXITCODE -ne 0) {
            Write-Host "  ✗ Step 1 failed — aborting prod promotion." -ForegroundColor Red
            return
        }

        Write-Host "`n  ═══ Step 2: staging → prod ═══`n" -ForegroundColor Magenta

        # Step 2: staging → prod
        $step2Params = @{ From = "staging"; To = "prod" }
        if ($Approve) { $step2Params.Approve = $true }
        if ($DryRun) { $step2Params.DryRun = $true }
        if ($Force) { $step2Params.Force = $true }
        # Don't skip tests/build for the prod leg

        Invoke-AitherRingPromotion @step2Params
        return
    }

    $startTime = Get-Date
    $version = if (Test-Path "VERSION") { (Get-Content "VERSION" -Raw).Trim() } else { "0.0.1" }
    $commitHash = git rev-parse --short HEAD 2>$null
    $commitMsg = git log -1 --pretty=%s 2>$null

    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║          RING PROMOTION: $($From.ToUpper()) → $($To.ToUpper())                        ║" -ForegroundColor Magenta
    Write-Host "╠═══════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
    Write-Host "║  Version:  $($version.PadRight(45))║" -ForegroundColor White
    Write-Host "║  Commit:   $("$commitHash — $commitMsg".Substring(0, [Math]::Min("$commitHash — $commitMsg".Length, 45)).PadRight(45))║" -ForegroundColor White
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

    if ($DryRun) {
        Write-Host "`n  [DRY RUN] Would execute promotion gates..." -ForegroundColor Yellow
    }

    $gates = @()
    $allPassed = $true

    # ══════════════════════════════════════════════════════════════
    # GATES (vary by promotion path)
    # ══════════════════════════════════════════════════════════════

    if ($From -eq "dev" -and $To -eq "staging") {
        # ── Gate 1: Health Check ──
        Write-Host "`n  ┌─ Gate 1: Dev Health Check" -ForegroundColor Cyan
        if (-not $DryRun) {
            try {
                $watchData = Invoke-RestMethod -Uri "http://localhost:8082/status" -TimeoutSec 15 -ErrorAction Stop
                $online = $watchData.summary.online
                $total = $watchData.summary.total
                $healthy = $online -gt 0
                Write-Host "  │  Services: $online/$total online" -ForegroundColor $(if ($healthy) { "Green" } else { "Red" })
                $gates += @{ Name = "Health Check"; Passed = $healthy; Detail = "$online/$total services" }
                if (-not $healthy) { $allPassed = $false }
            } catch {
                Write-Host "  │  Watch unavailable: $_" -ForegroundColor Red
                $gates += @{ Name = "Health Check"; Passed = $false; Detail = "Watch offline" }
                $allPassed = $false
            }
        } else {
            Write-Host "  │  [DRY RUN] Would check Watch status" -ForegroundColor Yellow
            $gates += @{ Name = "Health Check"; Passed = $true; Detail = "DRY RUN" }
        }
        Write-Host "  └─ $(if ($gates[-1].Passed) { '✓ PASSED' } else { '✗ FAILED' })" -ForegroundColor $(if ($gates[-1].Passed) { "Green" } else { "Red" })

        # ── Gate 2: Tests ──
        if (-not $SkipTests) {
            Write-Host "`n  ┌─ Gate 2: Test Suite" -ForegroundColor Cyan
            if (-not $DryRun) {
                try {
                    Push-Location "AitherOS"
                    $testResult = python -m pytest dev/tests/ --tb=line -q 2>&1
                    $testExitCode = $LASTEXITCODE
                    Pop-Location

                    $testPassed = $testExitCode -eq 0
                    Write-Host "  │  Exit code: $testExitCode" -ForegroundColor $(if ($testPassed) { "Green" } else { "Red" })
                    $gates += @{ Name = "Test Suite"; Passed = $testPassed; Detail = "pytest exit $testExitCode" }
                    if (-not $testPassed -and -not $Force) { $allPassed = $false }
                } catch {
                    Write-Host "  │  Tests failed to run: $_" -ForegroundColor Red
                    $gates += @{ Name = "Test Suite"; Passed = $false; Detail = $_.Exception.Message }
                    if (-not $Force) { $allPassed = $false }
                }
            } else {
                Write-Host "  │  [DRY RUN] Would run pytest" -ForegroundColor Yellow
                $gates += @{ Name = "Test Suite"; Passed = $true; Detail = "DRY RUN" }
            }
            Write-Host "  └─ $(if ($gates[-1].Passed) { '✓ PASSED' } else { '✗ FAILED' })" -ForegroundColor $(if ($gates[-1].Passed) { "Green" } else { "Red" })
        } else {
            Write-Host "`n  ── Gate 2: Test Suite [SKIPPED]" -ForegroundColor DarkGray
            $gates += @{ Name = "Test Suite"; Passed = $true; Detail = "SKIPPED" }
        }

        # ── Gate 3: Docker Build ──
        if (-not $SkipBuild) {
            Write-Host "`n  ┌─ Gate 3: Docker Build" -ForegroundColor Cyan
            if (-not $DryRun) {
                try {
                    Write-Host "  │  Building Docker images for staging..." -ForegroundColor Gray
                    $ringCtx = Get-AitherLiveContext
                    $buildOutput = docker compose -f $ringCtx.ComposeFile --profile core build 2>&1
                    $buildExitCode = $LASTEXITCODE
                    $buildPassed = $buildExitCode -eq 0
                    Write-Host "  │  Build exit code: $buildExitCode" -ForegroundColor $(if ($buildPassed) { "Green" } else { "Red" })
                    $gates += @{ Name = "Docker Build"; Passed = $buildPassed; Detail = "docker build exit $buildExitCode" }
                    if (-not $buildPassed) { $allPassed = $false }
                } catch {
                    Write-Host "  │  Build failed: $_" -ForegroundColor Red
                    $gates += @{ Name = "Docker Build"; Passed = $false; Detail = $_.Exception.Message }
                    $allPassed = $false
                }
            } else {
                Write-Host "  │  [DRY RUN] Would build Docker images" -ForegroundColor Yellow
                $gates += @{ Name = "Docker Build"; Passed = $true; Detail = "DRY RUN" }
            }
            Write-Host "  └─ $(if ($gates[-1].Passed) { '✓ PASSED' } else { '✗ FAILED' })" -ForegroundColor $(if ($gates[-1].Passed) { "Green" } else { "Red" })
        } else {
            Write-Host "`n  ── Gate 3: Docker Build [SKIPPED]" -ForegroundColor DarkGray
            $gates += @{ Name = "Docker Build"; Passed = $true; Detail = "SKIPPED" }
        }
    }
    elseif ($From -eq "staging" -and $To -eq "prod") {
        # ── Gate 1: Staging Health ──
        Write-Host "`n  ┌─ Gate 1: Staging Health Check" -ForegroundColor Cyan
        if (-not $DryRun) {
            try {
                $stagingResp = Invoke-WebRequest -Uri "https://demo.aitherium.com" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                $healthy = $stagingResp.StatusCode -eq 200
                Write-Host "  │  Staging HTTP: $($stagingResp.StatusCode)" -ForegroundColor $(if ($healthy) { "Green" } else { "Red" })
                $gates += @{ Name = "Staging Health"; Passed = $healthy; Detail = "HTTP $($stagingResp.StatusCode)" }
                if (-not $healthy) { $allPassed = $false }
            } catch {
                Write-Host "  │  Staging unreachable: $_" -ForegroundColor Red
                $gates += @{ Name = "Staging Health"; Passed = $false; Detail = "Unreachable" }
                $allPassed = $false
            }
        } else {
            Write-Host "  │  [DRY RUN] Would check staging health" -ForegroundColor Yellow
            $gates += @{ Name = "Staging Health"; Passed = $true; Detail = "DRY RUN" }
        }
        Write-Host "  └─ $(if ($gates[-1].Passed) { '✓ PASSED' } else { '✗ FAILED' })" -ForegroundColor $(if ($gates[-1].Passed) { "Green" } else { "Red" })

        # ── Gate 2: Smoke Tests ──
        Write-Host "`n  ┌─ Gate 2: Staging Smoke Tests" -ForegroundColor Cyan
        if (-not $DryRun) {
            $smokePassed = $true
            $smokeDetails = @()
            $smokeUrls = @(
                @{ Url = "https://demo.aitherium.com"; Name = "Veil" },
                @{ Url = "https://demo.aitherium.com/api/health"; Name = "API" }
            )
            foreach ($check in $smokeUrls) {
                try {
                    $resp = Invoke-WebRequest -Uri $check.Url -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                    Write-Host "  │  $($check.Name): ✓ HTTP $($resp.StatusCode)" -ForegroundColor Green
                    $smokeDetails += "$($check.Name)=OK"
                } catch {
                    Write-Host "  │  $($check.Name): ✗ Failed" -ForegroundColor Red
                    $smokeDetails += "$($check.Name)=FAIL"
                    $smokePassed = $false
                }
            }
            $gates += @{ Name = "Smoke Tests"; Passed = $smokePassed; Detail = ($smokeDetails -join ", ") }
            if (-not $smokePassed -and -not $Force) { $allPassed = $false }
        } else {
            Write-Host "  │  [DRY RUN] Would run smoke tests" -ForegroundColor Yellow
            $gates += @{ Name = "Smoke Tests"; Passed = $true; Detail = "DRY RUN" }
        }
        Write-Host "  └─ $(if ($gates[-1].Passed) { '✓ PASSED' } else { '✗ FAILED' })" -ForegroundColor $(if ($gates[-1].Passed) { "Green" } else { "Red" })
    }

    # ── Manual Approval Gate (always last) ──
    if (-not $Approve) {
        Write-Host "`n  ┌─ Gate: Manual Approval" -ForegroundColor Cyan
        if (-not $DryRun) {
            Write-Host "  │" -ForegroundColor Cyan
            Write-Host "  │  Gate Summary:" -ForegroundColor White
            foreach ($g in $gates) {
                $icon = if ($g.Passed) { "✓" } else { "✗" }
                $color = if ($g.Passed) { "Green" } else { "Red" }
                Write-Host "  │    $icon $($g.Name): $($g.Detail)" -ForegroundColor $color
            }
            Write-Host "  │" -ForegroundColor Cyan

            if (-not $allPassed -and -not $Force) {
                Write-Host "  │  ✗ Cannot promote — gates failed. Use -Force to override." -ForegroundColor Red
                $gates += @{ Name = "Manual Approval"; Passed = $false; Detail = "Blocked by failed gates" }
                Write-Host "  └─ ✗ BLOCKED" -ForegroundColor Red
                Write-RingHistory -Ring $To -Action "promote" -Status "blocked" -Version $version -Commit $commitHash -Gates $gates
                return
            }

            $response = Read-Host "  │  Approve promotion $($From.ToUpper()) → $($To.ToUpper())? (y/N)"
            if ($response -notin @("y", "Y", "yes")) {
                Write-Host "  └─ ✗ REJECTED" -ForegroundColor Red
                $gates += @{ Name = "Manual Approval"; Passed = $false; Detail = "User rejected" }
                Write-RingHistory -Ring $To -Action "promote" -Status "rejected" -Version $version -Commit $commitHash -Gates $gates
                return
            }
            $gates += @{ Name = "Manual Approval"; Passed = $true; Detail = "Approved" }
        }
        Write-Host "  └─ ✓ APPROVED" -ForegroundColor Green
    } else {
        $gates += @{ Name = "Manual Approval"; Passed = $true; Detail = "Auto-approved" }
    }

    # ── Pre-flight check ──
    if (-not $allPassed -and -not $Force -and -not $Approve) {
        Write-Host "`n  ✗ Promotion aborted — gates failed." -ForegroundColor Red
        Write-RingHistory -Ring $To -Action "promote" -Status "failed" -Version $version -Commit $commitHash -Gates $gates
        return
    }

    # ══════════════════════════════════════════════════════════════
    # EXECUTE PROMOTION
    # ══════════════════════════════════════════════════════════════

    Write-Host "`n  ═══ EXECUTING PROMOTION: $($From.ToUpper()) → $($To.ToUpper()) ═══" -ForegroundColor Green

    if ($To -eq "staging") {
        # ── Deploy to Staging ──
        if (-not $DryRun) {
            $tag = "ring-staging-v$version-$(Get-Date -Format 'yyyyMMdd-HHmm')"
            $commitTag = $commitHash

            # Step 1: Tag images with commit SHA
            Write-Host "  → Tagging: $tag" -ForegroundColor Gray
            git tag $tag 2>$null

            # Step 2: Push tag
            Write-Host "  → Pushing tag to origin..." -ForegroundColor Gray
            git push origin $tag 2>$null

            # Step 3: Build and push Docker images to GHCR
            $registry = "ghcr.io/aitherium"
            Write-Host "  → Building and pushing images to $registry..." -ForegroundColor Gray

            $imagesToPush = @("aitheros-veil", "aitheros-genesis")
            $pushSucceeded = $true

            foreach ($img in $imagesToPush) {
                Write-Host "    → Tagging $img → $registry/$($img):$commitTag" -ForegroundColor DarkGray
                docker tag "$($img):latest" "$registry/$($img):$commitTag" 2>$null
                docker tag "$($img):latest" "$registry/$($img):staging" 2>$null

                Write-Host "    → Pushing $registry/$($img):$commitTag" -ForegroundColor DarkGray
                $pushResult = docker push "$registry/$($img):$commitTag" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "    ⚠ Push failed for $img (may need: docker login ghcr.io)" -ForegroundColor Yellow
                    $pushSucceeded = $false
                }
                docker push "$registry/$($img):staging" 2>&1 | Out-Null
            }

            if (-not $pushSucceeded) {
                Write-Host "  ⚠ Some images failed to push. Trying remote deploy anyway..." -ForegroundColor Yellow
            }

            # Step 4: Deploy to remote host via SSH or GitHub Actions
            $deployed = $false

            # Try GitHub Actions first (preferred — no SSH key needed)
            if (Get-Command gh -ErrorAction SilentlyContinue) {
                try {
                    Write-Host "  → Triggering ring-deploy workflow for staging..." -ForegroundColor Gray
                    gh workflow run ring-deploy.yml -f target_ring=staging -f skip_tests=true 2>&1
                    $deployed = $true
                    Write-Host "    ✓ Workflow triggered via gh CLI" -ForegroundColor Green
                } catch {
                    Write-Warning "gh workflow trigger failed: $_"
                }
            }

            # Fallback: SSH deployment
            if (-not $deployed) {
                $sshKey = $env:STAGING_SSH_KEY
                $sshHost = $env:STAGING_HOST ?? "demo.aitherium.com"
                $sshUser = $env:STAGING_USER ?? "aitheros"

                if ($sshKey -and (Test-Path $sshKey)) {
                    Write-Host "  → Deploying to $sshUser@$sshHost via SSH..." -ForegroundColor Gray
                    try {
                        $sshCmd = "cd /opt/aitheros && docker compose pull && docker compose --profile core up -d"
                        ssh -i $sshKey -o StrictHostKeyChecking=no "$sshUser@$sshHost" $sshCmd 2>&1
                        $deployed = $true
                        Write-Host "    ✓ SSH deployment completed" -ForegroundColor Green
                    } catch {
                        Write-Warning "SSH deployment failed: $_"
                    }
                }
            }

            if (-not $deployed) {
                Write-Host "  ⚠ Could not deploy automatically." -ForegroundColor Yellow
                Write-Host "  → Set STAGING_HOST, STAGING_USER, STAGING_SSH_KEY env vars for SSH deploy" -ForegroundColor Yellow
                Write-Host "  → Or use: gh workflow run ring-deploy.yml -f target_ring=staging" -ForegroundColor Yellow
            }

            # Step 5: Emit Flux event
            try {
                $eventBody = @{
                    event = "ring.promoted"
                    data = @{
                        source = $From
                        target = $To
                        version = $version
                        commit = $commitHash
                        tag = $tag
                        timestamp = (Get-Date -Format "o")
                    }
                } | ConvertTo-Json -Depth 5
                Invoke-RestMethod -Uri "http://localhost:8117/api/v1/events/emit" `
                    -Method POST -ContentType "application/json" -Body $eventBody -TimeoutSec 5 -ErrorAction SilentlyContinue
            } catch {}
        } else {
            Write-Host "  [DRY RUN] Would build images, push to GHCR, deploy to staging" -ForegroundColor Yellow
        }
    }
    elseif ($To -eq "prod") {
        # ── Deploy to Prod ──
        if (-not $DryRun) {
            # Step 1: Tag the commit
            $tag = "ring-prod-v$version-$(Get-Date -Format 'yyyyMMdd-HHmm')"
            Write-Host "  → Tagging: $tag" -ForegroundColor Gray
            git tag $tag 2>$null

            # Step 2: Push tag
            Write-Host "  → Pushing tag to origin..." -ForegroundColor Gray
            git push origin $tag 2>$null

            # Step 3: Trigger GitHub Actions deploy workflow
            Write-Host "  → Triggering deploy-veil workflow..." -ForegroundColor Gray
            $triggered = $false

            if (Get-Command gh -ErrorAction SilentlyContinue) {
                try {
                    gh workflow run deploy-veil.yml -f confirm=deploy 2>&1
                    $triggered = $true
                    Write-Host "    ✓ Workflow triggered via gh CLI" -ForegroundColor Green
                } catch {
                    Write-Warning "gh CLI trigger failed, trying API..."
                }
            }

            if (-not $triggered) {
                try {
                    $body = @{
                        workflow = "deploy-veil.yml"
                        inputs = @{ confirm = "deploy" }
                    } | ConvertTo-Json
                    Invoke-RestMethod -Uri "http://localhost:8165/api/v1/workflows/dispatch" `
                        -Method POST -ContentType "application/json" -Body $body -TimeoutSec 15
                    $triggered = $true
                    Write-Host "    ✓ Workflow triggered via AitherFlow" -ForegroundColor Green
                } catch {
                    Write-Warning "AitherFlow trigger failed: $_"
                }
            }

            if (-not $triggered) {
                Write-Host "    ⚠ Could not trigger workflow automatically." -ForegroundColor Yellow
                Write-Host "    → Manual: gh workflow run deploy-veil.yml -f confirm=deploy" -ForegroundColor Yellow
            }

            # Step 4: Emit Flux event
            try {
                $eventBody = @{
                    event = "ring.promoted"
                    data = @{
                        source = $From
                        target = $To
                        version = $version
                        commit = $commitHash
                        tag = $tag
                        gates = $gates
                        timestamp = (Get-Date -Format "o")
                    }
                } | ConvertTo-Json -Depth 5
                Invoke-RestMethod -Uri "http://localhost:8117/api/v1/events/emit" `
                    -Method POST -ContentType "application/json" -Body $eventBody -TimeoutSec 5 -ErrorAction SilentlyContinue
            } catch {}
        } else {
            Write-Host "  [DRY RUN] Would tag, push, and trigger deploy-veil workflow" -ForegroundColor Yellow
        }
    }

    # Log to history
    $duration = (Get-Date) - $startTime
    Write-RingHistory -Ring $To -Action "promote" -Status "success" -Version $version -Commit $commitHash -Gates $gates -Duration $duration.TotalSeconds

    Write-Host ""
    Write-Host "  ✓ Promotion complete! ($([math]::Round($duration.TotalSeconds))s)" -ForegroundColor Green
    $targetUrl = switch ($To) {
        "staging" { "https://demo.aitherium.com" }
        "prod"    { "https://demo.aitherium.com" }
        default   { "http://localhost:3000" }
    }
    Write-Host "  → $($To.ToUpper()) endpoint: $targetUrl" -ForegroundColor White
    Write-Host ""
}


function Write-RingHistory {
    <#
    .SYNOPSIS
        Writes a deployment event to the ring history log.
    #>
    [CmdletBinding()]
    param(
        [string]$Ring,
        [string]$Action,
        [string]$Status,
        [string]$Version,
        [string]$Commit,
        [array]$Gates = @(),
        [double]$Duration = 0
    )

    $entry = @{
        timestamp = (Get-Date -Format "o")
        ring = $Ring
        action = $Action
        status = $Status
        version = $Version
        commit = $Commit
        gates = $Gates
        duration_seconds = $Duration
        user = $env:USERNAME ?? $env:USER ?? "unknown"
        machine = $env:COMPUTERNAME ?? (hostname)
    } | ConvertTo-Json -Compress -Depth 5

    $logDir = Join-Path (Get-Location) "logs"
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

    $logFile = Join-Path $logDir "ring-deployments.jsonl"
    $entry | Add-Content -Path $logFile -Encoding UTF8

    # Also ingest to Strata if available
    try {
        $strataBody = @{
            type = "deployment"
            source = "ring-deploy"
            data = ($entry | ConvertFrom-Json)
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Uri "http://localhost:8136/api/v1/ingest/deployment" `
            -Method POST -ContentType "application/json" -Body $strataBody -TimeoutSec 3 -ErrorAction SilentlyContinue
    } catch {
        # Strata may not be running
    }
}


function Get-AitherRingHistory {
    <#
    .SYNOPSIS
        Shows deployment history for a ring.

    .PARAMETER Ring
        Ring to show history for (dev, staging, prod, or all)

    .PARAMETER Last
        Number of entries to show (default: 20)

    .EXAMPLE
        Get-AitherRingHistory -Ring staging -Last 5
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("dev", "staging", "prod", "all")]
        [string]$Ring = "all",

        [int]$Last = 20
    )

    $logFile = Join-Path (Get-Location) "logs/ring-deployments.jsonl"
    if (-not (Test-Path $logFile)) {
        Write-Host "  No deployment history found." -ForegroundColor Yellow
        return @()
    }

    $entries = Get-Content $logFile | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch {}
    }

    if ($Ring -ne "all") {
        $entries = $entries | Where-Object { $_.ring -eq $Ring }
    }

    $entries = $entries | Select-Object -Last $Last

    Write-Host ""
    Write-Host "  Ring Deployment History (last $Last)" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkCyan

    foreach ($e in $entries) {
        $statusIcon = switch ($e.status) {
            "success"  { "✓" }
            "failed"   { "✗" }
            "rejected" { "⊘" }
            "blocked"  { "⊘" }
            default    { "?" }
        }
        $statusColor = switch ($e.status) {
            "success"  { "Green" }
            "failed"   { "Red" }
            "rejected" { "Yellow" }
            "blocked"  { "Yellow" }
            default    { "Gray" }
        }

        $time = if ($e.timestamp) { [datetime]::Parse($e.timestamp).ToString("yyyy-MM-dd HH:mm") } else { "?" }
        Write-Host "  $statusIcon [$time] $($e.ring.ToUpper()) — $($e.action) v$($e.version) ($($e.commit)) — $($e.status)" -ForegroundColor $statusColor
    }

    Write-Host ""
    return $entries
}


# Export handled by build.ps1
