#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the Genesis bootloader Docker image.

.DESCRIPTION
    Builds the Genesis bootloader container image with proper tagging
    and optional push to registry.

.PARAMETER Tag
    Image tag. Default: "latest"

.PARAMETER Target
    Build target: "development" or "production". Default: "production"

.PARAMETER Push
    Push image to registry after build. Default: $false

.PARAMETER Registry
    Container registry URL. Default: "ghcr.io/aitheros"

.PARAMETER NoPrune
    Don't prune build cache. Default: $false

.EXAMPLE
    .\2001_Build-GenesisImage.ps1 -Verbose
    
.EXAMPLE
    .\2001_Build-GenesisImage.ps1 -Tag "v2.0.0" -Push -Registry "docker.io/myrepo"

.NOTES
    Category: build
    Dependencies: 0003_Install-Docker.ps1
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [string]$Tag = "latest",
    
    [ValidateSet("development", "production")]
    [string]$Target = "production",
    
    [switch]$Push,
    
    [string]$Registry = "ghcr.io/aitheros",
    
    [switch]$NoPrune
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$dockerDir = Join-Path $workspaceRoot "docker"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Building Genesis Bootloader Image" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Validate Docker is available
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed. Run 0003_Install-Docker.ps1 first."
    exit 1
}

# Check Docker daemon
try {
    docker info | Out-Null
} catch {
    Write-Error "Docker daemon is not running. Please start Docker."
    exit 1
}

# Build parameters
$imageName = "aitheros-genesis"
$fullImageName = "$Registry/$imageName`:$Tag"
$contextPath = Join-Path $dockerDir "genesis"

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Image:    $fullImageName" -ForegroundColor Gray
Write-Host "  Target:   $Target" -ForegroundColor Gray
Write-Host "  Context:  $contextPath" -ForegroundColor Gray
Write-Host ""

# Validate context directory
if (-not (Test-Path $contextPath)) {
    Write-Error "Genesis Docker context not found: $contextPath"
    exit 1
}

# Build image
Write-Host "Building image..." -ForegroundColor Yellow

$buildArgs = @(
    "build"
    "--target", $Target
    "--tag", $fullImageName
    "--tag", "$Registry/$imageName`:latest"
    "--file", (Join-Path $contextPath "Dockerfile")
    "--progress", "plain"
)

# Add build args
$buildArgs += "--build-arg", "BUILDKIT_INLINE_CACHE=1"

# Add context path
$buildArgs += $contextPath

Write-Host "docker $($buildArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

$result = docker @buildArgs 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker build failed: $result"
    exit 1
}

Write-Host ""
Write-Host "Build successful!" -ForegroundColor Green

# Push if requested
if ($Push) {
    Write-Host ""
    Write-Host "Pushing image to registry..." -ForegroundColor Yellow
    
    docker push $fullImageName
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to push image"
        exit 1
    }
    
    # Also push latest tag
    docker push "$Registry/$imageName`:latest"
    
    Write-Host "Push successful!" -ForegroundColor Green
}

# Prune build cache
if (-not $NoPrune) {
    Write-Host ""
    Write-Host "Pruning build cache..." -ForegroundColor Gray
    docker builder prune -f --filter "until=24h" 2>&1 | Out-Null
}

# Summary
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Genesis image built successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  Image: $fullImageName" -ForegroundColor White
Write-Host ""
Write-Host "  To run locally:" -ForegroundColor Yellow
Write-Host "    docker run -p 8001:8001 $fullImageName" -ForegroundColor White
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
