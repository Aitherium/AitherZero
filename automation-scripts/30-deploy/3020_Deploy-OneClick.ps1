#Requires -Version 7.0
<#
.SYNOPSIS
    One-click AitherOS deployment orchestrator.

.DESCRIPTION
    The master deployment script that fully automates deploying AitherOS anywhere.
    Handles the complete pipeline: dependency installation, Docker image builds,
    model provisioning, service startup, and health validation.

    This script is config.psd1 driven and playbook-orchestrated. It detects
    the current environment, installs what's missing, builds what's needed,
    and starts everything automatically.

    Deployment modes:
    - Source:  Build all containers from local source code (default)
    - Pull:   Download pre-built images from registry
    - Hybrid: Pull base images, build service layers from source

.PARAMETER Mode
    Deployment mode:
    - "source"  : Build all Docker images from source (default for dev)
    - "pull"    : Pull pre-built images from registry (fastest, requires registry access)
    - "hybrid"  : Pull base images, build service layers locally

.PARAMETER Profile
    Service profile to deploy. Controls which services start:
    - "minimal"  : 5 core services (Chronicle, Node, LLM, Veil, GenesisAgent)
    - "core"     : 16 services (default - full core stack)
    - "full"     : ALL 97 services
    - "headless" : Core without Veil dashboard
    - "gpu"      : GPU-accelerated services only
    - "agents"   : Agent services only

.PARAMETER Environment
    Target environment: "development" (default), "production"

.PARAMETER SkipDependencies
    Skip dependency installation (assume everything is already installed).

.PARAMETER SkipModels
    Skip AI model download/provisioning.

.PARAMETER SkipBuild
    Skip Docker image build (use existing images).

.PARAMETER SkipHealthCheck
    Skip post-deployment health validation.

.PARAMETER ConfigOverrides
    Hashtable of config.psd1 overrides. Example:
    @{ 'AI.Ollama.DefaultModel' = 'llama3.2'; 'Services.Genesis.Port' = 9001 }

.PARAMETER DryRun
    Show what would be done without executing anything.

.PARAMETER Force
    Force rebuild/reinstall even if already present.

.PARAMETER NonInteractive
    Suppress all prompts (auto-accept defaults). Automatically set in CI.

.EXAMPLE
    # Deploy everything from source (default)
    .\3020_Deploy-OneClick.ps1

.EXAMPLE
    # Minimal deployment, skip models
    .\3020_Deploy-OneClick.ps1 -Profile minimal -SkipModels

.EXAMPLE
    # Production deploy from pre-built images
    .\3020_Deploy-OneClick.ps1 -Mode pull -Environment production -Profile full

.EXAMPLE
    # Dry run to see what would happen
    .\3020_Deploy-OneClick.ps1 -DryRun

.NOTES
    Category: deploy
    Dependencies: PowerShell 7+
    Platform: Windows, Linux, macOS
    Script: 3020
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("source", "pull", "hybrid")]
    [string]$Mode = "source",

    [ValidateSet("minimal", "core", "full", "headless", "gpu", "agents")]
    [string]$Profile = "core",

    [ValidateSet("development", "production")]
    [string]$Environment = "development",

    [switch]$SkipDependencies,
    [switch]$SkipModels,
    [switch]$SkipBuild,
    [switch]$SkipHealthCheck,

    [hashtable]$ConfigOverrides = @{},

    [switch]$DryRun,
    [switch]$Force,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ═══════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════

. "$PSScriptRoot/../_init.ps1"

$startTime = Get-Date
$results = @{
    Phase       = @{}
    Errors      = @()
    Warnings    = @()
    StartTime   = $startTime
    Mode        = $Mode
    Profile     = $Profile
    Environment = $Environment
}

# Auto-detect CI
if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true' -or $env:AITHEROS_NONINTERACTIVE -eq '1') {
    $NonInteractive = $true
}

# Resolve compose file
$composeFile = Join-Path $projectRoot "docker-compose.aitheros.yml"
if (-not (Test-Path $composeFile)) {
    $composeFile = Join-Path $projectRoot "docker" "docker-compose.yml"
}

# ═══════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════

