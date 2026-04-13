#Requires -Version 7.0
# Note: Run as Administrator for best results
<#
.SYNOPSIS
    FULL RESET: Cleans up everything and bootstraps AitherOS from scratch on D: drive.

.DESCRIPTION
    This script:
    1. Stops ALL AitherOS containers
    2. Removes ALL AitherOS containers, volumes, and images
    3. Cleans up Docker system (prune)
    4. Migrates Docker Desktop WSL data to D: drive (if needed)
    5. Creates ALL volume directories on D:\AitherOS-Data
    6. Rebuilds and starts everything fresh

.PARAMETER SkipMigration
    Skip Docker WSL migration (if already done)

.PARAMETER SkipBuild
    Skip rebuilding images (use existing)

.PARAMETER Profile
    Service profile: "minimal", "core", "full". Default: "core"

.EXAMPLE
    .\0000_Full-Reset-Bootstrap.ps1
    Full reset and bootstrap.

.EXAMPLE
    .\0000_Full-Reset-Bootstrap.ps1 -SkipMigration -Profile full
    Skip WSL migration, deploy full profile.
#>

[CmdletBinding()]
param(
    [switch]$SkipMigration,
    [switch]$SkipBuild,
    
    [ValidateSet("minimal", "core", "full")]
    [string]$Profile = "core"
)

$ErrorActionPreference = 'Stop'

# Get paths
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$dockerDir = Join-Path $workspaceRoot "docker"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║                    FULL AITHEROS RESET & BOOTSTRAP                   ║" -ForegroundColor Red
Write-Host "║                                                                      ║" -ForegroundColor Red
Write-Host "║  This will DESTROY all existing containers and data!                 ║" -ForegroundColor Red
Write-Host "║  All Docker data will be moved to D:\AitherOS-Data                   ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

# Confirm
$confirm = Read-Host "Type 'YES' to proceed"
if ($confirm -ne 'YES') {
    Write-Host "Aborted." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# PHASE 1: STOP AND REMOVE ALL CONTAINERS
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PHASE 1: Stopping and removing all AitherOS containers" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Check if Docker is running
$dockerRunning = $false
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerRunning = $true }
} catch { }

if ($dockerRunning) {
    Write-Host "Stopping all AitherOS containers..." -ForegroundColor Yellow
    
    # Get all aitheros containers
    $containers = docker ps -a --filter "name=aitheros" --format "{{.Names}}" 2>$null
    
    if ($containers) {
        foreach ($container in $containers) {
            Write-Host "  Stopping: $container" -ForegroundColor Gray
            docker stop $container 2>&1 | Out-Null
            docker rm -f $container 2>&1 | Out-Null
        }
        Write-Host "  ✓ All containers stopped and removed" -ForegroundColor Green
    } else {
        Write-Host "  No AitherOS containers found" -ForegroundColor Green
    }
    
    # Remove aitheros network
    Write-Host "Removing aitheros-net network..." -ForegroundColor Yellow
    docker network rm aitheros-net 2>&1 | Out-Null
    Write-Host "  ✓ Network removed" -ForegroundColor Green
    
    # Remove AitherOS volumes
    Write-Host "Removing AitherOS volumes..." -ForegroundColor Yellow
    $volumes = @(
        "aitheros_chronicle-data",
        "aitheros_secrets-data", 
        "aitheros_strata-hot",
        "aitheros_strata-warm",
        "aitheros_strata-cold",
        "aitheros_mind-data",
        "aitheros_workingmemory-data",
        "aitheros_spirit-data",
        "aitheros_veil-next",
        "aitheros_veil-node-modules",
        "aitheros_ollama-models",
        "aitheros_comfyui-models",
        "aitheros_comfyui-output",
        "aitheros_comfyui-custom-nodes",
        "aitheros_training-data",
        "aitheros_training-checkpoints",
        "ollama-models",
        "comfyui-models",
        "comfyui-output"
    )
    
    foreach ($vol in $volumes) {
        docker volume rm $vol 2>&1 | Out-Null
    }
    Write-Host "  ✓ Volumes removed" -ForegroundColor Green
    
    # Prune system
    Write-Host "Pruning Docker system..." -ForegroundColor Yellow
    docker system prune -f 2>&1 | Out-Null
    Write-Host "  ✓ System pruned" -ForegroundColor Green
} else {
    Write-Host "Docker is not running - will start it later" -ForegroundColor Yellow
}

