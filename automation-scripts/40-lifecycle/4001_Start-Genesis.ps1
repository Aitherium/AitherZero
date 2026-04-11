#Requires -Version 7.0
<#
.SYNOPSIS
    Starts the AitherOS Genesis bootloader and services.

.DESCRIPTION
    Starts the Genesis bootloader using Docker Compose, which then
    orchestrates the startup of all AitherOS services.

.PARAMETER Profile
    Service profile to start: "minimal", "core", "full". Default: "core"

.PARAMETER Environment
    Environment: "development" or "production". Default: "development"

.PARAMETER Detached
    Run in detached mode. Default: $true

.PARAMETER Build
    Build images before starting. Default: $false

.PARAMETER Wait
    Wait for services to be healthy. Default: $true

.EXAMPLE
    .\4001_Start-Genesis.ps1 -Verbose

.EXAMPLE
    .\4001_Start-Genesis.ps1 -Profile full -Environment production

.NOTES
    Category: lifecycle
    Dependencies: Docker, docker-compose.yml
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [ValidateSet("minimal", "core", "full")]
    [string]$Profile = "core",
    
    [ValidateSet("development", "production")]
    [string]$Environment = "development",
    
    [switch]$Detached = $true,
    [switch]$Build,
    [switch]$Wait = $true
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$dockerDir = Join-Path $workspaceRoot "docker"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Starting AitherOS Genesis" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Validate Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed."
    exit 1
}

# Check Docker daemon
try {
    docker info 2>&1 | Out-Null
} catch {
    Write-Error "Docker daemon is not running. Please start Docker."
    exit 1
}

# Determine compose files
$composeFiles = @(
    "-f", (Join-Path $dockerDir "docker-compose.yml")
)

$overlayFile = if ($Environment -eq "development") {
    Join-Path $dockerDir "docker-compose.dev.yml"
} else {
    Join-Path $dockerDir "docker-compose.prod.yml"
}

if (Test-Path $overlayFile) {
    $composeFiles += "-f", $overlayFile
}

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Profile:     $Profile" -ForegroundColor Gray
Write-Host "  Environment: $Environment" -ForegroundColor Gray
Write-Host "  Docker Dir:  $dockerDir" -ForegroundColor Gray
Write-Host ""

# Build compose command
$composeArgs = @("compose") + $composeFiles + @("up")

if ($Build) {
    $composeArgs += "--build"
}

if ($Detached) {
    $composeArgs += "-d"
}

if ($Wait) {
    $composeArgs += "--wait"
}

# Set profile environment variable
$env:COMPOSE_PROFILES = $Profile

Write-Host "Starting services..." -ForegroundColor Yellow
Write-Host "docker $($composeArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

Push-Location $dockerDir

try {
    & docker @composeArgs
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to start services"
        exit 1
    }
} finally {
    Pop-Location
}

# Wait for Genesis to be healthy
if ($Wait -and $Detached) {
    Write-Host ""
    Write-Host "Waiting for Genesis to be ready..." -ForegroundColor Yellow
    
    $maxRetries = 30
    $retryCount = 0
    $healthy = $false
    
    while (-not $healthy -and $retryCount -lt $maxRetries) {
        Start-Sleep -Seconds 2
        $retryCount++
        
        try {
            $response = Invoke-RestMethod -Uri "http://localhost:8001/health" -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($response.status -eq "healthy") {
                $healthy = $true
            }
        } catch {
            Write-Host "  Waiting... ($retryCount/$maxRetries)" -ForegroundColor Gray
        }
    }
    
    if ($healthy) {
        Write-Host "  Genesis is ready!" -ForegroundColor Green
    } else {
        Write-Warning "Genesis health check timed out, but services may still be starting"
    }
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  AitherOS Genesis started!" -ForegroundColor Green
Write-Host ""
Write-Host "  Dashboard:  http://localhost:3000" -ForegroundColor White
Write-Host "  Genesis:    http://localhost:8001" -ForegroundColor White
Write-Host "  API Docs:   http://localhost:8001/docs" -ForegroundColor White
Write-Host ""
Write-Host "  View logs:  docker compose -f docker-compose.aitheros.yml logs -f" -ForegroundColor Gray
Write-Host "  Stop:       .\4002_Stop-Genesis.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
