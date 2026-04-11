#Requires -Version 7.0
<#
.SYNOPSIS
    Pulls images from GHCR and performs rolling restart of AitherOS services.

.DESCRIPTION
    Core CD script for the self-hosted runner pipeline. Pulls updated Docker
    images from GitHub Container Registry, performs rolling restarts with
    health validation, and rolls back on failure.

.PARAMETER Tag
    Image tag to pull. Default: "latest"

.PARAMETER Services
    Comma-separated services to update. Default: "genesis,veil"
    Use "all" to update all 40+ mapped services.
    Key services: genesis, veil, microscheduler, node, pulse, watch, mind,
    faculties, nexus, workingmemory, atlas, saga, demiurge, and more.
    For bulk image pulls without rolling restart, use Pull-AitherImages.ps1.

.PARAMETER Registry
    GHCR registry prefix. Default: "ghcr.io/aitherium"

.PARAMETER Profile
    Docker Compose profile. Default: "all"

.PARAMETER HealthCheckTimeout
    Seconds to wait for health checks. Default: 120

.PARAMETER RollingRestart
    Update one service at a time. Default: $true

.PARAMETER DryRun
    Preview mode — show what would happen without executing.

.PARAMETER NonInteractive
    Skip confirmation prompts.

.EXAMPLE
    .\3050_Deploy-FromGHCR.ps1 -Tag "latest" -Services "genesis,veil"
    .\3050_Deploy-FromGHCR.ps1 -Tag "sha-abc1234" -Services "genesis" -DryRun
    .\3050_Deploy-FromGHCR.ps1 -Services "all" -NonInteractive

.NOTES
    Category: deploy
    Dependencies: Docker, GHCR authentication
    Platform: Windows, Linux
#>