# ============================================================================
# PHASE 2: CREATE VOLUME DIRECTORIES ON D:
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PHASE 2: Creating volume directories on D: drive" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$baseDir = "D:\AitherOS-Data\volumes"

$directories = @(
    "$baseDir\chronicle",
    "$baseDir\secrets",
    "$baseDir\strata\hot",
    "$baseDir\strata\warm",
    "$baseDir\strata\cold",
    "$baseDir\mind",
    "$baseDir\workingmemory",
    "$baseDir\spirit",
    "$baseDir\veil\next",
    "$baseDir\veil\node_modules",
    "$baseDir\ollama\models",
    "$baseDir\comfyui\models",
    "$baseDir\comfyui\output",
    "$baseDir\comfyui\custom_nodes",
    "$baseDir\training\data",
    "$baseDir\training\checkpoints"
)

foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "  Created: $dir" -ForegroundColor Green
    } else {
        Write-Host "  Exists:  $dir" -ForegroundColor Gray
    }
}

# Also create logs directory
$logsDir = Join-Path $workspaceRoot "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

Write-Host "  ✓ All directories created on D: drive" -ForegroundColor Green

# ============================================================================
# PHASE 3: MIGRATE DOCKER WSL DATA TO D: (Optional)
# ============================================================================

if (-not $SkipMigration) {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  PHASE 3: Migrating Docker Desktop WSL data to D: drive" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    # Check if Docker WSL data is already on D:
    $wslDataPath = "D:\DockerData\wsl"
    if (Test-Path $wslDataPath) {
        Write-Host "  Docker WSL data already on D: drive - skipping migration" -ForegroundColor Green
    } else {
        Write-Host "  Stopping Docker and WSL..." -ForegroundColor Yellow
        
        # Stop everything
        wsl --shutdown 2>$null
        Stop-Process -Name "Docker Desktop" -Force -ErrorAction SilentlyContinue
        Stop-Process -Name "com.docker.*" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        
        # Create destination directories
        $dockerDataPath = "D:\DockerData"
        New-Item -ItemType Directory -Path $dockerDataPath -Force | Out-Null
        New-Item -ItemType Directory -Path "$wslDataPath" -Force | Out-Null
        New-Item -ItemType Directory -Path "$wslDataPath\docker-desktop" -Force | Out-Null
        New-Item -ItemType Directory -Path "$wslDataPath\docker-desktop-data" -Force | Out-Null
        
        # Export and reimport Docker WSL distros
        Write-Host "  Exporting Docker WSL distros..." -ForegroundColor Yellow
        $distros = wsl -l -q 2>$null | Where-Object { $_ -match "docker" }
        
        foreach ($distro in $distros) {
            $distro = $distro.Trim()
            if ($distro -and $distro -ne "") {
                $exportPath = "$dockerDataPath\$distro.tar"
                Write-Host "    Exporting $distro..." -ForegroundColor Gray
                wsl --export $distro $exportPath 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    Unregistering $distro..." -ForegroundColor Gray
                    wsl --unregister $distro 2>$null
                    Write-Host "    Importing $distro to D:\DockerData\wsl\$distro..." -ForegroundColor Gray
                    wsl --import $distro "$wslDataPath\$distro" $exportPath 2>$null
                    Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
                    Write-Host "    ✓ $distro migrated" -ForegroundColor Green
                }
            }
        }
        
        # Update Docker Desktop settings
        Write-Host "  Updating Docker Desktop settings..." -ForegroundColor Yellow
        $dockerSettingsPath = "$env:APPDATA\Docker\settings-store.json"
        
        if (Test-Path $dockerSettingsPath) {
            $settings = Get-Content $dockerSettingsPath -Raw | ConvertFrom-Json
            
            if (-not ($settings.PSObject.Properties.Name -contains "customWslDistroDir")) {
                $settings | Add-Member -NotePropertyName "customWslDistroDir" -NotePropertyValue $wslDataPath -Force
            } else {
                $settings.customWslDistroDir = $wslDataPath
            }
            
            $settings | ConvertTo-Json -Depth 10 | Set-Content $dockerSettingsPath
            Write-Host "    ✓ Updated settings-store.json" -ForegroundColor Green
        }
        
        # Clean up old C: drive data
        Write-Host "  Cleaning up C: drive Docker cache..." -ForegroundColor Yellow
        $pathsToClean = @(
            "$env:LOCALAPPDATA\Docker\wsl\distro",
            "$env:LOCALAPPDATA\Docker\wsl\data"
        )
        
        foreach ($path in $pathsToClean) {
            if (Test-Path $path) {
                Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "    Removed: $path" -ForegroundColor Gray
            }
        }
        
        Write-Host "  ✓ Docker WSL data migrated to D: drive" -ForegroundColor Green
    }
} else {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  PHASE 3: Skipping Docker WSL migration (as requested)" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

# ============================================================================
# PHASE 4: START DOCKER DESKTOP
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PHASE 4: Starting Docker Desktop" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$dockerRunning = $false
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerRunning = $true }
} catch { }