function Show-DeployBanner {
    $banner = @"

╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║     █████╗ ██╗████████╗██╗  ██╗███████╗██████╗  ██████╗ ███████╗  ║
║    ██╔══██╗██║╚══██╔══╝██║  ██║██╔════╝██╔══██╗██╔═══██╗██╔════╝  ║
║    ███████║██║   ██║   ███████║█████╗  ██████╔╝██║   ██║███████╗  ║
║    ██╔══██║██║   ██║   ██╔══██║██╔══╝  ██╔══██╗██║   ██║╚════██║  ║
║    ██║  ██║██║   ██║   ██║  ██║███████╗██║  ██║╚██████╔╝███████║  ║
║    ╚═╝  ╚═╝╚═╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝  ║
║                                                                   ║
║              ONE-CLICK DEPLOYMENT ENGINE v1.0                     ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║  Mode:        $($Mode.PadRight(50))║
║  Profile:     $($Profile.PadRight(50))║
║  Environment: $($Environment.PadRight(50))║
║  Platform:    $($($IsWindows ? 'Windows' : ($IsLinux ? 'Linux' : 'macOS')).PadRight(50))║
╚═══════════════════════════════════════════════════════════════════╝

"@
    Write-Host $banner -ForegroundColor Cyan
}

if (-not $DryRun) {
    Show-DeployBanner
} else {
    Write-Host "`n[DRY RUN] Showing deployment plan without executing..." -ForegroundColor Yellow
    Show-DeployBanner
}

# ═══════════════════════════════════════════════════════════════
# PHASE 1: DEPENDENCY CHECK & INSTALL
# ═══════════════════════════════════════════════════════════════

function Invoke-Phase {
    param(
        [string]$Name,
        [string]$Description,
        [scriptblock]$Action,
        [switch]$ContinueOnError
    )

    $phaseStart = Get-Date
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "  PHASE: $Name" -ForegroundColor Cyan
    Write-Host "  $Description" -ForegroundColor Gray
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would execute: $Name" -ForegroundColor Yellow
        $results.Phase[$Name] = @{ Status = 'DryRun'; Duration = '0s' }
        return $true
    }

    try {
        & $Action
        $duration = (Get-Date) - $phaseStart
        $results.Phase[$Name] = @{ Status = 'Success'; Duration = "$([math]::Round($duration.TotalSeconds))s" }
        Write-Host "  ✓ $Name completed ($([math]::Round($duration.TotalSeconds))s)" -ForegroundColor Green
        return $true
    }
    catch {
        $duration = (Get-Date) - $phaseStart
        $results.Phase[$Name] = @{ Status = 'Failed'; Duration = "$([math]::Round($duration.TotalSeconds))s"; Error = $_.Exception.Message }
        $results.Errors += "$Name : $($_.Exception.Message)"

        if ($ContinueOnError) {
            Write-Warning "  ⚠ $Name failed (non-fatal): $($_.Exception.Message)"
            $results.Warnings += "$Name : $($_.Exception.Message)"
            return $true
        }
        else {
            Write-Host "  ✗ $Name FAILED: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# ── Phase 1: Dependencies ──────────────────────────────────────
if (-not $SkipDependencies) {
    $ok = Invoke-Phase -Name "Dependencies" -Description "Auto-detecting and installing required dependencies" -Action {
        $depScript = Join-Path $PSScriptRoot "3021_Install-Dependencies.ps1"
        if (Test-Path $depScript) {
            & $depScript -NonInteractive:$NonInteractive -Force:$Force
        }
        else {
            # Inline minimal dependency check
            Write-Host "  Checking Docker..." -ForegroundColor Gray
            if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
                throw "Docker is not installed. Please install Docker Desktop (https://docker.com/get-started) and retry."
            }
            try { docker info 2>&1 | Out-Null }
            catch { throw "Docker daemon is not running. Please start Docker Desktop and retry." }
            Write-Host "    ✓ Docker available" -ForegroundColor Green

            Write-Host "  Checking Docker Compose..." -ForegroundColor Gray
            $composeVersion = docker compose version 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Docker Compose is not available. Please update Docker Desktop."
            }
            Write-Host "    ✓ $composeVersion" -ForegroundColor Green

            # Check disk space (need at least 10GB)
            if ($IsWindows) {
                $drive = (Get-Item $projectRoot).PSDrive
                $freeGB = [math]::Round($drive.Free / 1GB, 1)
                if ($freeGB -lt 10) {
                    Write-Warning "Low disk space: ${freeGB}GB free (recommend 20GB+)"
                }
                else {
                    Write-Host "    ✓ Disk space: ${freeGB}GB free" -ForegroundColor Green
                }
            }
        }
    }
    if (-not $ok) { exit 1 }
}
else {
    Write-Host "`n  [SKIP] Dependencies (--SkipDependencies)" -ForegroundColor DarkGray
}

