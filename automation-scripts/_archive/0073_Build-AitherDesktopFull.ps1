<#
.SYNOPSIS
    Build all AitherDesktop Atomic OS image layers.

.DESCRIPTION
    Complete build pipeline for AitherDesktop Atomic OS.
    Builds layers in order:
    1. Base (RockyLinux 9 bootc)
    2. Desktop (GNOME/KDE)
    3. GPU-NVIDIA (NVIDIA drivers + container toolkit)
    4. AitherOS (services, mesh agent, first-boot)

    Optionally generates bootable ISO for bare-metal installation.

.PARAMETER DesktopEnv
    Desktop environment to include. Options: gnome, kde. Default: gnome

.PARAMETER Layers
    Which layers to build. Options: all, base, desktop, gpu, aitheros. Default: all

.PARAMETER Tag
    Image tag to use. Default: latest

.PARAMETER Push
    Push images to registry after building.

.PARAMETER GenerateISO
    Generate bootable ISO after building images.

.PARAMETER Registry
    Container registry. Default: ghcr.io/aitherium

.PARAMETER ShowOutput
    Show verbose build output.

.EXAMPLE
    ./0073_Build-AitherDesktopFull.ps1 -ShowOutput

.EXAMPLE
    ./0073_Build-AitherDesktopFull.ps1 -DesktopEnv kde -Push -Tag v1.0.0

.EXAMPLE
    ./0073_Build-AitherDesktopFull.ps1 -GenerateISO -ShowOutput

.NOTES
    Requires: Podman, bootc-image-builder (for ISO)
    Script Number: 0073
    Category: AitherDesktop Build Pipeline
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('gnome', 'kde')]
    [string]$DesktopEnv = 'gnome',

    [Parameter()]
    [ValidateSet('all', 'base', 'desktop', 'gpu', 'aitheros')]
    [string]$Layers = 'all',

    [Parameter()]
    [string]$Tag = 'latest',

    [Parameter()]
    [switch]$Push,

    [Parameter()]
    [switch]$GenerateISO,

    [Parameter()]
    [string]$Registry = 'ghcr.io/aitherium',

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize AitherZero
. "$PSScriptRoot/_init.ps1"

$ErrorActionPreference = 'Stop'

# Configuration
$BuildDir = Join-Path $PSScriptRoot '../../AitherOS/AitherDesktop/build'
$OutputDir = Join-Path $PSScriptRoot '../../AitherOS/AitherDesktop/output'

# Layer definitions
$LayerDefinitions = @(
    @{
        Name = 'base'
        Image = 'aitheros-base'
        Containerfile = 'Containerfile.base'
        BaseImage = 'quay.io/rockylinux/rockylinux:9-bootc'
        BuildArgs = @{}
    }
    @{
        Name = 'desktop'
        Image = 'aitheros-desktop'
        Containerfile = 'Containerfile.desktop'
        BaseImage = 'localhost/aitheros-base:latest'
        BuildArgs = @{ DESKTOP_ENV = $DesktopEnv }
    }
    @{
        Name = 'gpu'
        Image = 'aitheros-gpu-nvidia'
        Containerfile = 'Containerfile.gpu-nvidia'
        BaseImage = 'localhost/aitheros-desktop:latest'
        BuildArgs = @{}
    }
    @{
        Name = 'aitheros'
        Image = 'aitheros-desktop-full'
        Containerfile = 'Containerfile.aitheros'
        BaseImage = 'localhost/aitheros-gpu-nvidia:latest'
        BuildArgs = @{}
    }
)

function Write-StepHeader {
    param([string]$Message)
    if ($ShowOutput) {
        Write-Host "`n════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  $Message" -ForegroundColor Cyan
        Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
    }
}

