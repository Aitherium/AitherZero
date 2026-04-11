#Requires -Version 7.0
<#
.SYNOPSIS
    Complete AitherOS bootstrap - cleans up, builds and starts everything on D: drive.

.DESCRIPTION
    Fully automated bootstrap that:
    1. Cleans up existing containers, volumes, networks
    2. Creates volume directories on D:\AitherOS-Data
    3. Starts Docker Desktop if needed
    4. Builds all container images
    5. Starts all services via Docker Compose
    6. Starts vLLM Multi-Model Stack with GPU support
    7. Verifies everything is running

.PARAMETER Profile
    Service profile: "minimal", "core", "full". Default: "core"

.PARAMETER SkipBuild
    Skip building images (use existing)

.PARAMETER SkipCleanup
    Skip cleanup of existing containers

.EXAMPLE
    .\0000_Bootstrap-AitherOS.ps1

.EXAMPLE
    .\0000_Bootstrap-AitherOS.ps1 -Profile full -SkipBuild

.EXAMPLE
    .\0000_Bootstrap-AitherOS.ps1 -PullFromGHCR
    # Pulls pre-built images from GHCR instead of building locally.
    # Uses docker/scripts/Pull-AitherImages.ps1 for all layers + specialized.
    # Starts with --no-build so compose uses pulled images.
#>

[CmdletBinding()]
param(
    [ValidateSet("minimal", "core", "full", "qwen")]
    [string]$Profile = "core",
    
    [switch]$SkipBuild,
    [switch]$SkipCleanup,

    # Pull pre-built images from GHCR instead of building locally
    # Uses docker/scripts/Pull-AitherImages.ps1 for layer + specialized images
    [switch]$PullFromGHCR
)

$ErrorActionPreference = 'Continue'

# Get paths
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$dockerDir = Join-Path $workspaceRoot "docker"

# Load AitherZero Configuration
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) {
    . $initScript
}

$Config = @{}
if (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue) {
    $Config = Get-AitherConfigs
}

if ($Config.Core.Profile -and $PSBoundParameters.ContainsKey('Profile') -eq $false) {
    # If a profile is set in config and no explicit flag was passed, override with config profile.
    $Profile = $Config.Core.Profile.ToLower()
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         AITHEROS COMPLETE BOOTSTRAP (D: DRIVE)                " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Workspace: $workspaceRoot" -ForegroundColor Gray
Write-Host "  Profile:   $Profile" -ForegroundColor Gray
if ($PullFromGHCR) {
    Write-Host "  Images:    GHCR (pre-built)" -ForegroundColor Green
}
Write-Host ""

# ============================================================================
# PHASE 1: START DOCKER IF NEEDED
# ============================================================================

Write-Host "[PHASE 1] Checking Docker..." -ForegroundColor Yellow

$dockerRunning = $false
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerRunning = $true }
} catch { }

if (-not $dockerRunning) {
    Write-Host "  Starting Docker Desktop..." -ForegroundColor Gray
    
    $dockerPaths = @(
        "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe"
    )
    
    foreach ($p in $dockerPaths) {
        if (Test-Path $p) {
            Start-Process -FilePath $p -WindowStyle Hidden
            break
        }
    }
    
    Write-Host "  Waiting for Docker daemon (up to 3 minutes)..." -ForegroundColor Gray
    $maxWait = 180
    $waited = 0
    
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 5
        $waited += 5
        try {
            $null = docker info 2>&1
            if ($LASTEXITCODE -eq 0) { $dockerRunning = $true; break }
        } catch { }
        if (($waited % 30) -eq 0) { Write-Host "    $waited seconds..." -ForegroundColor DarkGray }
    }
    
    if (-not $dockerRunning) {
        Write-Host "  ERROR: Docker failed to start!" -ForegroundColor Red
        exit 1
    }
}

Write-Host "  Docker is running" -ForegroundColor Green

# ============================================================================
# PHASE 1.5: GUIDED ENVIRONMENT CONFIGURATION
# ============================================================================

if (-not $NonInteractive -and -not (Test-Path "$PSScriptRoot\..\..\..\..\.env")) {
    Write-Host "`n[PHASE 1.5] Guided Environment Setup..." -ForegroundColor Cyan
    pwsh -File "$PSScriptRoot\0007_Setup-GuidedEnvironment.ps1" -Interactive
} elseif (Test-Path "$PSScriptRoot\0007_Setup-GuidedEnvironment.ps1") {
     # Always run in non-interactive mode to ensure defaults/hardware settings are refreshed
     Write-Host "`n[PHASE 1.5] Refreshing Environment Configuration..." -ForegroundColor Cyan
     pwsh -File "$PSScriptRoot\0007_Setup-GuidedEnvironment.ps1" -Interactive:$false
}