# ── Phase 2: Environment Configuration ─────────────────────────
$ok = Invoke-Phase -Name "Configuration" -Description "Setting up environment and configuration" -Action {
    # Create .env file if missing
    $envFile = Join-Path $projectRoot ".env"
    if (-not (Test-Path $envFile)) {
        Write-Host "  Creating .env from defaults..." -ForegroundColor Gray
        $envContent = @"
# AitherOS Environment Configuration
# Generated by Deploy-OneClick on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

AITHER_DOCKER_MODE=true
AITHER_ENVIRONMENT=$Environment
COMPOSE_PROFILES=$Profile
AITHER_LOG_LEVEL=$(if ($Environment -eq 'production') { 'WARNING' } else { 'INFO' })

# AI Configuration
OLLAMA_HOST=http://host.docker.internal:11434
AITHER_INFERENCE_MODE=ollama

# Security
AITHER_MASTER_KEY=$(New-Guid)

# Timezone
TZ=$([System.TimeZoneInfo]::Local.Id)
"@
        Set-Content -Path $envFile -Value $envContent -Encoding UTF8
        Write-Host "    ✓ .env created" -ForegroundColor Green
    }
    else {
        Write-Host "    ✓ .env exists" -ForegroundColor Green
    }

    # Apply config overrides
    if ($ConfigOverrides.Count -gt 0) {
        Write-Host "  Applying $($ConfigOverrides.Count) config override(s)..." -ForegroundColor Gray
        foreach ($key in $ConfigOverrides.Keys) {
            $envKey = "AITHEROS_$($key.Replace('.', '_').ToUpper())"
            [Environment]::SetEnvironmentVariable($envKey, $ConfigOverrides[$key], 'Process')
            Write-Host "    → $key = $($ConfigOverrides[$key])" -ForegroundColor DarkGray
        }
    }

    # Ensure data directories exist
    $dataDirs = @('data', 'logs', 'cache', 'data/models', 'data/embeddings', 'data/chronicle')
    foreach ($dir in $dataDirs) {
        $fullPath = Join-Path $projectRoot $dir
        if (-not (Test-Path $fullPath)) {
            New-Item -Path $fullPath -ItemType Directory -Force | Out-Null
        }
    }
    Write-Host "    ✓ Data directories ready" -ForegroundColor Green
}
if (-not $ok) { exit 1 }

# ── Phase 3: Docker Image Build ────────────────────────────────
if (-not $SkipBuild) {
    $ok = Invoke-Phase -Name "Build" -Description "Building Docker images ($Mode mode)" -ContinueOnError -Action {
        switch ($Mode) {
            "source" {
                Write-Host "  Building all images from source..." -ForegroundColor Gray
                Write-Host "  Compose file: $composeFile" -ForegroundColor DarkGray
                Write-Host "  This may take 10-30 minutes on first run..." -ForegroundColor DarkGray

                $buildArgs = @("compose", "-f", $composeFile)

                # Set profiles for build
                $env:COMPOSE_PROFILES = $Profile
                $buildArgs += @("build")

                if ($Force) { $buildArgs += "--no-cache" }
                $buildArgs += "--parallel"

                & docker @buildArgs 2>&1 | ForEach-Object {
                    if ($_ -match 'error|Error|ERROR') {
                        Write-Host "    $_" -ForegroundColor Red
                    }
                    elseif ($_ -match 'Step|CACHED|Building|built') {
                        Write-Host "    $_" -ForegroundColor DarkGray
                    }
                }

                if ($LASTEXITCODE -ne 0) {
                    throw "Docker build failed (exit code $LASTEXITCODE). Check output above."
                }
            }
            "pull" {
                Write-Host "  Pulling pre-built images from registry..." -ForegroundColor Gray
                $env:COMPOSE_PROFILES = $Profile
                & docker compose -f $composeFile pull 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Image pull failed. Check registry access."
                }
            }
            "hybrid" {
                Write-Host "  Pulling base images, building service layers..." -ForegroundColor Gray
                # Pull base images
                & docker compose -f $composeFile pull --ignore-buildable 2>&1
                # Build service layers
                $env:COMPOSE_PROFILES = $Profile
                & docker compose -f $composeFile build --parallel 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Hybrid build failed."
                }
            }
        }
    }
    if (-not $ok) { exit 1 }
}
else {
    Write-Host "`n  [SKIP] Build (--SkipBuild)" -ForegroundColor DarkGray
}