if (-not $dockerRunning) {
    Write-Host "  Starting Docker Desktop..." -ForegroundColor Yellow
    
    $dockerDesktopPaths = @(
        "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe"
    )
    
    foreach ($dockerPath in $dockerDesktopPaths) {
        if (Test-Path $dockerPath) {
            Start-Process -FilePath $dockerPath -WindowStyle Hidden -ErrorAction SilentlyContinue
            break
        }
    }
    
    # Wait for Docker to be ready
    Write-Host "  Waiting for Docker daemon (this may take 2-5 minutes)..." -ForegroundColor Yellow
    $maxWait = 300
    $waited = 0
    
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 3
        $waited += 3
        
        try {
            $null = docker info 2>&1
            if ($LASTEXITCODE -eq 0) {
                $dockerRunning = $true
                break
            }
        } catch { }
        
        if (($waited % 30) -eq 0) {
            Write-Host "    Still waiting... ($waited/$maxWait seconds)" -ForegroundColor Gray
        }
    }
    
    if ($dockerRunning) {
        Write-Host "  ✓ Docker Desktop is running" -ForegroundColor Green
    } else {
        Write-Error "Docker daemon did not start within $maxWait seconds. Please start Docker Desktop manually."
        exit 1
    }
} else {
    Write-Host "  ✓ Docker Desktop is already running" -ForegroundColor Green
}

# ============================================================================
# PHASE 5: RUN BOOTSTRAP
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PHASE 5: Running AitherOS Bootstrap" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$bootstrapScript = Join-Path $scriptDir "0000_Bootstrap-AitherOS.ps1"

if (Test-Path $bootstrapScript) {
    $bootstrapArgs = @()
    $bootstrapArgs += "-Profile", $Profile
    if ($SkipBuild) {
        $bootstrapArgs += "-SkipBuild"
    }
    
    & $bootstrapScript @bootstrapArgs
} else {
    Write-Error "Bootstrap script not found: $bootstrapScript"
    exit 1
}

# ============================================================================
# SUCCESS
# ============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    FULL RESET COMPLETE!                              ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║                                                                      ║" -ForegroundColor Green
Write-Host "║  All Docker data is now stored on D:\AitherOS-Data                   ║" -ForegroundColor Green
Write-Host "║  Docker WSL distros moved to D:\DockerData\wsl                       ║" -ForegroundColor Green
Write-Host "║                                                                      ║" -ForegroundColor Green
Write-Host "║  C: drive should now have much more free space!                      ║" -ForegroundColor Green
Write-Host "║                                                                      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# Show disk space
$cDrive = Get-Volume -DriveLetter C
$dDrive = Get-Volume -DriveLetter D
Write-Host "  C: drive free: $([math]::Round($cDrive.SizeRemaining / 1GB, 2)) GB" -ForegroundColor White
Write-Host "  D: drive free: $([math]::Round($dDrive.SizeRemaining / 1GB, 2)) GB" -ForegroundColor White
Write-Host ""

exit 0
