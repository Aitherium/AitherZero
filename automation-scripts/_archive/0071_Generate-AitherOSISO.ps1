<#
.SYNOPSIS
    Generates bootable ISO from AitherOS container image.
    
.DESCRIPTION
    Uses bootc-image-builder to create a bootable ISO from the
    AitherOS container image. The ISO can be used for bare-metal
    installation or VM deployment.
    
.PARAMETER ImageName
    Container image to convert (default: ghcr.io/aitherium/aitheros:latest)

.PARAMETER OutputDir
    Directory for the generated ISO (default: ./build/iso)

.PARAMETER Variant
    Build variant: minimal, desktop, server (default: desktop)

.PARAMETER Kickstart
    Path to custom kickstart file

.PARAMETER ShowOutput
    Show verbose build output

.EXAMPLE
    ./0071_Generate-AitherOSISO.ps1 -ShowOutput
    
.EXAMPLE
    ./0071_Generate-AitherOSISO.ps1 -Variant server -OutputDir ./releases
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ImageName = 'ghcr.io/aitherium/aitheros:latest',
    
    [Parameter()]
    [string]$OutputDir = './build/iso',
    
    [Parameter()]
    [ValidateSet('minimal', 'desktop', 'server')]
    [string]$Variant = 'desktop',
    
    [Parameter()]
    [string]$Kickstart,
    
    [Parameter()]
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'

# Source shared utilities
$initPath = Join-Path $PSScriptRoot '_init.ps1'
if (Test-Path $initPath) {
    . $initPath
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           AitherOS ISO Generator                              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Verify tools
$hasBootcBuilder = $null -ne (Get-Command 'bootc-image-builder' -ErrorAction SilentlyContinue) -or
                   $null -ne (podman images --format '{{.Repository}}' 2>$null | Where-Object { $_ -like '*bootc-image-builder*' })

if (-not $hasBootcBuilder) {
    Write-Host ""
    Write-Host "bootc-image-builder not found. Installing via container..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "The ISO will be built using:" -ForegroundColor Cyan
    Write-Host "  quay.io/centos-bootc/bootc-image-builder:latest" -ForegroundColor DarkGray
}

# Create output directory
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Image:      $ImageName"
Write-Host "  Output:     $OutputDir"
Write-Host "  Variant:    $Variant"

# Build ISO using bootc-image-builder container
$buildArgs = @(
    'run'
    '--rm'
    '--privileged'
    '--pull=newer'
    '-v', "${OutputDir}:/output"
    '-v', '/var/lib/containers/storage:/var/lib/containers/storage'
    'quay.io/centos-bootc/bootc-image-builder:latest'
    '--type', 'iso'
    '--output', '/output'
    $ImageName
)

if ($Kickstart) {
    $ksPath = [System.IO.Path]::GetFullPath($Kickstart)
    $buildArgs = $buildArgs[0..($buildArgs.Length - 2)] + @('-v', "${ksPath}:/config.ks:ro", '--config', '/config.ks') + @($ImageName)
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
Write-Host "  Generating ISO (this may take 10-30 minutes)..." -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
Write-Host ""
Write-Host "  Command: podman $($buildArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

$process = Start-Process -FilePath 'podman' -ArgumentList $buildArgs -NoNewWindow -Wait -PassThru

if ($process.ExitCode -ne 0) {
    Write-Host ""
    Write-Host "  ✗ ISO generation failed" -ForegroundColor Red
    exit 1
}

# Find the generated ISO
$isoFile = Get-ChildItem -Path $OutputDir -Filter '*.iso' | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($isoFile) {
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
    Write-Host "  ✓ ISO Generated Successfully!" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  File: $($isoFile.FullName)" -ForegroundColor Cyan
    Write-Host "  Size: $([math]::Round($isoFile.Length / 1GB, 2)) GB" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "    1. Write to USB: dd if=$($isoFile.Name) of=/dev/sdX bs=4M status=progress"
    Write-Host "    2. Or boot in VM with the ISO attached"
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "  ✗ ISO file not found in output directory" -ForegroundColor Red
    exit 1
}