[CmdletBinding()]
param(
    [string]$Tag = "latest",
    [string]$Services = "genesis,veil",
    [string]$Registry = "ghcr.io/aitherium",
    [string]$Profile = "all",
    [int]$HealthCheckTimeout = 120,
    [switch]$RollingRestart = $true,
    [switch]$DryRun,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

# Workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$composeFile = Join-Path $workspaceRoot "docker-compose.aitheros.yml"
$logDir = Join-Path $workspaceRoot "logs"
$lockFile = Join-Path $logDir "deploy.lock"

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  AitherOS CD — Pull from GHCR & Rolling Restart" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# SERVICE → IMAGE MAPPING
# =============================================================================
# Maps docker-compose service names to GHCR image names and local image names.
# Local image name is what docker-compose.aitheros.yml expects.
# For full bulk image pulls, use Pull-AitherImages.ps1 instead.
# This script is for targeted rolling deploys of specific services.
$ServiceMap = @{
    # ── Specialized (own Dockerfiles, own GHCR images) ──────────────
    genesis          = @{ ghcr = "aitheros-genesis";         local = "aitheros-genesis";          compose = "aither-genesis" }
    veil             = @{ ghcr = "aitheros-veil";            local = "aitheros-veil";             compose = "aither-veil" }
    microscheduler   = @{ ghcr = "aitheros-microscheduler";  local = "aitheros-microscheduler";   compose = "aither-microscheduler" }
    # Agents
    atlas            = @{ ghcr = "aitheros-atlas";           local = "aitheros-atlas";            compose = "aither-atlas" }
    saga             = @{ ghcr = "aitheros-saga";            local = "aitheros-saga";             compose = "aither-saga" }
    lyra             = @{ ghcr = "aitheros-lyra";            local = "aitheros-lyra";             compose = "aither-lyra" }
    iris             = @{ ghcr = "aitheros-iris";            local = "aitheros-iris";             compose = "aither-iris" }
    vera             = @{ ghcr = "aitheros-vera";            local = "aitheros-vera";             compose = "aither-vera" }
    hera             = @{ ghcr = "aitheros-hera";            local = "aitheros-hera";             compose = "aither-hera" }
    demiurge         = @{ ghcr = "aitheros-demiurge";        local = "aitheros-demiurge";         compose = "aither-demiurge" }
    themis           = @{ ghcr = "aitheros-themis";          local = "aitheros-themis";           compose = "aither-themis" }
    'genesis-agent'  = @{ ghcr = "aitheros-genesis-agent";   local = "aitheros-genesis-agent";    compose = "aither-genesis-agent" }
    'chaos-agent'    = @{ ghcr = "aitheros-chaos-agent";     local = "aitheros-chaos-agent";      compose = "aither-chaos-agent" }
    agent            = @{ ghcr = "aitheros-agent";           local = "aitheros-agent";            compose = "aither-agent" }
    # Web apps
    'desktop-web'    = @{ ghcr = "aitheros-desktop-web";     local = "aitheros-desktop-web";      compose = "aither-desktop-web" }
    elysium          = @{ ghcr = "aitheros-elysium";         local = "aitheros-elysium";          compose = "aither-elysium" }
    admin            = @{ ghcr = "aitheros-admin";           local = "aitheros-admin";            compose = "aither-admin" }
    # ── Core layer (all share aitheros-core GHCR image) ─────────────
    node             = @{ ghcr = "aitheros-core";  local = "aitheros-core";  compose = "aither-node" }
    pulse            = @{ ghcr = "aitheros-core";  local = "aitheros-core";  compose = "aither-pulse" }
    watch            = @{ ghcr = "aitheros-core";  local = "aitheros-core";  compose = "aither-watch" }
    chronicle        = @{ ghcr = "aitheros-core";  local = "aitheros-core";  compose = "aither-chronicle" }
    strata           = @{ ghcr = "aitheros-core";  local = "aitheros-core";  compose = "aither-strata" }
    secrets          = @{ ghcr = "aitheros-core";  local = "aitheros-core";  compose = "aither-secrets" }
    directory        = @{ ghcr = "aitheros-core";  local = "aitheros-core";  compose = "aither-directory" }
    sandbox          = @{ ghcr = "aitheros-core";  local = "aitheros-core";  compose = "aither-sandbox" }
    # ── Intelligence layer ──────────────────────────────────────────
    mind             = @{ ghcr = "aitheros-intelligence";  local = "aitheros-intelligence";  compose = "aither-mind" }
    faculties        = @{ ghcr = "aitheros-intelligence";  local = "aitheros-intelligence";  compose = "aither-faculties" }
    'cognition-core' = @{ ghcr = "aitheros-intelligence";  local = "aitheros-intelligence";  compose = "aither-cognition-core" }
    'cognition-advanced' = @{ ghcr = "aitheros-intelligence";  local = "aitheros-intelligence";  compose = "aither-cognition-advanced" }
    'security-core'  = @{ ghcr = "aitheros-intelligence";  local = "aitheros-intelligence";  compose = "aither-security-core" }
    'security-defense' = @{ ghcr = "aitheros-intelligence";  local = "aitheros-intelligence";  compose = "aither-security-defense" }
    # ── Memory layer ────────────────────────────────────────────────
    workingmemory    = @{ ghcr = "aitheros-memory";  local = "aitheros-memory";  compose = "aither-workingmemory" }
    spiritmem        = @{ ghcr = "aitheros-memory";  local = "aitheros-memory";  compose = "aither-spiritmem" }
    nexus            = @{ ghcr = "aitheros-memory";  local = "aitheros-memory";  compose = "aither-nexus" }
    'memory-core'    = @{ ghcr = "aitheros-memory";  local = "aitheros-memory";  compose = "aither-memory-core" }
    # ── Perception layer ────────────────────────────────────────────
    canvas           = @{ ghcr = "aitheros-perception";  local = "aitheros-perception";  compose = "aither-canvas" }
    'perception-core' = @{ ghcr = "aitheros-perception";  local = "aitheros-perception";  compose = "aither-perception-core" }
    # ── Autonomic layer ─────────────────────────────────────────────
    'automation-core' = @{ ghcr = "aitheros-autonomic";  local = "aitheros-autonomic";  compose = "aither-automation-core" }
    compute          = @{ ghcr = "aitheros-autonomic";  local = "aitheros-autonomic";  compose = "aither-compute" }
    # ── Gateway layer ───────────────────────────────────────────────
    gateway          = @{ ghcr = "aitheros-gateway";  local = "aitheros-gateway";  compose = "aither-gateway" }
    'mesh-core'      = @{ ghcr = "aitheros-gateway";  local = "aitheros-gateway";  compose = "aither-mesh-core" }
    # ── Training layer ──────────────────────────────────────────────
    'training-pipeline' = @{ ghcr = "aitheros-training";  local = "aitheros-training";  compose = "aither-training-pipeline" }
}

# Restart order: infrastructure first, then memory/cognition, then brain, then agents, then UI
$RestartOrder = @(
    # Infrastructure
    "pulse", "chronicle", "strata", "secrets", "node", "directory", "watch",
    # Memory & Cognition
    "nexus", "workingmemory", "spiritmem", "memory-core",
    "mind", "cognition-core", "cognition-advanced",
    # Security
    "security-core", "security-defense",
    # Intelligence
    "faculties",
    # Gateway & Autonomic
    "gateway", "mesh-core", "automation-core", "compute",
    # Perception
    "perception-core", "canvas",
    # Orchestration
    "genesis", "microscheduler",
    # Agents
    "atlas", "saga", "lyra", "iris", "vera", "hera", "demiurge", "themis",
    "genesis-agent", "chaos-agent", "agent",
    # Training
    "training-pipeline",
    # Web Apps
    "admin", "desktop-web", "elysium",
    # UI last
    "veil"
)

# =============================================================================
# LOCK CHECK
# =============================================================================
if (Test-Path $lockFile) {
    $lockContent = Get-Content $lockFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($lockContent -and $lockContent.pid) {
        $lockProcess = Get-Process -Id $lockContent.pid -ErrorAction SilentlyContinue
        if ($lockProcess) {
            Write-Error "Another deployment is in progress (PID $($lockContent.pid), started $($lockContent.started)). Wait or remove $lockFile"
        }
    }
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}

# Acquire lock
@{ pid = $PID; started = (Get-Date -Format "o"); tag = $Tag; services = $Services } |
    ConvertTo-Json | Set-Content $lockFile

try {

# =============================================================================
# PHASE 1: PRE-FLIGHT
# =============================================================================
Write-Host "Phase 1: Pre-flight validation" -ForegroundColor Yellow

# Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not available"
}
$dockerInfo = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker is not running"
}
Write-Host "  Docker: OK" -ForegroundColor Green

