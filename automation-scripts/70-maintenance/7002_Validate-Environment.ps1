#Requires -Version 7.0
<#
.SYNOPSIS
    Validates the AitherOS environment configuration.

.DESCRIPTION
    Performs comprehensive validation of the AitherOS environment:
    - Directory structure
    - Configuration files
    - Docker setup
    - Network configuration
    - Services configuration

.PARAMETER Fix
    Attempt to fix issues found. Default: $false

.PARAMETER Verbose
    Show detailed output.

.EXAMPLE
    .\7002_Validate-Environment.ps1
    Validate environment and report issues.

.EXAMPLE
    .\7002_Validate-Environment.ps1 -Fix
    Validate and attempt to fix issues.

.NOTES
    Category: maintenance
    Dependencies: None
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [switch]$Fix
)

$ErrorActionPreference = 'SilentlyContinue'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  AitherOS Environment Validation" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "Workspace: $workspaceRoot" -ForegroundColor Gray
Write-Host ""

$issues = @()
$warnings = @()
$passed = @()

function Test-Check {
    param(
        [string]$Name,
        [scriptblock]$Check,
        [scriptblock]$FixAction,
        [string]$Category = "General"
    )
    
    $result = & $Check
    
    if ($result.Passed) {
        $script:passed += @{ Name = $Name; Details = $result.Details; Category = $Category }
        Write-Host "  ✓ $Name" -ForegroundColor Green
        if ($result.Details) {
            Write-Host "    $($result.Details)" -ForegroundColor DarkGray
        }
    } else {
        if ($result.Warning) {
            $script:warnings += @{ Name = $Name; Details = $result.Details; Category = $Category }
            Write-Host "  ⚠ $Name" -ForegroundColor Yellow
        } else {
            $script:issues += @{ Name = $Name; Details = $result.Details; Category = $Category; Fix = $FixAction }
            Write-Host "  ✗ $Name" -ForegroundColor Red
        }
        if ($result.Details) {
            Write-Host "    $($result.Details)" -ForegroundColor $(if ($result.Warning) { "Yellow" } else { "Red" })
        }
        
        # Attempt fix if requested
        if ($Fix -and $FixAction -and -not $result.Warning) {
            Write-Host "    Attempting fix..." -ForegroundColor Yellow
            try {
                & $FixAction
                Write-Host "    Fixed!" -ForegroundColor Green
            } catch {
                Write-Host "    Fix failed: $_" -ForegroundColor Red
            }
        }
    }
}

# ============================================================================
# DIRECTORY STRUCTURE
# ============================================================================

Write-Host "Directory Structure" -ForegroundColor Yellow
Write-Host "-" * 40

$requiredDirs = @(
    "AitherOS",
    "AitherOS/config",
    "AitherOS/services",
    "docker",
    "docker/genesis",
    "docker/services",
    "logs"
)

foreach ($dir in $requiredDirs) {
    $fullPath = Join-Path $workspaceRoot $dir
    Test-Check -Name "Directory: $dir" -Category "Structure" -Check {
        if (Test-Path $fullPath) {
            @{ Passed = $true }
        } else {
            @{ Passed = $false; Details = "Missing directory" }
        }
    } -FixAction {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
    }
}

Write-Host ""

# ============================================================================
# CONFIGURATION FILES
# ============================================================================

Write-Host "Configuration Files" -ForegroundColor Yellow
Write-Host "-" * 40

$configFiles = @(
    @{ Path = "AitherOS/config/services.yaml"; Required = $true }
    @{ Path = "docker-compose.aitheros.yml"; Required = $true }
    @{ Path = "docker/genesis/Dockerfile"; Required = $true }
    @{ Path = "docker/genesis/genesis.py"; Required = $true }
    @{ Path = "docker/.env"; Required = $false }
)

foreach ($file in $configFiles) {
    $fullPath = Join-Path $workspaceRoot $file.Path
    Test-Check -Name "File: $($file.Path)" -Category "Config" -Check {
        if (Test-Path $fullPath) {
            $size = (Get-Item $fullPath).Length
            @{ Passed = $true; Details = "$size bytes" }
        } elseif ($file.Required) {
            @{ Passed = $false; Details = "Required file missing" }
        } else {
            @{ Passed = $false; Warning = $true; Details = "Optional file missing" }
        }
    }
}

Write-Host ""

# ============================================================================
# DOCKER
# ============================================================================

Write-Host "Docker" -ForegroundColor Yellow
Write-Host "-" * 40