# ============================================================================
# PHASE 2: CLEANUP EXISTING RESOURCES
# ============================================================================

if (-not $SkipCleanup) {
    Write-Host "`n[PHASE 2] Cleaning up existing resources..." -ForegroundColor Yellow
    
    # Stop and remove all aitheros containers
    $containers = docker ps -aq --filter "name=aitheros" 2>$null
    if ($containers) {
        Write-Host "  Stopping containers..." -ForegroundColor Gray
        docker stop $containers 2>&1 | Out-Null
        docker rm -f $containers 2>&1 | Out-Null
    }
    
    # Remove compose project containers
    Push-Location $dockerDir
    docker compose down --remove-orphans 2>&1 | Out-Null
    Pop-Location
    
    # Remove networks
    docker network rm aitheros-net 2>&1 | Out-Null
    docker network rm aitheros_aitheros-net 2>&1 | Out-Null
    
    # Remove old volumes (compose-created ones)
    $vols = docker volume ls -q 2>$null | Where-Object { $_ -like "*aitheros*" }
    foreach ($v in $vols) { docker volume rm $v 2>&1 | Out-Null }
    
    Write-Host "  Cleanup complete" -ForegroundColor Green
} else {
    Write-Host "`n[PHASE 2] Skipping cleanup" -ForegroundColor Yellow
}

# ============================================================================
# PHASE 3: CREATE VOLUME DIRECTORIES ON D:
# ============================================================================

Write-Host "`n[PHASE 3] Creating volume directories on D: drive..." -ForegroundColor Yellow

$baseDir = "D:\AitherOS-Data\volumes"
$dirs = @(
    "$baseDir\chronicle", "$baseDir\secrets",
    "$baseDir\strata\hot", "$baseDir\strata\warm", "$baseDir\strata\cold",
    "$baseDir\mind", "$baseDir\workingmemory", "$baseDir\spirit",
    "$baseDir\veil\next", "$baseDir\veil\node_modules",
    "$baseDir\ollama\models",
    "$baseDir\comfyui\models", "$baseDir\comfyui\output", "$baseDir\comfyui\custom_nodes",
    "$baseDir\training\data", "$baseDir\training\checkpoints"
)

foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

# Create logs directory
$logsDir = Join-Path $workspaceRoot "logs"
New-Item -ItemType Directory -Path $logsDir -Force -ErrorAction SilentlyContinue | Out-Null

Write-Host "  All directories created on D:" -ForegroundColor Green

Write-Host "  Creating external Docker volumes..." -ForegroundColor Gray
# vLLM/HF cache volumes must be explicitly created since they are marked external
$requiredVolumes = @("aither-hf-cache", "aither-vllm-cache")
foreach ($vol in $requiredVolumes) {
    if (-not (docker volume ls -q | Where-Object { $_ -eq $vol })) {
        docker volume create --name $vol | Out-Null
        Write-Host "    Created volume: $vol" -ForegroundColor Green
    } else {
        Write-Host "    Volume exists: $vol" -ForegroundColor DarkGray
    }
}

# ============================================================================
# PHASE 4: BUILD IMAGES
# ============================================================================

if ($PullFromGHCR) {
    Write-Host "`n[PHASE 4] Pulling pre-built images from GHCR..." -ForegroundColor Yellow

    $pullScript = Join-Path $workspaceRoot "docker" "scripts" "Pull-AitherImages.ps1"
    if (Test-Path $pullScript) {
        & $pullScript -Layers all -IncludeSpecialized
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  All images pulled from GHCR" -ForegroundColor Green
        } else {
            Write-Host "  Some image pulls failed — services may fall back to local build" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ERROR: Pull script not found: $pullScript" -ForegroundColor Red
        Write-Host "  Falling back to local build..." -ForegroundColor Yellow
        $PullFromGHCR = $false
    }
} elseif (-not $SkipBuild) {
    Write-Host "`n[PHASE 4] Building container images..." -ForegroundColor Yellow

    # Build Genesis
    Write-Host "  Building Genesis..." -ForegroundColor Gray
    Push-Location (Join-Path $dockerDir "genesis")
    docker build -t aitheros-genesis:latest . 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    Genesis build failed - retrying with output..." -ForegroundColor Yellow
        docker build -t aitheros-genesis:latest .
    }
    Pop-Location
    Write-Host "    Genesis built" -ForegroundColor Green

    # Build base service image
    Write-Host "  Building base service image..." -ForegroundColor Gray
    Push-Location (Join-Path $dockerDir "services")
    docker build -f Dockerfile.base -t ghcr.io/aitheros/aitheros-service-base:latest . 2>&1 | Out-Null
    Pop-Location
    Write-Host "    Base service image built" -ForegroundColor Green
} else {
    Write-Host "`n[PHASE 4] Skipping builds (using existing images)" -ForegroundColor Yellow
}

