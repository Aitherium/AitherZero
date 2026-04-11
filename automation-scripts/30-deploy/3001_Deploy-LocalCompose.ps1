#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys AitherOS locally using Docker Compose.

.DESCRIPTION
    Starts AitherOS services using Docker Compose with proper
    environment configuration and health checks.

.PARAMETER Environment
    Environment: "development" or "production". Default: "development"

.PARAMETER Profile
    Service profile: "minimal", "core", "full". Default: "core"

.PARAMETER Build
    Build images before starting. Default: $false

.PARAMETER Recreate
    Force recreate containers. Default: $false

.EXAMPLE
    .\3001_Deploy-LocalCompose.ps1 -Verbose

.NOTES
    Category: deploy
    Dependencies: Docker, docker-compose.yml
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [ValidateSet("development", "production")]
    [string]$Environment = "development",
    
    [ValidateSet("minimal", "core", "full")]
    [string]$Profile = "core",
    
    [switch]$Build,
    [switch]$Recreate
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$dockerDir = Join-Path $workspaceRoot "docker"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Deploying AitherOS (Local Docker Compose)" -ForegroundColor Cyan
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
    Write-Error "Docker daemon is not running."
    exit 1
}

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Environment: $Environment" -ForegroundColor Gray
Write-Host "  Profile:     $Profile" -ForegroundColor Gray
Write-Host "  Build:       $Build" -ForegroundColor Gray
Write-Host ""

# Copy .env file if not exists
$envFile = Join-Path $dockerDir ".env"
$envExample = Join-Path $dockerDir ".env.example"
if (-not (Test-Path $envFile) -and (Test-Path $envExample)) {
    Copy-Item $envExample $envFile
    Write-Host "Created .env from .env.example" -ForegroundColor Gray
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

# Build compose command
$composeArgs = @("compose") + $composeFiles + @("up", "-d")

if ($Build) {
    $composeArgs += "--build"
}

if ($Recreate) {
    $composeArgs += "--force-recreate"
}

$composeArgs += "--wait"

# Set environment variables
$env:COMPOSE_PROFILES = $Profile

Write-Host "Starting deployment..." -ForegroundColor Yellow
Write-Host "docker $($composeArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

Push-Location $dockerDir

try {
    & docker @composeArgs
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Deployment failed"
        exit 1
    }
} finally {
    Pop-Location
}

# Show status
Write-Host ""
Write-Host "Service Status:" -ForegroundColor Yellow
docker compose -f (Join-Path $dockerDir "docker-compose.yml") ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Deployment complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Dashboard:  http://localhost:3000" -ForegroundColor White
Write-Host "  Genesis:    http://localhost:8001" -ForegroundColor White
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
