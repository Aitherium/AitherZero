<#
.SYNOPSIS
    Build AitherOS Docker images.

.DESCRIPTION
    Builds Docker images for all AitherOS services using docker-compose.aitheros.yml.
    Supports building specific profiles or all images at once.

.PARAMETER Profile
    Docker compose profile to build: core, intelligence, perception, memory, training, autonomic, gateway, gpu, all.
    Default: all

.PARAMETER NoCache
    Build without using cache (clean build).

.PARAMETER Push
    Push images to registry after building.

.PARAMETER ShowOutput
    Display docker build output in console.

.EXAMPLE
    .\0820_Build-AitherOSDocker.ps1
    # Build all images

.EXAMPLE
    .\0820_Build-AitherOSDocker.ps1 -Profile core -NoCache
    # Clean build of core services only
#>
[CmdletBinding()]
param(
    [ValidateSet("core", "intelligence", "perception", "memory", "training", "autonomic", "gateway", "gpu", "external", "all")]
    [string]$Profile = "all",
    
    [switch]$NoCache,
    
    [switch]$Push,
    
    [switch]$ShowOutput
)

# Initialize script environment
$scriptPath = $PSScriptRoot
. (Join-Path $scriptPath "_init.ps1")

Write-AitherLog "Building AitherOS Docker images..." -Level Information -Source "DockerBuild"

# Check for Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-AitherLog "Docker not found. Please install Docker Desktop." -Level Error -Source "DockerBuild"
    exit 1
}

# Check Docker is running, auto-start if not
$dockerRunning = $false
try {
    docker info 2>$null | Out-Null
    $dockerRunning = ($LASTEXITCODE -eq 0)
} catch {
    $dockerRunning = $false
}

if (-not $dockerRunning) {
    Write-AitherLog "Docker daemon not running. Starting Docker Desktop..." -Level Information -Source "DockerBuild"
    
    # Find Docker Desktop executable
    $dockerDesktopPaths = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Docker\Docker Desktop.exe"
    )
    
    $dockerExe = $dockerDesktopPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    
    if ($dockerExe) {
        # Start Docker Desktop minimized and with lower priority to reduce memory pressure
        $proc = Start-Process -FilePath $dockerExe -WindowStyle Minimized -PassThru
        Write-AitherLog "Docker Desktop starting (PID: $($proc.Id)). Waiting for daemon (up to 120 seconds)..." -Level Information -Source "DockerBuild"
        
        # Brief pause to let Docker begin initialization without competing for resources
        Start-Sleep -Seconds 3
        
        $maxWait = 120
        $waited = 0
        while ($waited -lt $maxWait) {
            Start-Sleep -Seconds 5
            $waited += 5
            try {
                docker info 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-AitherLog "Docker daemon started successfully after $waited seconds" -Level Information -Source "DockerBuild"
                    # Give Docker a moment to stabilize memory usage before proceeding
                    Write-AitherLog "Allowing Docker to stabilize..." -Level Debug -Source "DockerBuild"
                    Start-Sleep -Seconds 5
                    $dockerRunning = $true
                    break
                }
            } catch { }
            Write-AitherLog "Still waiting for Docker... ($waited/$maxWait seconds)" -Level Debug -Source "DockerBuild"
        }
        
        if (-not $dockerRunning) {
            Write-AitherLog "Docker daemon failed to start within $maxWait seconds" -Level Error -Source "DockerBuild"
            exit 1
        }
    } else {
        Write-AitherLog "Docker Desktop executable not found. Please install Docker Desktop." -Level Error -Source "DockerBuild"
        exit 1
    }
}

# Find compose file
$composeFile = Join-Path $env:AITHERZERO_ROOT "docker-compose.aitheros.yml"
if (-not (Test-Path $composeFile)) {
    Write-AitherLog "docker-compose.aitheros.yml not found at: $composeFile" -Level Error -Source "DockerBuild"
    exit 1
}

# Build command
$buildArgs = @("compose", "-f", $composeFile)

if ($Profile -ne "all") {
    $buildArgs += @("--profile", $Profile)
} else {
    $buildArgs += @("--profile", "all")
}

$buildArgs += "build"

if ($NoCache) {
    $buildArgs += "--no-cache"
}

$buildArgs += "--parallel"

Write-AitherLog "Docker command: docker $($buildArgs -join ' ')" -Level Debug -Source "DockerBuild"
Write-AitherLog "Building profile: $Profile" -Level Information -Source "DockerBuild"

# Execute build
$startTime = Get-Date
try {
    if ($ShowOutput) {
        & docker @buildArgs
    } else {
        & docker @buildArgs 2>&1 | ForEach-Object { Write-Verbose $_ }
    }
    
    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed with exit code $LASTEXITCODE"
    }
    
    $elapsed = (Get-Date) - $startTime
    Write-AitherLog "Build completed in $($elapsed.TotalSeconds.ToString('F1')) seconds" -Level Information -Source "DockerBuild"
    
} catch {
    Write-AitherLog "Docker build failed: $_" -Level Error -Source "DockerBuild"
    exit 1
}

# Optional push
if ($Push) {
    Write-AitherLog "Pushing images to registry..." -Level Information -Source "DockerBuild"
    
    $pushArgs = @("compose", "-f", $composeFile)
    if ($Profile -ne "all") {
        $pushArgs += @("--profile", $Profile)
    } else {
        $pushArgs += @("--profile", "all")
    }
    $pushArgs += "push"
    
    & docker @pushArgs
    
    if ($LASTEXITCODE -eq 0) {
        Write-AitherLog "Images pushed successfully" -Level Information -Source "DockerBuild"
    } else {
        Write-AitherLog "Image push failed" -Level Warning -Source "DockerBuild"
    }
}

# List built images
Write-AitherLog "Built images:" -Level Information -Source "DockerBuild"
docker images --filter "reference=ghcr.io/aitherium/aitheros-*" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
