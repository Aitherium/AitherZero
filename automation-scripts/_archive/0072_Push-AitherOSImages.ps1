<#
.SYNOPSIS
    Pushes AitherOS container images to registry.
    
.DESCRIPTION
    Authenticates with container registry and pushes all
    AitherOS layer images.
    
.PARAMETER Registry
    Container registry (default: ghcr.io/aitherium)

.PARAMETER Tag
    Image tag to push (default: latest)

.PARAMETER All
    Push all layers (base, desktop, gpu, aitheros)

.PARAMETER Layer
    Specific layer to push

.PARAMETER ShowOutput
    Show verbose output

.EXAMPLE
    ./0072_Push-AitherOSImages.ps1 -All
    
.EXAMPLE
    ./0072_Push-AitherOSImages.ps1 -Layer aitheros -Tag v1.0.0
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Registry = 'ghcr.io/aitherium',
    
    [Parameter()]
    [string]$Tag = 'latest',
    
    [Parameter()]
    [switch]$All,
    
    [Parameter()]
    [ValidateSet('base', 'desktop', 'gpu', 'aitheros')]
    [string]$Layer,
    
    [Parameter()]
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'

# Source shared utilities
$initPath = Join-Path $PSScriptRoot '_init.ps1'
if (Test-Path $initPath) {
    . $initPath
}

$ImageNames = @{
    base = "aitheros-base"
    desktop = "aitheros-desktop"
    gpu = "aitheros-gpu-nvidia"
    aitheros = "aitheros"
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           AitherOS Image Pusher                               ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Check authentication
Write-Host ""
Write-Host "Checking registry authentication..." -ForegroundColor Yellow

$registryHost = ($Registry -split '/')[0]
$loginCheck = podman login --get-login $registryHost 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Not logged in to $registryHost" -ForegroundColor Yellow
    Write-Host "  Please run: podman login $registryHost" -ForegroundColor Cyan
    exit 1
}

Write-Host "  ✓ Authenticated as: $loginCheck" -ForegroundColor Green

# Determine which images to push
$imagesToPush = if ($All) {
    $ImageNames.Keys
} elseif ($Layer) {
    @($Layer)
} else {
    Write-Host ""
    Write-Host "Specify -All or -Layer <name>" -ForegroundColor Red
    exit 1
}

# Push images
$success = $true
$pushed = @()

foreach ($layerName in $imagesToPush) {
    $imageName = "$Registry/$($ImageNames[$layerName]):$Tag"
    
    Write-Host ""
    Write-Host "Pushing: $imageName" -ForegroundColor Cyan
    
    # Check if image exists locally
    $imageExists = podman image exists $imageName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚠ Image not found locally, skipping" -ForegroundColor Yellow
        continue
    }
    
    $process = Start-Process -FilePath 'podman' -ArgumentList @('push', $imageName) -NoNewWindow -Wait -PassThru
    
    if ($process.ExitCode -ne 0) {
        Write-Host "  ✗ Push failed" -ForegroundColor Red
        $success = $false
    } else {
        Write-Host "  ✓ Pushed successfully" -ForegroundColor Green
        $pushed += $imageName
    }
}

# Summary
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue

if ($pushed.Count -gt 0) {
    Write-Host "  Pushed $($pushed.Count) image(s):" -ForegroundColor Green
    foreach ($img in $pushed) {
        Write-Host "    ✓ $img" -ForegroundColor DarkGreen
    }
}

if (-not $success) {
    Write-Host ""
    Write-Host "  Some pushes failed. Check output above." -ForegroundColor Red
    exit 1
}

Write-Host ""
exit 0