# Compose file
if (-not (Test-Path $composeFile)) {
    Write-Error "Compose file not found: $composeFile"
}
Write-Host "  Compose: $composeFile" -ForegroundColor Green

# Parse services
$targetServices = if ($Services -eq "all") {
    $ServiceMap.Keys | Sort-Object
} else {
    $Services -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
}

# Validate service names
foreach ($svc in $targetServices) {
    if (-not $ServiceMap.ContainsKey($svc)) {
        Write-Warning "Unknown service '$svc' — skipping. Known: $($ServiceMap.Keys -join ', ')"
        $targetServices = $targetServices | Where-Object { $_ -ne $svc }
    }
}
if ($targetServices.Count -eq 0) {
    Write-Error "No valid services to deploy"
}
Write-Host "  Services: $($targetServices -join ', ')" -ForegroundColor Green
Write-Host "  Tag: $Tag" -ForegroundColor Green

# =============================================================================
# PHASE 2: CAPTURE ROLLBACK STATE
# =============================================================================
Write-Host ""
Write-Host "Phase 2: Capturing rollback state" -ForegroundColor Yellow

$rollbackManifest = @{
    timestamp = (Get-Date -Format "o")
    tag = $Tag
    services = @()
}

foreach ($svc in $targetServices) {
    $map = $ServiceMap[$svc]
    $containerName = "aitheros-$svc"
    $currentImage = docker inspect --format '{{.Config.Image}}' $containerName 2>$null
    $currentDigest = docker inspect --format '{{.Image}}' $containerName 2>$null

    $rollbackManifest.services += @{
        name = $svc
        compose_service = $map.compose
        previous_image = $currentImage
        previous_digest = $currentDigest
    }
    Write-Host "  $svc current: $currentImage" -ForegroundColor Gray
}

