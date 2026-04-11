#Requires -Version 7.0
<#
.SYNOPSIS
    Pushes all AitherOS Docker images to a container registry.

.DESCRIPTION
    Pushes all built AitherOS images to the specified container registry.
    Supports Docker Hub, GitHub Container Registry, and other registries.

.PARAMETER Registry
    Container registry URL. Default: "ghcr.io/aitheros"

.PARAMETER Tag
    Image tag to push. Default: "latest"

.PARAMETER All
    Push all tags, not just the specified one. Default: $false

.PARAMETER Login
    Perform registry login before push. Default: $false

.PARAMETER Username
    Registry username (required if -Login is specified).

.PARAMETER Token
    Registry token/password (required if -Login is specified).

.EXAMPLE
    .\2005_Push-Images.ps1 -Registry "docker.io/myrepo" -Login -Username myuser

.NOTES
    Category: build
    Dependencies: 2003_Build-ServiceImages.ps1
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [string]$Registry = "ghcr.io/aitheros",
    
    [string]$Tag = "latest",
    
    [switch]$All,
    
    [switch]$Login,
    
    [string]$Username,
    
    [SecureString]$Token
)

$ErrorActionPreference = 'Stop'

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Pushing AitherOS Images to Registry" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Validate Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed."
    exit 1
}

# Registry login if requested
if ($Login) {
    if (-not $Username) {
        $Username = Read-Host "Registry username"
    }
    
    if (-not $Token) {
        $Token = Read-Host "Registry token/password" -AsSecureString
    }
    
    Write-Host "Logging into registry: $Registry" -ForegroundColor Yellow
    
    # Convert SecureString to plain text for docker login
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
    $plainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    
    $plainToken | docker login $Registry --username $Username --password-stdin
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Registry login failed"
        exit 1
    }
    
    Write-Host "Login successful!" -ForegroundColor Green
    Write-Host ""
}

# Get list of AitherOS images
Write-Host "Finding AitherOS images..." -ForegroundColor Yellow

$images = docker images --filter "reference=$Registry/aitheros-*" --format "{{.Repository}}:{{.Tag}}" 2>&1

if (-not $images) {
    Write-Warning "No AitherOS images found for registry: $Registry"
    Write-Host "Build images first using 2003_Build-ServiceImages.ps1"
    exit 1
}

$imageList = $images -split "`n" | Where-Object { $_ }

# Filter by tag unless -All is specified
if (-not $All) {
    $imageList = $imageList | Where-Object { $_ -like "*:$Tag" }
}

Write-Host "Found $($imageList.Count) images to push:" -ForegroundColor Gray
$imageList | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Write-Host ""

# Push images
$results = @()

foreach ($image in $imageList) {
    Write-Host "Pushing: $image" -ForegroundColor Yellow
    
    $pushOutput = docker push $image 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED" -ForegroundColor Red
        $results += @{ Image = $image; Status = "failed"; Error = $pushOutput }
    } else {
        Write-Host "  SUCCESS" -ForegroundColor Green
        $results += @{ Image = $image; Status = "success" }
    }
}

# Summary
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "Push Summary:" -ForegroundColor Yellow
Write-Host ""

$successCount = ($results | Where-Object { $_.Status -eq "success" }).Count
$failedCount = ($results | Where-Object { $_.Status -eq "failed" }).Count

foreach ($result in $results) {
    $statusColor = if ($result.Status -eq "success") { "Green" } else { "Red" }
    Write-Host "  $($result.Image): " -NoNewline
    Write-Host $result.Status.ToUpper() -ForegroundColor $statusColor
}

Write-Host ""
Write-Host "  Total: $($results.Count) | Success: $successCount | Failed: $failedCount" -ForegroundColor Gray
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan

if ($failedCount -gt 0) {
    exit 1
}
exit 0