Test-Check -Name "Docker CLI installed" -Category "Docker" -Check {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) {
        @{ Passed = $true; Details = $docker.Source }
    } else {
        @{ Passed = $false; Details = "Docker not found in PATH" }
    }
}

Test-Check -Name "Docker daemon running" -Category "Docker" -Check {
    try {
        $info = docker info 2>&1
        if ($LASTEXITCODE -eq 0) {
            @{ Passed = $true }
        } else {
            @{ Passed = $false; Details = "Docker daemon not running" }
        }
    } catch {
        @{ Passed = $false; Details = "Docker daemon not responding" }
    }
}

Test-Check -Name "Docker Compose available" -Category "Docker" -Check {
    $version = docker compose version 2>&1
    if ($LASTEXITCODE -eq 0) {
        @{ Passed = $true; Details = $version -replace 'Docker Compose version ', '' }
    } else {
        @{ Passed = $false; Details = "Docker Compose plugin not found" }
    }
}

Test-Check -Name "AitherOS network exists" -Category "Docker" -Check {
    $network = docker network ls --filter "name=aitheros-net" --format "{{.Name}}" 2>$null
    if ($network -eq "aitheros-net") {
        @{ Passed = $true }
    } else {
        @{ Passed = $false; Warning = $true; Details = "Network will be created on first run" }
    }
} -FixAction {
    docker network create --subnet=172.28.0.0/16 aitheros-net
}

Write-Host ""

# ============================================================================
# IMAGES
# ============================================================================

Write-Host "Docker Images" -ForegroundColor Yellow
Write-Host "-" * 40

$requiredImages = @(
    "aitheros-genesis"
    "ghcr.io/aitheros/aitheros-service-base"
)

foreach ($image in $requiredImages) {
    Test-Check -Name "Image: $image" -Category "Images" -Check {
        $exists = docker images --filter "reference=$image*" --format "{{.Repository}}:{{.Tag}}" 2>$null
        if ($exists) {
            @{ Passed = $true; Details = $exists | Select-Object -First 1 }
        } else {
            @{ Passed = $false; Warning = $true; Details = "Image not built yet" }
        }
    }
}

Write-Host ""

# ============================================================================
# SERVICES YAML
# ============================================================================

Write-Host "Services Configuration" -ForegroundColor Yellow
Write-Host "-" * 40

$servicesYaml = Join-Path $workspaceRoot "AitherOS/config/services.yaml"

Test-Check -Name "services.yaml parseable" -Category "Services" -Check {
    if (Test-Path $servicesYaml) {
        try {
            # Try to read and count services
            $content = Get-Content $servicesYaml -Raw
            $serviceCount = ([regex]::Matches($content, '^\s{2}\w+:', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
            @{ Passed = $true; Details = "~$serviceCount services defined" }
        } catch {
            @{ Passed = $false; Details = "Failed to parse: $_" }
        }
    } else {
        @{ Passed = $false; Details = "File not found" }
    }
}

Test-Check -Name "Service groups defined" -Category "Services" -Check {
    if (Test-Path $servicesYaml) {
        $content = Get-Content $servicesYaml -Raw
        if ($content -match 'groups:') {
            $groups = @("minimal", "core", "full") | Where-Object { $content -match "$_`:" }
            @{ Passed = $true; Details = "Groups: $($groups -join ', ')" }
        } else {
            @{ Passed = $false; Warning = $true; Details = "No service groups defined" }
        }
    } else {
        @{ Passed = $false; Details = "services.yaml not found" }
    }
}

Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

$passedCount = $passed.Count
$warningCount = $warnings.Count
$issueCount = $issues.Count
$totalCount = $passedCount + $warningCount + $issueCount

Write-Host "Validation Summary:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  ✓ Passed:   $passedCount" -ForegroundColor Green
Write-Host "  ⚠ Warnings: $warningCount" -ForegroundColor Yellow
Write-Host "  ✗ Issues:   $issueCount" -ForegroundColor $(if ($issueCount -gt 0) { "Red" } else { "Gray" })
Write-Host ""
Write-Host "  Total Checks: $totalCount" -ForegroundColor Gray

if ($issueCount -gt 0) {
    Write-Host ""
    Write-Host "Issues to resolve:" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host "  - $($issue.Name): $($issue.Details)" -ForegroundColor Red
    }
    
    if (-not $Fix) {
        Write-Host ""
        Write-Host "Run with -Fix to attempt automatic fixes." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan

exit $(if ($issueCount -gt 0) { 1 } else { 0 })