$rollbackPath = Join-Path $logDir "deploy-rollback-manifest.json"
$rollbackManifest | ConvertTo-Json -Depth 5 | Set-Content $rollbackPath
Write-Host "  Rollback manifest: $rollbackPath" -ForegroundColor Green

# =============================================================================
# PHASE 3: PULL IMAGES
# =============================================================================
Write-Host ""
Write-Host "Phase 3: Pulling images from GHCR" -ForegroundColor Yellow

# Deduplicate GHCR images (e.g., pulse and chronicle both use aitheros-core)
$imagesToPull = @{}
foreach ($svc in $targetServices) {
    $map = $ServiceMap[$svc]
    $ghcrImage = "$Registry/$($map.ghcr):$Tag"
    if (-not $imagesToPull.ContainsKey($ghcrImage)) {
        $imagesToPull[$ghcrImage] = $map.local
    }
}

$pullFailed = @()
foreach ($ghcrImage in $imagesToPull.Keys) {
    $localImage = $imagesToPull[$ghcrImage]
    Write-Host "  Pulling $ghcrImage ..." -NoNewline

    if ($DryRun) {
        Write-Host " [DRY RUN]" -ForegroundColor Magenta
        continue
    }

    $pullOutput = docker pull $ghcrImage 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Warning "  $pullOutput"
        $pullFailed += $ghcrImage
        continue
    }
    Write-Host " OK" -ForegroundColor Green

    # Re-tag to local image name so docker-compose picks it up
    if ($ghcrImage -ne "${localImage}:${Tag}") {
        docker tag $ghcrImage "${localImage}:latest" 2>$null
        Write-Host "    Tagged as ${localImage}:latest" -ForegroundColor Gray
    }
}

if ($pullFailed.Count -gt 0) {
    Write-Warning "Failed to pull: $($pullFailed -join ', ')"
    if ($pullFailed.Count -eq $imagesToPull.Count) {
        Write-Error "All image pulls failed. Aborting deployment."
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN complete. No services were restarted." -ForegroundColor Magenta
    return
}

# =============================================================================
# PHASE 4: ROLLING RESTART
# =============================================================================
Write-Host ""
Write-Host "Phase 4: Rolling restart" -ForegroundColor Yellow

# Order services by restart priority
$orderedServices = $RestartOrder | Where-Object { $_ -in $targetServices }
# Add any services not in the explicit order
$orderedServices += $targetServices | Where-Object { $_ -notin $orderedServices }

$restartFailed = @()
foreach ($svc in $orderedServices) {
    $map = $ServiceMap[$svc]
    $composeSvc = $map.compose

    Write-Host "  Restarting $svc ($composeSvc) ..." -NoNewline

    # Rebuild and restart via compose
    $upOutput = docker compose -f $composeFile --profile $Profile up -d --no-deps --force-recreate $composeSvc 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Warning "  $upOutput"
        $restartFailed += $svc
        continue
    }

    # Wait for health check
    $containerName = "aitheros-$svc"
    $healthy = $false
    $elapsed = 0
    $interval = 5

    while ($elapsed -lt $HealthCheckTimeout) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval

        $health = docker inspect --format '{{.State.Health.Status}}' $containerName 2>$null
        if ($health -eq "healthy") {
            $healthy = $true
            break
        }

        # No healthcheck defined — check if running
        if (-not $health -or $health -eq "") {
            $state = docker inspect --format '{{.State.Status}}' $containerName 2>$null
            if ($state -eq "running") {
                $healthy = $true
                break
            }
        }
    }

    if ($healthy) {
        Write-Host " OK (${elapsed}s)" -ForegroundColor Green
    } else {
        Write-Host " UNHEALTHY after ${HealthCheckTimeout}s" -ForegroundColor Red
        $restartFailed += $svc
    }
}

