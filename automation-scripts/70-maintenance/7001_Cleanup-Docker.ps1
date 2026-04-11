#Requires -Version 7.0
<#
.SYNOPSIS
    Cleans up Docker resources to free disk space.

.DESCRIPTION
    Removes unused Docker resources including:
    - Stopped containers
    - Dangling images
    - Unused volumes
    - Build cache
    
    Supports different cleanup levels from safe to aggressive.

.PARAMETER Level
    Cleanup level: "safe", "moderate", "aggressive". Default: "safe"
    - safe: Only remove dangling images and stopped non-AitherOS containers
    - moderate: Remove all stopped containers and unused images
    - aggressive: Full system prune including volumes

.PARAMETER IncludeVolumes
    Include volume cleanup. Default: $false (dangerous!)

.PARAMETER DryRun
    Show what would be cleaned without actually doing it.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\7001_Cleanup-Docker.ps1 -DryRun
    Show what would be cleaned.

.EXAMPLE
    .\7001_Cleanup-Docker.ps1 -Level moderate -Force
    Moderate cleanup without prompts.

.NOTES
    Category: maintenance
    Dependencies: Docker
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [ValidateSet("safe", "moderate", "aggressive")]
    [string]$Level = "safe",
    
    [switch]$IncludeVolumes,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Docker Cleanup Utility" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Validate Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed."
    exit 1
}

function Get-DockerDiskUsage {
    try {
        $usage = docker system df --format "{{json .}}" | ConvertFrom-Json
        return $usage
    } catch {
        return $null
    }
}

function Format-Size {
    param([string]$Size)
    return $Size
}

# Get current disk usage
Write-Host "Current Docker Disk Usage:" -ForegroundColor Yellow
Write-Host ""

$beforeUsage = docker system df 2>&1
Write-Host $beforeUsage -ForegroundColor Gray
Write-Host ""

# Confirm if not forced
if (-not $Force -and -not $DryRun) {
    Write-Host "Cleanup Level: $Level" -ForegroundColor $(if ($Level -eq "aggressive") { "Red" } else { "Yellow" })
    
    if ($Level -eq "aggressive" -or $IncludeVolumes) {
        Write-Host ""
        Write-Warning "AGGRESSIVE cleanup or volume removal can cause DATA LOSS!"
        Write-Warning "Make sure you have backups before proceeding."
    }
    
    Write-Host ""
    $confirm = Read-Host "Proceed with cleanup? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$dryRunArg = if ($DryRun) { "--dry-run" } else { "" }

# Perform cleanup based on level
Write-Host ""
Write-Host "Performing $Level cleanup..." -ForegroundColor Yellow
Write-Host ""

$cleanedSomething = $false

switch ($Level) {
    "safe" {
        # Remove dangling images only
        Write-Host "Removing dangling images..." -ForegroundColor Gray
        if ($DryRun) {
            $danglingImages = docker images -f "dangling=true" -q 2>$null
            if ($danglingImages) {
                Write-Host "  Would remove $($danglingImages.Count) dangling image(s)" -ForegroundColor Yellow
            } else {
                Write-Host "  No dangling images to remove" -ForegroundColor Green
            }
        } else {
            docker image prune -f
            $cleanedSomething = $true
        }
        
        # Remove stopped non-AitherOS containers
        Write-Host "Removing stopped non-AitherOS containers..." -ForegroundColor Gray
        $stoppedContainers = docker ps -a --filter "status=exited" --format "{{.Names}}" 2>$null | Where-Object { $_ -notlike "aitheros-*" }
        
        if ($stoppedContainers) {
            if ($DryRun) {
                Write-Host "  Would remove: $($stoppedContainers -join ', ')" -ForegroundColor Yellow
            } else {
                foreach ($container in $stoppedContainers) {
                    docker rm $container 2>$null
                }
                $cleanedSomething = $true
            }
        } else {
            Write-Host "  No stopped non-AitherOS containers" -ForegroundColor Green
        }
    }
    
    "moderate" {
        # Remove all stopped containers
        Write-Host "Removing all stopped containers..." -ForegroundColor Gray
        if ($DryRun) {
            $stopped = docker ps -a --filter "status=exited" --format "{{.Names}}" 2>$null
            if ($stopped) {
                Write-Host "  Would remove $($stopped.Count) container(s)" -ForegroundColor Yellow
            }
        } else {
            docker container prune -f
            $cleanedSomething = $true
        }

        # Remove dangling images
        Write-Host "Removing dangling images..." -ForegroundColor Gray
        if (-not $DryRun) {
            docker image prune -f
            $cleanedSomething = $true
        }

        # Remove unused images older than 1 week
        Write-Host "Removing unused images (older than 7 days)..." -ForegroundColor Gray
        if ($DryRun) {
            Write-Host "  Would remove unused images older than 7 days" -ForegroundColor Yellow
        } else {
            docker image prune -a -f --filter "until=168h"
            $cleanedSomething = $true
        }

        # Clean build cache
        Write-Host "Cleaning build cache..." -ForegroundColor Gray
        if ($DryRun) {
            Write-Host "  Would prune build cache" -ForegroundColor Yellow
        } else {
            docker builder prune -f
            $cleanedSomething = $true
        }

        # Remove orphaned volumes (not attached to any container)
        Write-Host "Removing orphaned volumes..." -ForegroundColor Gray
        if ($DryRun) {
            $danglingVols = docker volume ls --filter "dangling=true" --format "{{.Name}}" 2>$null
            if ($danglingVols) {
                $count = ($danglingVols | Measure-Object).Count
                Write-Host "  Would remove $count orphaned volume(s)" -ForegroundColor Yellow
            } else {
                Write-Host "  No orphaned volumes" -ForegroundColor Green
            }
        } else {
            docker volume prune --all -f
            $cleanedSomething = $true
        }
    }
    
    "aggressive" {
        Write-Host "Running full system prune..." -ForegroundColor Red
        
        $pruneArgs = @("system", "prune", "-a", "-f")
        
        if ($IncludeVolumes) {
            $pruneArgs += "--volumes"
            Write-Host "  Including volumes (DANGEROUS!)" -ForegroundColor Red
        }
        
        if ($DryRun) {
            Write-Host "  Would run: docker $($pruneArgs -join ' ')" -ForegroundColor Yellow
        } else {
            docker @pruneArgs
            $cleanedSomething = $true
        }
    }
}

# Show results
Write-Host ""

if ($DryRun) {
    Write-Host "DRY RUN - No changes made" -ForegroundColor Yellow
} elseif ($cleanedSomething) {
    Write-Host "Disk Usage After Cleanup:" -ForegroundColor Yellow
    Write-Host ""
    docker system df
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Cleanup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
