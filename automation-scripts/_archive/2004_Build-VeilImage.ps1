#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the Veil dashboard Docker image.

.DESCRIPTION
    Builds the Next.js-based Veil dashboard container image.

.PARAMETER Tag
    Image tag. Default: "latest"

.PARAMETER Target
    Build target: "development" or "production". Default: "production"

.PARAMETER Push
    Push image to registry after build. Default: $false

.PARAMETER Registry
    Container registry URL. Default: "ghcr.io/aitheros"

.PARAMETER ApiUrl
    API URL for Next.js public env. Default: "http://localhost:8001"

.EXAMPLE
    .\2004_Build-VeilImage.ps1 -Verbose

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
    
    [string]$ApiUrl = "http://localhost:8001"
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$veilDir = Join-Path $workspaceRoot "AitherOS/AitherVeil"
$dockerServicesDir = Join-Path $workspaceRoot "docker/services"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Building Veil Dashboard Image" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Validate Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed."
    exit 1
}

# Validate Veil directory exists
if (-not (Test-Path $veilDir)) {
    Write-Error "Veil directory not found: $veilDir"
    exit 1
}

# Build parameters
$imageName = "aitheros-veil"
$fullImageName = "$Registry/$imageName`:$Tag"
$dockerfilePath = Join-Path $dockerServicesDir "Dockerfile.node"

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Image:      $fullImageName" -ForegroundColor Gray
Write-Host "  Target:     $Target" -ForegroundColor Gray
Write-Host "  Context:    $veilDir" -ForegroundColor Gray
Write-Host "  API URL:    $ApiUrl" -ForegroundColor Gray
Write-Host ""

# Check for Dockerfile
if (-not (Test-Path $dockerfilePath)) {
    Write-Warning "Node Dockerfile not found at $dockerfilePath, using context's Dockerfile"
    $dockerfilePath = Join-Path $veilDir "Dockerfile"
}

# Build image
Write-Host "Building image..." -ForegroundColor Yellow

$buildArgs = @(
    "build"
    "--target", $Target
    "--tag", $fullImageName
    "--tag", "$Registry/$imageName`:latest"
    "--build-arg", "NEXT_PUBLIC_API_URL=$ApiUrl"
    "--progress", "plain"
)

if (Test-Path $dockerfilePath) {
    $buildArgs += "--file", $dockerfilePath
}

$buildArgs += $veilDir

Write-Host "docker $($buildArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

$result = docker @buildArgs 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host $result -ForegroundColor Red
    Write-Error "Docker build failed"
    exit 1
}

Write-Host ""
Write-Host "Build successful!" -ForegroundColor Green

# Push if requested
if ($Push) {
    Write-Host ""
    Write-Host "Pushing image to registry..." -ForegroundColor Yellow
    
    docker push $fullImageName
    docker push "$Registry/$imageName`:latest"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to push image"
        exit 1
    }
    
    Write-Host "Push successful!" -ForegroundColor Green
}

# Summary
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Veil dashboard image built successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  Image: $fullImageName" -ForegroundColor White
Write-Host ""
Write-Host "  To run locally:" -ForegroundColor Yellow
Write-Host "    docker run -p 3000:3000 $fullImageName" -ForegroundColor White
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