# ── Phase 4: Model Provisioning ────────────────────────────────
if (-not $SkipModels) {
    Invoke-Phase -Name "Models" -Description "Provisioning AI models" -ContinueOnError -Action {
        $modelScript = Join-Path $PSScriptRoot "3022_Provision-Models.ps1"
        if (Test-Path $modelScript) {
            & $modelScript -NonInteractive:$NonInteractive -Profile $Profile
        }
        else {
            # Inline check for Ollama
            if (Get-Command ollama -ErrorAction SilentlyContinue) {
                Write-Host "  Ollama detected, checking models..." -ForegroundColor Gray

                $installedModels = ollama list 2>&1
                $requiredModels = @('llama3.2')

                foreach ($model in $requiredModels) {
                    if ($installedModels -match $model) {
                        Write-Host "    ✓ $model already available" -ForegroundColor Green
                    }
                    else {
                        Write-Host "    ↓ Pulling $model (this may take a while)..." -ForegroundColor Yellow
                        ollama pull $model 2>&1
                    }
                }
            }
            else {
                Write-Host "  Ollama not installed - AI models will use container-bundled inference" -ForegroundColor Yellow
                Write-Host "  Install Ollama later: https://ollama.com/download" -ForegroundColor DarkGray
            }
        }
    }
}
else {
    Write-Host "`n  [SKIP] Models (--SkipModels)" -ForegroundColor DarkGray
}

# ── Phase 5: Service Startup ───────────────────────────────────
$ok = Invoke-Phase -Name "Startup" -Description "Starting AitherOS services ($Profile profile)" -Action {
    $env:COMPOSE_PROFILES = $Profile

    $upArgs = @("compose", "-f", $composeFile, "up", "-d")

    # Remove orphans from previous deployments
    $upArgs += "--remove-orphans"

    Write-Host "  Starting services..." -ForegroundColor Gray
    Write-Host "  docker $($upArgs -join ' ')" -ForegroundColor DarkGray

    & docker @upArgs 2>&1 | ForEach-Object {
        if ($_ -match 'Started|Created|Running') {
            Write-Host "    $_" -ForegroundColor Green
        }
        elseif ($_ -match 'error|Error') {
            Write-Host "    $_" -ForegroundColor Red
        }
        else {
            Write-Host "    $_" -ForegroundColor DarkGray
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Service startup failed (exit code $LASTEXITCODE)"
    }

    # Brief wait for containers to initialize
    Write-Host "  Waiting for containers to initialize..." -ForegroundColor Gray
    Start-Sleep -Seconds 5
}
if (-not $ok) { exit 1 }

# ── Phase 6: Health Validation ──────────────────────────────────
if (-not $SkipHealthCheck) {
    Invoke-Phase -Name "Health Check" -Description "Validating deployed services" -ContinueOnError -Action {
        $healthEndpoints = @{
            'Genesis'   = 'http://localhost:8001/health'
            'Veil'      = 'http://localhost:3000'
        }

        # Add profile-specific endpoints
        if ($Profile -in @('core', 'full')) {
            $healthEndpoints['Chronicle'] = 'http://localhost:8121/health'
            $healthEndpoints['LLM']       = 'http://localhost:8118/health'
            $healthEndpoints['Node']      = 'http://localhost:8090/health'
        }

        $maxRetries = 30
        $healthy = 0
        $total = $healthEndpoints.Count

        Write-Host "  Checking $total service(s)..." -ForegroundColor Gray

        foreach ($svc in $healthEndpoints.Keys) {
            $url = $healthEndpoints[$svc]
            $retries = 0
            $ok = $false

            while (-not $ok -and $retries -lt $maxRetries) {
                try {
                    $response = Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -in 200..299) {
                        Write-Host "    ✓ $svc ($url) — HTTP $($response.StatusCode)" -ForegroundColor Green
                        $ok = $true
                        $healthy++
                    }
                }
                catch {
                    $retries++
                    if ($retries % 5 -eq 0) {
                        Write-Host "    ⏳ $svc still starting... ($retries/$maxRetries)" -ForegroundColor DarkGray
                    }
                    Start-Sleep -Seconds 2
                }
            }

            if (-not $ok) {
                Write-Host "    ✗ $svc ($url) — TIMEOUT after ${maxRetries} attempts" -ForegroundColor Red
                $results.Warnings += "$svc health check timed out"
            }
        }

        Write-Host ""
        Write-Host "  Health: $healthy/$total services responding" -ForegroundColor $(if ($healthy -eq $total) { 'Green' } elseif ($healthy -gt 0) { 'Yellow' } else { 'Red' })
    }
}