function Write-SubStep {
    param([string]$Message, [string]$Status = 'info')
    if ($ShowOutput) {
        $color = switch ($Status) {
            'success' { 'Green' }
            'warning' { 'Yellow' }
            'error' { 'Red' }
            default { 'White' }
        }
        $symbol = switch ($Status) {
            'success' { '✓' }
            'warning' { '!' }
            'error' { '✗' }
            default { '→' }
        }
        Write-Host "  [$symbol] $Message" -ForegroundColor $color
    }
}

function Test-Prerequisites {
    Write-StepHeader "Checking Prerequisites"

    # Check Podman
    $podman = Get-Command podman -ErrorAction SilentlyContinue
    if (-not $podman) {
        throw "Podman is required but not found. Install with: dnf install podman"
    }
    Write-SubStep "Podman: $($podman.Source)" -Status success

    # Check build directory
    if (-not (Test-Path $BuildDir)) {
        throw "Build directory not found: $BuildDir"
    }
    Write-SubStep "Build directory: $BuildDir" -Status success

    # Check for bootc-image-builder if generating ISO
    if ($GenerateISO) {
        $bootcBuilder = Get-Command bootc-image-builder -ErrorAction SilentlyContinue
        if (-not $bootcBuilder) {
            Write-SubStep "bootc-image-builder not found - ISO generation will use container" -Status warning
        }
        else {
            Write-SubStep "bootc-image-builder: $($bootcBuilder.Source)" -Status success
        }
    }

    return $true
}

function Build-Layer {
    param([hashtable]$Layer)

    Write-StepHeader "Building Layer: $($Layer.Name)"

    $containerfile = Join-Path $BuildDir $Layer.Containerfile

    if (-not (Test-Path $containerfile)) {
        throw "Containerfile not found: $containerfile"
    }

    $localTag = "$($Layer.Image):$Tag"

    Write-SubStep "Containerfile: $($Layer.Containerfile)"
    Write-SubStep "Base image: $($Layer.BaseImage)"
    Write-SubStep "Target tag: $localTag"

    # Build arguments
    $buildArgs = @(
        'build'
        '--tag', $localTag
        '--file', $containerfile
        '--format', 'oci'
        '--layers', 'true'
        '--build-arg', "BASE_IMAGE=$($Layer.BaseImage)"
    )

    foreach ($key in $Layer.BuildArgs.Keys) {
        $buildArgs += '--build-arg', "$key=$($Layer.BuildArgs[$key])"
    }

    if (-not $ShowOutput) {
        $buildArgs += '--quiet'
    }

    $buildArgs += $BuildDir

    $startTime = Get-Date

    if ($ShowOutput) {
        Write-Host "`n--- Build Output ---" -ForegroundColor DarkGray
    }

    & podman @buildArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Build failed for layer $($Layer.Name) with exit code $LASTEXITCODE"
    }

    $duration = (Get-Date) - $startTime

    # Get image size
    $sizeBytes = podman image inspect $localTag --format '{{.Size}}' 2>$null | ForEach-Object { [long]$_ }
    $sizeGB = if ($sizeBytes) { $sizeBytes / 1GB } else { 0 }

    if ($ShowOutput) {
        Write-Host "--- End Build Output ---`n" -ForegroundColor DarkGray
    }

    Write-SubStep "Build time: $($duration.TotalMinutes.ToString('F1')) minutes" -Status success
    Write-SubStep "Image size: $($sizeGB.ToString('F2')) GB" -Status success

    # Push if requested
    if ($Push) {
        $fullTag = "${Registry}/$($Layer.Image):$Tag"
        Write-SubStep "Pushing to: $fullTag"

        & podman tag $localTag $fullTag
        & podman push $fullTag

        if ($LASTEXITCODE -ne 0) {
            throw "Push failed for $fullTag"
        }

        Write-SubStep "Pushed successfully" -Status success
    }

    return @{
        Name = $Layer.Name
        LocalTag = $localTag
        Size = $sizeGB
        Duration = $duration
    }
}

