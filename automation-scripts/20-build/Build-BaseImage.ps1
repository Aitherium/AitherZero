<#
.SYNOPSIS
    Builds the AitherOS unified base image with all dependencies pre-installed.

.DESCRIPTION
    This script builds the unified base Docker image that contains ALL Python
    dependencies for AitherOS services. Build this ONCE, then all service builds
    become instant (just copying code, no pip install).

    Build time: ~5-10 minutes (first time)
    After this, service builds: ~10 seconds each

.PARAMETER Tag
    Image tag. Default: latest

.PARAMETER Push
    Push to GitHub Container Registry after build.

.PARAMETER NoBuildKit
    Disable BuildKit (for debugging).

.PARAMETER Platform
    Target platform(s). Default: linux/amd64

.EXAMPLE
    # Build base image locally
    ./Build-BaseImage.ps1

.EXAMPLE
    # Build and push to registry
    ./Build-BaseImage.ps1 -Push

.EXAMPLE
    # Build specific tag
    ./Build-BaseImage.ps1 -Tag "v1.2.0" -Push

.NOTES
    After building, update docker-compose.aitheros.yml to use:
    ghcr.io/aitherium/aitheros-base:latest
#>

[CmdletBinding()]
param(
    [string]$Tag = "latest",
    [switch]$Push,
    [switch]$NoBuildKit,
    [string]$Platform = "linux/amd64",
    [string]$Registry = "ghcr.io/aitherium"
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           AitherOS Unified Base Image Builder                     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$imageName = "$Registry/aitheros-base"
$fullTag = "${imageName}:${Tag}"

Write-Host "📦 Building: $fullTag" -ForegroundColor Yellow
Write-Host "📂 Context:  $projectRoot" -ForegroundColor Gray
Write-Host ""

# Enable BuildKit for faster builds
if (-not $NoBuildKit) {
    $env:DOCKER_BUILDKIT = "1"
    Write-Host "✓ BuildKit enabled" -ForegroundColor Green
}

# Build the base image
$buildArgs = @(
    "build"
    "-f", "$projectRoot/docker/base/Dockerfile.unified-base"
    "-t", $fullTag
    "--platform", $Platform
)

# Add cache settings
$buildArgs += @(
    "--build-arg", "BUILDKIT_INLINE_CACHE=1"
)

# If we have a previous image, use it as cache
$buildArgs += @(
    "--cache-from", $fullTag
)

$buildArgs += $projectRoot

Write-Host "🔨 Running: docker $($buildArgs -join ' ')" -ForegroundColor Gray
Write-Host ""

$startTime = Get-Date

try {
    & docker @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed with exit code $LASTEXITCODE"
    }
}
catch {
    Write-Host "❌ Build failed: $_" -ForegroundColor Red
    exit 1
}

$duration = (Get-Date) - $startTime
Write-Host ""
Write-Host "✅ Build completed in $($duration.ToString('mm\:ss'))" -ForegroundColor Green

# Also tag as 'latest' if building a version tag
if ($Tag -ne "latest") {
    Write-Host "🏷️  Also tagging as ${imageName}:latest" -ForegroundColor Yellow
    docker tag $fullTag "${imageName}:latest"
}

# Push if requested
if ($Push) {
    Write-Host ""
    Write-Host "📤 Pushing to registry..." -ForegroundColor Yellow
    
    docker push $fullTag
    if ($Tag -ne "latest") {
        docker push "${imageName}:latest"
    }
    
    Write-Host "✅ Pushed successfully!" -ForegroundColor Green
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                         NEXT STEPS                                ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║ 1. Update docker-compose.aitheros.yml to use the new Dockerfile  ║" -ForegroundColor White
Write-Host "║    Change: dockerfile: AitherOS/Dockerfile                        ║" -ForegroundColor Gray
Write-Host "║    To:     dockerfile: AitherOS/Dockerfile.optimized              ║" -ForegroundColor Gray
Write-Host "║                                                                   ║" -ForegroundColor White
Write-Host "║ 2. Rebuild services (now instant!):                               ║" -ForegroundColor White
Write-Host "║    docker compose -f docker-compose.aitheros.yml build            ║" -ForegroundColor Gray
Write-Host "║                                                                   ║" -ForegroundColor White
Write-Host "║ 3. For CI/CD, push the base image:                                ║" -ForegroundColor White
Write-Host "║    ./Build-BaseImage.ps1 -Push                                    ║" -ForegroundColor Gray
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