# ── Phase 7: Show Running Services ─────────────────────────────
Invoke-Phase -Name "Status" -Description "Deployment summary" -ContinueOnError -Action {
    Write-Host ""
    Write-Host "  Running containers:" -ForegroundColor Gray
    docker ps --filter "name=aither" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 | ForEach-Object {
        Write-Host "    $_" -ForegroundColor White
    }
}

# ═══════════════════════════════════════════════════════════════
# FINAL REPORT
# ═══════════════════════════════════════════════════════════════

$totalDuration = (Get-Date) - $startTime
$successCount = ($results.Phase.Values | Where-Object { $_.Status -eq 'Success' }).Count
$failCount = ($results.Phase.Values | Where-Object { $_.Status -eq 'Failed' }).Count

$statusColor = if ($failCount -eq 0) { 'Green' } elseif ($failCount -lt 3) { 'Yellow' } else { 'Red' }
$statusIcon = if ($failCount -eq 0) { '✓' } else { '⚠' }

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor $statusColor
Write-Host "║         $statusIcon AITHEROS DEPLOYMENT COMPLETE                          ║" -ForegroundColor $statusColor
Write-Host "╠═══════════════════════════════════════════════════════════════════╣" -ForegroundColor $statusColor
Write-Host "║                                                                   ║" -ForegroundColor $statusColor
Write-Host "║  Duration:  $("$([math]::Round($totalDuration.TotalMinutes, 1)) minutes".PadRight(50))║" -ForegroundColor $statusColor
Write-Host "║  Phases:    $("$successCount succeeded, $failCount failed".PadRight(50))║" -ForegroundColor $statusColor
Write-Host "║  Mode:      $($Mode.PadRight(50))║" -ForegroundColor $statusColor
Write-Host "║  Profile:   $($Profile.PadRight(50))║" -ForegroundColor $statusColor
Write-Host "║                                                                   ║" -ForegroundColor $statusColor

if ($failCount -eq 0) {
    Write-Host "║  ACCESS POINTS:                                                   ║" -ForegroundColor $statusColor
    Write-Host "║  → Dashboard:    http://localhost:3000                             ║" -ForegroundColor $statusColor
    Write-Host "║  → Genesis API:  http://localhost:8001                             ║" -ForegroundColor $statusColor
    Write-Host "║  → API Docs:     http://localhost:8001/docs                        ║" -ForegroundColor $statusColor
    Write-Host "║                                                                   ║" -ForegroundColor $statusColor
    Write-Host "║  MANAGEMENT:                                                      ║" -ForegroundColor $statusColor
    Write-Host "║  → Stop:     docker compose -f docker-compose.aitheros.yml down    ║" -ForegroundColor $statusColor
    Write-Host "║  → Logs:     docker compose -f docker-compose.aitheros.yml logs -f ║" -ForegroundColor $statusColor
    Write-Host "║  → Restart:  docker compose -f docker-compose.aitheros.yml restart ║" -ForegroundColor $statusColor
}

if ($results.Warnings.Count -gt 0) {
    Write-Host "║                                                                   ║" -ForegroundColor $statusColor
    Write-Host "║  WARNINGS:                                                        ║" -ForegroundColor Yellow
    foreach ($w in $results.Warnings | Select-Object -First 5) {
        Write-Host "║  ⚠ $($w.Substring(0, [Math]::Min($w.Length, 58)).PadRight(58))║" -ForegroundColor Yellow
    }
}

Write-Host "║                                                                   ║" -ForegroundColor $statusColor
Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor $statusColor
Write-Host ""

exit $(if ($failCount -eq 0) { 0 } else { 1 })