function Build-ISO {
    Write-StepHeader "Generating Bootable ISO"

    $isoOutputDir = Join-Path $OutputDir 'iso'
    if (-not (Test-Path $isoOutputDir)) {
        New-Item -ItemType Directory -Path $isoOutputDir -Force | Out-Null
    }

    $finalImage = 'localhost/aitheros-desktop-full:latest'
    $isoName = "aitheros-desktop-$Tag-x86_64.iso"
    $isoPath = Join-Path $isoOutputDir $isoName

    Write-SubStep "Source image: $finalImage"
    Write-SubStep "Output: $isoPath"

    # Use podman to run bootc-image-builder
    $builderArgs = @(
        'run'
        '--rm'
        '--privileged'
        '--pull=newer'
        '--security-opt', 'label=type:unconfined_t'
        '-v', '/var/lib/containers/storage:/var/lib/containers/storage'
        '-v', "${isoOutputDir}:/output"
        'quay.io/centos-bootc/bootc-image-builder:latest'
        '--type', 'iso'
        '--local'
        $finalImage
    )

    Write-SubStep "Running bootc-image-builder..."

    & podman @builderArgs

    if ($LASTEXITCODE -ne 0) {
        throw "ISO generation failed with exit code $LASTEXITCODE"
    }

    # Find generated ISO
    $generatedISO = Get-ChildItem -Path $isoOutputDir -Filter '*.iso' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($generatedISO) {
        $isoSizeGB = $generatedISO.Length / 1GB
        Write-SubStep "ISO generated: $($generatedISO.Name)" -Status success
        Write-SubStep "ISO size: $($isoSizeGB.ToString('F2')) GB" -Status success
        return $generatedISO.FullName
    }
    else {
        Write-SubStep "ISO file not found in output directory" -Status warning
        return $null
    }
}

function Get-LayersToBuild {
    if ($Layers -eq 'all') {
        return $LayerDefinitions
    }

    $targetIndex = switch ($Layers) {
        'base' { 0 }
        'desktop' { 1 }
        'gpu' { 2 }
        'aitheros' { 3 }
    }

    # Build from base up to target
    return $LayerDefinitions[0..$targetIndex]
}

# Main execution
try {
    $startTime = Get-Date

    Write-StepHeader "AitherDesktop Atomic OS Full Build"

    if ($ShowOutput) {
        Write-Host "  Desktop: $DesktopEnv" -ForegroundColor Yellow
        Write-Host "  Layers: $Layers" -ForegroundColor Yellow
        Write-Host "  Tag: $Tag" -ForegroundColor Yellow
        Write-Host "  Push: $Push" -ForegroundColor Yellow
        Write-Host "  ISO: $GenerateISO" -ForegroundColor Yellow
    }

    Test-Prerequisites

    $layersToBuild = Get-LayersToBuild
    $results = @()

    foreach ($layer in $layersToBuild) {
        $result = Build-Layer -Layer $layer
        $results += $result
    }

    $isoPath = $null
    if ($GenerateISO) {
        $isoPath = Build-ISO
    }

    $totalDuration = (Get-Date) - $startTime

    Write-StepHeader "Build Complete"

    if ($ShowOutput) {
        Write-Host "`n  Summary:" -ForegroundColor Green
        Write-Host "  ─────────────────────────────────" -ForegroundColor Green

        foreach ($result in $results) {
            Write-Host "    $($result.Name): $($result.LocalTag)" -ForegroundColor White
            Write-Host "      Size: $($result.Size.ToString('F2')) GB, Time: $($result.Duration.TotalMinutes.ToString('F1'))m" -ForegroundColor DarkGray
        }

        if ($isoPath) {
            Write-Host "`n    ISO: $isoPath" -ForegroundColor White
        }

        Write-Host "`n  Total build time: $($totalDuration.TotalMinutes.ToString('F1')) minutes" -ForegroundColor Green
        Write-Host "  Status: SUCCESS" -ForegroundColor Green
    }

    return @{
        Success = $true
        Layers = $results
        ISOPath = $isoPath
        Duration = $totalDuration
    }
}
catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed

    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