if ($Profile -and $Profile -ne "") {
    if ($Profile -eq "full") {
        # 'Full' profile includes Qwen dedicated model
        $env:COMPOSE_PROFILES = "full,qwen"
    } else {
        $env:COMPOSE_PROFILES = $Profile
    }
}

Write-Host "Services profile set to: $env:COMPOSE_PROFILES" -ForegroundColor Yellow

# ============================================================================
# PHASE 4.5: MODEL PROVISIONING (Qwen 3.5 Setup)
# ============================================================================

if ($Profile -eq 'full' -or $Profile -eq 'qwen') {
    Write-Host "`n[PHASE 4.5] Provisioning AI Models (Qwen 3.5)..." -ForegroundColor Yellow
    
    $qwenScript = Join-Path $scriptDir "../50-ai-setup/5003_Setup-Qwen35-35B.ps1"
    if (Test-Path $qwenScript) {
        Write-Host "  Running Qwen setup..." -ForegroundColor Gray
        & $qwenScript
    } else {
        Write-Warning "  [WARN] Qwen setup script not found at $qwenScript"
    }
}

# ============================================================================
# PHASE 5: START SERVICES WITH DOCKER COMPOSE
# ============================================================================

Write-Host "`n[PHASE 5] Starting services with Docker Compose..." -ForegroundColor Yellow

Push-Location $workspaceRoot

# Start ALL services with docker compose
Write-Host "  Starting ALL services for profile: $Profile..." -ForegroundColor Gray

# Load secrets to environment (including CLOUDFLARE_TUNNEL_TOKEN)
$initSecretsScript = Join-Path $workspaceRoot "AitherZero/src/public/Security/Initialize-AitherSecrets.ps1"
if (Test-Path $initSecretsScript) {
    Write-Host "  Loading AitherSecrets..." -ForegroundColor Gray
    . $initSecretsScript
    Initialize-AitherSecrets -Names "CLOUDFLARE_TUNNEL_TOKEN" -Scope Process -ErrorAction SilentlyContinue | Out-Null
    
    # Write it to .env for Docker Compose
    if ($env:CLOUDFLARE_TUNNEL_TOKEN) {
        $envPath = Join-Path $workspaceRoot ".env"
        $envContent = Get-Content $envPath -Raw
        if ($envContent -match "CLOUDFLARE_TUNNEL_TOKEN=") {
            $envContent = $envContent -replace 'CLOUDFLARE_TUNNEL_TOKEN=.*', ("CLOUDFLARE_TUNNEL_TOKEN=" + $env:CLOUDFLARE_TUNNEL_TOKEN)
        } else {
            $envContent += "`nCLOUDFLARE_TUNNEL_TOKEN=" + $env:CLOUDFLARE_TUNNEL_TOKEN
        }
        $envContent | Set-Content $envPath
        Write-Host "  Injected CLOUDFLARE_TUNNEL_TOKEN into .env" -ForegroundColor Green
    }
}

# Start all services defined in docker-compose.aitheros.yml
$buildFlag = if ($PullFromGHCR) { "--no-build" } else { "--build" }
$composeCmd = "docker compose -f docker-compose.aitheros.yml --profile $Profile up -d $buildFlag"
Write-Host "  Running: $composeCmd" -ForegroundColor DarkGray

Invoke-Expression $composeCmd 2>&1 | ForEach-Object {
    if ($_ -match "error|Error|ERROR|failed|Failed") {
        Write-Host "  $_" -ForegroundColor Yellow
    }
}

Pop-Location

Write-Host "  Services starting..." -ForegroundColor Green

# ============================================================================
# PHASE 6: START MULTI-MODEL vLLM
# ============================================================================

Write-Host "`n[PHASE 6] Starting Multi-Model vLLM Stack..." -ForegroundColor Yellow

