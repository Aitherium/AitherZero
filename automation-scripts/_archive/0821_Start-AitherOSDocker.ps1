<#
.SYNOPSIS
    Start AitherOS services via Docker Compose.

.DESCRIPTION
    Starts AitherOS services using docker-compose.aitheros.yml.
    Supports various profiles for selective service deployment.

.PARAMETER Profile
    Docker compose profile: core, intelligence, perception, memory, training, autonomic, gateway, gpu, external, all.
    Default: core

.PARAMETER Detach
    Run containers in detached mode (background). Default: true

.PARAMETER Recreate
    Force recreate containers even if unchanged.

.PARAMETER Pull
    Pull latest images before starting.

.PARAMETER ShowOutput
    Display docker compose output.

.EXAMPLE
    .\0821_Start-AitherOSDocker.ps1
    # Start core services

.EXAMPLE
    .\0821_Start-AitherOSDocker.ps1 -Profile all -Pull
    # Pull latest and start all services
#>
[CmdletBinding()]
param(
    [ValidateSet("core", "intelligence", "perception", "memory", "training", "autonomic", "gateway", "gpu", "external", "agents", "all")]
    [string]$Profile = "core",
    
    [switch]$Detach = $true,
    
    [switch]$Recreate,
    
    [switch]$Pull,
    
    [switch]$ShowOutput
)

# Initialize script environment
$scriptPath = $PSScriptRoot
. (Join-Path $scriptPath "_init.ps1")

Write-AitherLog "Starting AitherOS via Docker Compose..." -Level INFO -Source "DockerStart"

# Check for Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-AitherLog "Docker not found. Please install Docker Desktop." -Level ERROR -Source "DockerStart"
    exit 1
}

# Check Docker is running
try {
    docker info | Out-Null
} catch {
    Write-AitherLog "Docker daemon is not running. Please start Docker Desktop." -Level ERROR -Source "DockerStart"
    exit 1
}

# Find compose file
$composeFile = Join-Path $env:AITHERZERO_ROOT "docker-compose.aitheros.yml"
if (-not (Test-Path $composeFile)) {
    Write-AitherLog "docker-compose.aitheros.yml not found at: $composeFile" -Level ERROR -Source "DockerStart"
    exit 1
}

# Optionally pull latest images
if ($Pull) {
    Write-AitherLog "Pulling latest images for profile: $Profile" -Level INFO -Source "DockerStart"
    $pullArgs = @("compose", "-f", $composeFile, "--profile", $Profile, "pull")
    & docker @pullArgs
}

# Build up command
$upArgs = @("compose", "-f", $composeFile)
$upArgs += @("--profile", $Profile)
$upArgs += "up"

if ($Detach) {
    $upArgs += "-d"
}

if ($Recreate) {
    $upArgs += "--force-recreate"
}

Write-AitherLog "Docker command: docker $($upArgs -join ' ')" -Level DEBUG -Source "DockerStart"
Write-AitherLog "Starting profile: $Profile" -Level INFO -Source "DockerStart"

# Execute
$startTime = Get-Date
try {
    if ($ShowOutput) {
        & docker @upArgs
    } else {
        & docker @upArgs 2>&1 | ForEach-Object { Write-Verbose $_ }
    }
    
    if ($LASTEXITCODE -ne 0) {
        throw "Docker compose up failed with exit code $LASTEXITCODE"
    }
    
    $elapsed = (Get-Date) - $startTime
    Write-AitherLog "Containers started in $($elapsed.TotalSeconds.ToString('F1')) seconds" -Level SUCCESS -Source "DockerStart"
    
} catch {
    Write-AitherLog "Docker compose up failed: $_" -Level ERROR -Source "DockerStart"
    exit 1
}

# Wait for health checks
Write-AitherLog "Waiting for services to become healthy..." -Level INFO -Source "DockerStart"
Start-Sleep -Seconds 5

# Show running containers
Write-AitherLog "Running AitherOS containers:" -Level INFO -Source "DockerStart"
docker compose -f $composeFile ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

# Show endpoints
$endpoints = @"

╔═══════════════════════════════════════════════════════════════╗
║            🐳 AITHEROS DOCKER IS RUNNING! 🐳                  ║
╠═══════════════════════════════════════════════════════════════╣
║  ENDPOINTS (Docker mode):                                     ║
║  → AitherNode (MCP):      http://localhost:8080               ║
║  → AitherVeil (Dashboard): http://localhost:3000              ║
║  → AitherPulse (Events):  http://localhost:8081               ║
║  → Chronicle (Logs):      http://localhost:8121               ║
║  → Ollama (LLM):          http://localhost:11434              ║
║                                                               ║
║  MANAGEMENT:                                                  ║
║  → View logs:   docker compose -f docker-compose.aitheros.yml ║
║                 logs -f <service-name>                        ║
║  → Stop all:    docker compose -f docker-compose.aitheros.yml ║
║                 --profile $Profile down                        ║
║  → Shell:       docker exec -it aither-node /bin/bash         ║
╚═══════════════════════════════════════════════════════════════╝
"@

Write-Host $endpoints -ForegroundColor Cyan
