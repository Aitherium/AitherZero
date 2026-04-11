<#
.SYNOPSIS
    Build AitherDesktop Atomic OS base image layer.

.DESCRIPTION
    Builds the RockyLinux 9 bootc base layer for AitherDesktop.
    This is the foundation layer containing:
    - Podman container runtime
    - SELinux enforcing
    - Core system utilities
    - SSH hardening
    - Cockpit management

.PARAMETER Tag
    Image tag to use. Default: latest

.PARAMETER Push
    Push to registry after building.

.PARAMETER Registry
    Container registry. Default: ghcr.io/aitherium

.PARAMETER ShowOutput
    Show verbose build output.

.EXAMPLE
    ./0070_Build-AitherDesktopBase.ps1 -ShowOutput

.EXAMPLE
    ./0070_Build-AitherDesktopBase.ps1 -Push -Tag v1.0.0

.NOTES
    Requires: Podman
    Script Number: 0070
    Category: AitherDesktop Build Pipeline
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Tag = 'latest',

    [Parameter()]
    [switch]$Push,

    [Parameter()]
    [string]$Registry = 'ghcr.io/aitherium',

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize AitherZero
. "$PSScriptRoot/_init.ps1"

$ErrorActionPreference = 'Stop'

# Configuration
$ImageName = 'aitheros-base'
$BuildDir = Join-Path $PSScriptRoot '../../AitherOS/AitherDesktop/build'
$Containerfile = Join-Path $BuildDir 'Containerfile.base'

function Write-StepHeader {
    param([string]$Message)
    if ($ShowOutput) {
        Write-Host "`n=== $Message ===" -ForegroundColor Cyan
    }
}

function Test-Prerequisites {
    Write-StepHeader "Checking prerequisites"

    # Check Podman
    $podman = Get-Command podman -ErrorAction SilentlyContinue
    if (-not $podman) {
        throw "Podman is required but not found. Install with: dnf install podman"
    }

    if ($ShowOutput) {
        Write-Host "  [✓] Podman: $($podman.Source)" -ForegroundColor Green
    }

    # Check Containerfile exists
    if (-not (Test-Path $Containerfile)) {
        throw "Containerfile not found: $Containerfile"
    }

    if ($ShowOutput) {
        Write-Host "  [✓] Containerfile: $Containerfile" -ForegroundColor Green
    }

    return $true
}

function Build-BaseImage {
    Write-StepHeader "Building base image"

    $localTag = "${ImageName}:${Tag}"
    $fullTag = "${Registry}/${ImageName}:${Tag}"

    if ($ShowOutput) {
        Write-Host "  Building: $localTag" -ForegroundColor Yellow
        Write-Host "  Context: $BuildDir" -ForegroundColor Yellow
    }

    $buildArgs = @(
        'build'
        '--tag', $localTag
        '--file', $Containerfile
        '--format', 'oci'
        '--layers', 'true'
    )

    if (-not $ShowOutput) {
        $buildArgs += '--quiet'
    }

    $buildArgs += $BuildDir

    $startTime = Get-Date

    & podman @buildArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code $LASTEXITCODE"
    }

    $duration = (Get-Date) - $startTime

    if ($ShowOutput) {
        Write-Host "  [✓] Build completed in $($duration.TotalMinutes.ToString('F1')) minutes" -ForegroundColor Green
    }

    # Get image info
    $imageInfo = podman image inspect $localTag --format '{{.Size}}' | ForEach-Object { [long]$_ }
    $sizeGB = $imageInfo / 1GB

    if ($ShowOutput) {
        Write-Host "  [✓] Image size: $($sizeGB.ToString('F2')) GB" -ForegroundColor Green
    }

    return $localTag
}

function Push-Image {
    param([string]$LocalTag)

    Write-StepHeader "Pushing to registry"

    $fullTag = "${Registry}/${ImageName}:${Tag}"

    if ($ShowOutput) {
        Write-Host "  Tagging: $LocalTag -> $fullTag" -ForegroundColor Yellow
    }

    & podman tag $LocalTag $fullTag

    if ($ShowOutput) {
        Write-Host "  Pushing: $fullTag" -ForegroundColor Yellow
    }

    & podman push $fullTag

    if ($LASTEXITCODE -ne 0) {
        throw "Push failed with exit code $LASTEXITCODE"
    }

    if ($ShowOutput) {
        Write-Host "  [✓] Pushed to $fullTag" -ForegroundColor Green
    }
}

# Main execution
try {
    Write-StepHeader "AitherDesktop Base Layer Build"

    Test-Prerequisites

    $localTag = Build-BaseImage

    if ($Push) {
        Push-Image -LocalTag $localTag
    }

    Write-StepHeader "Build Summary"

    if ($ShowOutput) {
        Write-Host "  Image: $localTag" -ForegroundColor Green
        Write-Host "  Layer: base (RockyLinux 9 bootc)" -ForegroundColor Green
        Write-Host "  Status: SUCCESS" -ForegroundColor Green
    }

    return @{
        Success = $true
        ImageTag = $localTag
        Layer = 'base'
    }
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
