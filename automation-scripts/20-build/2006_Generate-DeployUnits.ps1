#Requires -Version 7.0

# Stage: Build
# Dependencies: Python 3.10+, PyYAML
# Description: Generate deployment unit files (systemd + Quadlet) from services.yaml
# Tags: deploy, systemd, quadlet, podman, rocky-linux, atomic

<#
.SYNOPSIS
    Generates systemd .service and Podman Quadlet .container unit files from
    the canonical config/services.yaml.

.DESCRIPTION
    This script wraps deploy/generate-deploy-units.py, which reads the single
    source of truth (AitherOS/config/services.yaml) and generates deployment
    units for BOTH target environments:

      1. Systemd .service files  -> deploy/rocky-linux/systemd/
         (used by bootstrap-rocky.sh for server installations)

      2. Quadlet .container files -> AitherOS/apps/AitherDesktop/atomic/systemd/
         (used by build-iso.sh for bootable Atomic OS images)

    Run this after adding/removing/modifying services in services.yaml to keep
    deployment definitions in sync.

.PARAMETER Format
    Which format to generate: systemd, quadlet, or both (default: both).

.PARAMETER DryRun
    Preview what would be generated without writing files.

.PARAMETER Services
    Comma-separated list of service names to regenerate (default: all).

.EXAMPLE
    .\2006_Generate-DeployUnits.ps1
    # Generates both systemd and quadlet units for all services

.EXAMPLE
    .\2006_Generate-DeployUnits.ps1 -Format systemd
    # Generates only systemd .service files

.EXAMPLE
    .\2006_Generate-DeployUnits.ps1 -DryRun
    # Preview without writing

.EXAMPLE
    .\2006_Generate-DeployUnits.ps1 -Services "Genesis,Pulse,Secrets"
    # Regenerate specific services only
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("systemd", "quadlet", "both")]
    [string]$Format = "both",

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$Services = "",

    [Parameter()]
    [switch]$Install
)

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$RepoRoot = (Resolve-Path "$PSScriptRoot/../../../../").Path
$Generator = Join-Path $RepoRoot "deploy/generate-deploy-units.py"
$SystemdDir = Join-Path $RepoRoot "deploy/rocky-linux/systemd"
$QuadletDir = Join-Path $RepoRoot "AitherOS/apps/AitherDesktop/atomic/systemd"

if (-not (Test-Path $Generator)) {
    Write-Error "Generator not found: $Generator"
    exit 1
}

# ---------------------------------------------------------------------------
# Build command
# ---------------------------------------------------------------------------
$PythonCmd = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { "python" }

$Args = @($Generator, "--format", $Format)

if ($DryRun) {
    $Args += "--dry-run"
}

if ($Services) {
    $Args += @("--services", $Services)
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
Write-Host "`n=== AitherOS Deploy Unit Generator ===" -ForegroundColor Cyan
Write-Host "Source:  AitherOS/config/services.yaml" -ForegroundColor DarkGray
Write-Host "Format:  $Format" -ForegroundColor DarkGray

if ($Services) {
    Write-Host "Filter:  $Services" -ForegroundColor DarkGray
}

Write-Host ""

& $PythonCmd @Args

if ($LASTEXITCODE -ne 0) {
    Write-Error "Generator failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Count output
# ---------------------------------------------------------------------------
if (-not $DryRun) {
    if ($Format -in "systemd", "both") {
        $SystemdCount = (Get-ChildItem "$SystemdDir/*.service" -ErrorAction SilentlyContinue).Count
        $TargetCount = (Get-ChildItem "$SystemdDir/*.target" -ErrorAction SilentlyContinue).Count
        $TimerCount = (Get-ChildItem "$SystemdDir/*.timer" -ErrorAction SilentlyContinue).Count
        Write-Host "`nSystemd: $SystemdCount services, $TargetCount targets, $TimerCount timers" -ForegroundColor Green
    }

    if ($Format -in "quadlet", "both") {
        $ContainerCount = (Get-ChildItem "$QuadletDir/*.container" -ErrorAction SilentlyContinue).Count
        $NetworkCount = (Get-ChildItem "$QuadletDir/*.network" -ErrorAction SilentlyContinue).Count
        $VolumeCount = (Get-ChildItem "$QuadletDir/*.volume" -ErrorAction SilentlyContinue).Count
        Write-Host "Quadlet: $ContainerCount containers, $NetworkCount networks, $VolumeCount volumes" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Optional: install to local systemd (Linux only)
# ---------------------------------------------------------------------------
if ($Install -and -not $DryRun) {
    if ($IsLinux) {
        $UserSystemd = "$HOME/.config/systemd/user"
        New-Item -ItemType Directory -Path $UserSystemd -Force | Out-Null

        Copy-Item "$SystemdDir/*.service" $UserSystemd -Force
        Copy-Item "$SystemdDir/*.target" $UserSystemd -Force
        Copy-Item "$SystemdDir/*.timer" $UserSystemd -Force -ErrorAction SilentlyContinue

        & systemctl --user daemon-reload
        Write-Host "`nInstalled to $UserSystemd and reloaded systemd" -ForegroundColor Green
    }
    else {
        Write-Warning "-Install is only supported on Linux (requires systemd)"
    }
}

Write-Host "`nDone." -ForegroundColor Cyan