if ($Config.AI -and $Config.AI.GPU -and $Config.AI.GPU.Enabled -eq $false -or $Config.Features.AI.GPUAcceleration.Enabled -eq $false) {
    Write-Host "  Skipping vLLM Stack provisioning - GPU Acceleration is disabled in config.psd1." -ForegroundColor DarkGray
} else {
    $vllmComposeFile = Join-Path $workspaceRoot "docker-compose.vllm-multimodel.yml"

    if (Test-Path $vllmComposeFile) {
        Push-Location $workspaceRoot
        Write-Host "  Running Multi-Model vLLM workers (Orchestrator, Reasoning, Vision, Coding)..." -ForegroundColor Gray
        
        $vllmComposeCmd = "docker compose -f docker-compose.vllm-multimodel.yml up -d"
        Write-Host "  Running: $vllmComposeCmd" -ForegroundColor DarkGray
        
        Invoke-Expression $vllmComposeCmd 2>&1 | ForEach-Object {
            if ($_ -match "error|Error|ERROR|failed|Failed") {
                Write-Host "  $_" -ForegroundColor Yellow
            }
        }
        Pop-Location
        Write-Host "  Multi-Model vLLM Stack started" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ vLLM compose file not found: $vllmComposeFile" -ForegroundColor Red
    }
}

# ============================================================================
# PHASE 7: WAIT FOR SERVICES TO BE HEALTHY
# ============================================================================

Write-Host "`n[PHASE 7] Waiting for services to be healthy..." -ForegroundColor Yellow

Start-Sleep -Seconds 10

# Check Genesis health
$maxRetries = 30
$retryCount = 0
$genesisHealthy = $false

while (-not $genesisHealthy -and $retryCount -lt $maxRetries) {
    Start-Sleep -Seconds 2
    $retryCount++
    
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:8001/health" -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($health.status -eq "healthy") {
            $genesisHealthy = $true
        }
    } catch { }
}

if ($genesisHealthy) {
    Write-Host "  Genesis is healthy" -ForegroundColor Green
} else {
    Write-Host "  Genesis health check timed out" -ForegroundColor Yellow
}

# ============================================================================
# PHASE 8: SYSTEM RESILIENCE (Docker Watchdog)
# ============================================================================

Write-Host "`n[PHASE 8] Setting up system resilience..." -ForegroundColor Yellow

$watchdogScript = Join-Path $scriptDir ".." "08-aitheros" "0846_DockerDaemon-Watchdog.ps1"
$watchdogSetup = Join-Path $scriptDir ".." "08-aitheros" "0847_Setup-DockerWatchdog.ps1"

if (Test-Path $watchdogSetup) {
    # Check if running as admin (required for scheduled task creation)
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    
    if ($isAdmin) {
        $existingTask = Get-ScheduledTask -TaskName "AitherOS-DockerWatchdog" -ErrorAction SilentlyContinue
        if (-not $existingTask) {
            Write-Host "  Registering Docker Daemon Watchdog scheduled task..." -ForegroundColor Gray
            try {
                & $watchdogSetup -Profile $Profile
                Write-Host "  Docker Watchdog installed (auto-recovers on daemon crash)" -ForegroundColor Green
            } catch {
                Write-Host "  Failed to install watchdog task: $_" -ForegroundColor Yellow
                Write-Host "  Run manually: .\0847_Setup-DockerWatchdog.ps1" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Docker Watchdog already registered" -ForegroundColor Green
        }
    } else {
        Write-Host "  Skipping watchdog setup (not running as admin)" -ForegroundColor Yellow
        Write-Host "  To enable: Run 0847_Setup-DockerWatchdog.ps1 as admin" -ForegroundColor Gray
    }
} else {
    Write-Host "  Watchdog script not found — skipping" -ForegroundColor Yellow
}

# ============================================================================
# PHASE 9: SHOW STATUS
# ============================================================================

Write-Host "`n[PHASE 9] Final Status" -ForegroundColor Yellow
Write-Host ""

# Show running containers
Write-Host "Running containers:" -ForegroundColor Cyan
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 | Select-Object -First 20

# Show disk usage
Write-Host ""
Write-Host "Disk space:" -ForegroundColor Cyan
try {
    $c = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
    $d = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
    if ($c) { Write-Host "  C: $([math]::Round($c.SizeRemaining / 1GB, 1)) GB free" }
    if ($d) { Write-Host "  D: $([math]::Round($d.SizeRemaining / 1GB, 1)) GB free" }
} catch { }

# ============================================================================
# SUCCESS
# ============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "              BOOTSTRAP COMPLETE!                              " -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Genesis Dashboard: http://localhost:8001/dashboard" -ForegroundColor White
Write-Host "  Genesis API:       http://localhost:8001" -ForegroundColor White
Write-Host "  Ollama:            http://localhost:11434" -ForegroundColor White
Write-Host ""
Write-Host "  All data stored on: D:\AitherOS-Data" -ForegroundColor Gray
Write-Host ""
Write-Host "  View logs:  docker logs -f aitheros-genesis" -ForegroundColor Gray
Write-Host "  Stop all:   docker compose -f docker-compose.aitheros.yml down" -ForegroundColor Gray
Write-Host ""

exit 0