# =============================================================================
# PHASE 5: HEALTH VALIDATION
# =============================================================================
Write-Host ""
Write-Host "Phase 5: Health validation" -ForegroundColor Yellow

$healthOk = $true

# Genesis health
if ("genesis" -in $targetServices) {
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:8001/health" -TimeoutSec 10 -ErrorAction Stop
        if ($response.status -eq "healthy") {
            Write-Host "  Genesis: healthy" -ForegroundColor Green
        } else {
            Write-Host "  Genesis: $($response.status)" -ForegroundColor Red
            $healthOk = $false
        }
    } catch {
        Write-Host "  Genesis: unreachable" -ForegroundColor Red
        $healthOk = $false
    }
}

# Veil health
if ("veil" -in $targetServices) {
    try {
        $veilResponse = Invoke-WebRequest -Uri "http://localhost:3000" -TimeoutSec 10 -ErrorAction Stop
        if ($veilResponse.StatusCode -eq 200) {
            Write-Host "  Veil: healthy (HTTP 200)" -ForegroundColor Green
        } else {
            Write-Host "  Veil: HTTP $($veilResponse.StatusCode)" -ForegroundColor Red
            $healthOk = $false
        }
    } catch {
        Write-Host "  Veil: unreachable" -ForegroundColor Red
        $healthOk = $false
    }
}

# =============================================================================
# PHASE 6: ROLLBACK ON FAILURE
# =============================================================================
if ($restartFailed.Count -gt 0 -or -not $healthOk) {
    Write-Host ""
    Write-Host "DEPLOYMENT ISSUES DETECTED — Initiating rollback" -ForegroundColor Red

    foreach ($entry in $rollbackManifest.services) {
        if ($entry.name -in $restartFailed -or -not $healthOk) {
            if ($entry.previous_image) {
                Write-Host "  Rolling back $($entry.name) to $($entry.previous_image)..." -ForegroundColor Yellow
                docker compose -f $composeFile --profile $Profile up -d --no-deps $entry.compose_service 2>$null
            }
        }
    }

    # Record failure
    $deployRecord = @{
        timestamp = (Get-Date -Format "o")
        ring = "dev"
        action = "deploy"
        status = "failed"
        tag = $Tag
        services = $targetServices
        failed = $restartFailed
    }
    $deployRecord | ConvertTo-Json | Add-Content (Join-Path $logDir "ring-deployments.jsonl")

    Write-Error "Deployment failed for: $($restartFailed -join ', '). Rollback attempted."
}

# =============================================================================
# PHASE 7: RECORD SUCCESS
# =============================================================================
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "  Deployment Complete" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "  Tag:      $Tag"
Write-Host "  Services: $($targetServices -join ', ')"
Write-Host "  Registry: $Registry"
Write-Host ""

$deployRecord = @{
    timestamp = (Get-Date -Format "o")
    ring = "dev"
    action = "deploy"
    status = "success"
    tag = $Tag
    services = $targetServices
    commit = (git -C $workspaceRoot rev-parse --short HEAD 2>$null)
}
$deployRecord | ConvertTo-Json | Add-Content (Join-Path $logDir "ring-deployments.jsonl")

# Report to Strata if available
try {
    $strataPayload = @{
        session_id = "cd-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        ide = "github-actions"
        timestamp = (Get-Date -Format "o")
        summary = "CD deploy: $($targetServices -join ', ') @ $Tag"
        files_modified = @()
        key_decisions = @("Deployed tag $Tag via GHCR pull")
        outcome = "success"
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "http://localhost:8136/api/v1/ingest/ide-session" -Method POST -Body $strataPayload -ContentType "application/json" -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
} catch {
    # Strata not available — fine
}

} finally {
    # Release lock
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}
