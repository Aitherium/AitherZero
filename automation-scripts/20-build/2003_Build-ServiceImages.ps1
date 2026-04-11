#Requires -Version 7.0
<#
.SYNOPSIS
    Builds all AitherOS service Docker images using Docker Compose.

.DESCRIPTION
    Uses Docker Compose to build all service images defined in docker-compose.yml.
    Supports building specific services or all services.

.PARAMETER Services
    Specific services to build. If not specified, builds all services.

.PARAMETER Target
    Build target: "development" or "production". Default: "production"

.PARAMETER NoPull
    Don't pull base images before building. Default: $false

.PARAMETER NoCache
    Build without using cache. Default: $false

.PARAMETER Parallel
    Build services in parallel. Default: $true

.EXAMPLE
    .\2003_Build-ServiceImages.ps1 -Verbose
    
.EXAMPLE
    .\2003_Build-ServiceImages.ps1 -Services genesis,veil,chronicle

.NOTES
    Category: build
    Dependencies: 2001_Build-GenesisImage.ps1, 2002_Build-ServicesBase.ps1
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [string[]]$Services,
    
    [ValidateSet("development", "production")]
    [string]$Target = "production",
    
    [switch]$NoPull,
    [switch]$NoCache,
    [switch]$Parallel = $true
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Resolve-Path "$scriptDir/../../../../"
$dockerDir = Join-Path $workspaceRoot "AitherOS/docker"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Building AitherOS Service Images" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Validate Docker Compose
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed."
    exit 1
}

# Check for compose plugin
$composeVersion = docker compose version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker Compose plugin not found. Install Docker Compose."
    exit 1
}

Write-Host "Docker Compose: $($composeVersion -replace 'Docker Compose version ', '')" -ForegroundColor Gray

# Determine compose files
$composeFile = Join-Path $workspaceRoot "docker-compose.aitheros.yml"
$overlayFile = if ($Target -eq "development") {
    Join-Path $workspaceRoot "docker-compose.dev.yml"
} else {
    Join-Path $workspaceRoot "docker-compose.prod.yml"
}

if (-not (Test-Path $composeFile)) {
    Write-Error "Compose file not found: $composeFile"
    exit 1
}

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Target:       $Target" -ForegroundColor Gray
Write-Host "  Compose:      $composeFile" -ForegroundColor Gray
if (Test-Path $overlayFile) {
    Write-Host "  Overlay:      $overlayFile" -ForegroundColor Gray
}
Write-Host "  Parallel:     $Parallel" -ForegroundColor Gray
Write-Host ""

# Build compose arguments
$composeArgs = @(
    "compose"
    "-f", $composeFile
)

if (Test-Path $overlayFile) {
    $composeArgs += "-f", $overlayFile
}

$composeArgs += "build"

if (-not $NoPull) {
    $composeArgs += "--pull"
}

if ($NoCache) {
    $composeArgs += "--no-cache"
}

if ($Parallel) {
    $composeArgs += "--parallel"
}

# Add specific services if provided
if ($Services) {
    Write-Host "Building services: $($Services -join ', ')" -ForegroundColor Yellow
    $composeArgs += $Services
} else {
    Write-Host "Building all services..." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "docker $($composeArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

# Change to docker directory for relative paths
Push-Location $dockerDir

try {
    # Run build
    $result = & docker @composeArgs 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host $result -ForegroundColor Red
        Write-Error "Docker Compose build failed"
        exit 1
    }
    
    Write-Host $result
    
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  All service images built successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  To start services:" -ForegroundColor Yellow
Write-Host "    docker compose -f docker-compose.aitheros.yml up -d" -ForegroundColor White
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
