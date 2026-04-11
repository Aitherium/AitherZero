#Requires -Version 7.0
<#
.SYNOPSIS
    Configures the AitherOS environment and creates required directories.

.DESCRIPTION
    Sets up the AitherOS environment:
    - Creates required directory structure
    - Configures environment variables
    - Creates default configuration files
    - Sets up Python virtual environment
    - Configures Docker settings
    - Sets up shell aliases and functions

.PARAMETER RootPath
    Root path for AitherOS. Default: Auto-detect from script location

.PARAMETER CreateVenv
    Create Python virtual environment. Default: $true

.PARAMETER ConfigureShell
    Add shell aliases and functions. Default: $true

.EXAMPLE
    .\0005_Configure-Environment.ps1 -Verbose
    
.EXAMPLE
    .\0005_Configure-Environment.ps1 -RootPath "D:\AitherOS" -CreateVenv

.NOTES
    Category: bootstrap
    Dependencies: 0001_Validate-Prerequisites.ps1
    Platform: Windows, Linux, macOS
    Exit Codes:
        0 - Success
        1 - Configuration failed
#>

[CmdletBinding()]
param(
    [string]$RootPath,
    [switch]$CreateVenv = $true,
    [switch]$ConfigureShell = $true
)

$ErrorActionPreference = 'Stop'

# Detect root path
if (-not $RootPath) {
    # Navigate up from automation-scripts/00-bootstrap to find AitherOS root
    $scriptDir = $PSScriptRoot
    $RootPath = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
}

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  AitherOS Environment Configuration" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "Root Path: $RootPath" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# DIRECTORY STRUCTURE
# ============================================================================

Write-Host "Creating Directory Structure" -ForegroundColor Yellow
Write-Host "-" * 40

$directories = @(
    # Core directories
    "AitherOS",
    "AitherOS/.venv",
    "AitherOS/config",
    "AitherOS/data",
    "AitherOS/data/strata",
    "AitherOS/data/strata/hot",
    "AitherOS/data/strata/warm",
    "AitherOS/data/strata/cold",
    "AitherOS/data/strata/cache",
    "AitherOS/services",
    "AitherOS/lib",
    
    # Docker directory
    "docker",
    "docker/genesis",
    "docker/services",
    "docker/k8s",
    
    # Library
    "AitherOS/Library",
    "AitherOS/Library/Data",
    "AitherOS/Library/Logs",
    "AitherOS/Library/Cache",
    "AitherOS/Library/Output",
    "AitherOS/Library/Docs",
    "AitherOS/Library/Models",
    "AitherOS/Library/Results",

    # Legacy Data support (for backups)
    "data/backups",
    
    # Temp and cache
    ".cache",
    ".cache/docker",
    ".cache/models"
)

foreach ($dir in $directories) {
    $fullPath = Join-Path $RootPath $dir
    if (-not (Test-Path $fullPath)) {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        Write-Host "  Created: $dir" -ForegroundColor Gray
    }
}

Write-Host "  Directory structure ready" -ForegroundColor Green
Write-Host ""

# ============================================================================
# ENVIRONMENT VARIABLES
# ============================================================================

Write-Host "Configuring Environment Variables" -ForegroundColor Yellow
Write-Host "-" * 40

$envVars = @{
    "AITHEROS_ROOT" = $RootPath
    "AITHEROS_CONFIG" = Join-Path $RootPath "AitherOS/config"
    "AITHEROS_DATA" = Join-Path $RootPath "AitherOS/Library/Data"
    "AITHEROS_LOGS" = Join-Path $RootPath "AitherOS/Library/Logs"
    "AITHER_LIBRARY" = Join-Path $RootPath "AitherOS/Library"
    "GENESIS_PORT" = "8001"
    "VEIL_PORT" = "3000"
    "VLLM_ORCHESTRATOR_URL" = "http://localhost:8200"
    "VLLM_REASONING_URL" = "http://localhost:8201"
    "VLLM_VISION_URL" = "http://localhost:8202"
    "VLLM_CODING_URL" = "http://localhost:8203"
}

foreach ($key in $envVars.Keys) {
    $value = $envVars[$key]
    
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        # Set for current session
        [Environment]::SetEnvironmentVariable($key, $value, "Process")
        # Set permanently for user
        [Environment]::SetEnvironmentVariable($key, $value, "User")
    } else {
        # Set for current session
        Set-Item -Path "env:$key" -Value $value
    }
    
    Write-Host "  $key = $value" -ForegroundColor Gray
}

Write-Host "  Environment variables configured" -ForegroundColor Green
Write-Host ""

# ============================================================================
# CONFIGURATION FILES
# ============================================================================

Write-Host "Creating Configuration Files" -ForegroundColor Yellow
Write-Host "-" * 40

# Create .env file for Docker
$envFilePath = Join-Path $RootPath ".env"
if (-not (Test-Path $envFilePath)) {
    $envContent = @"
# AitherOS Environment Configuration
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# Paths
AITHEROS_ROOT=$RootPath
COMPOSE_PROJECT_NAME=aitheros

# Ports
GENESIS_PORT=8001
VEIL_PORT=3000
CHRONICLE_PORT=8121
CANVAS_PORT=8108

# vLLM Multi-Model Endpoints
VLLM_MULTI_PORT_ORCH=8200
VLLM_MULTI_PORT_REASON=8201
VLLM_MULTI_PORT_VISION=8202
VLLM_MULTI_PORT_CODE=8203

# GPU Configuration
NVIDIA_VISIBLE_DEVICES=all
CUDA_VISIBLE_DEVICES=0

# Logging
LOG_LEVEL=INFO
LOG_FORMAT=json

# Security
AITHEROS_SECRET_KEY=change-me-in-production
ENABLE_AUTH=false
"@
    $envContent | Set-Content -Path $envFilePath
    Write-Host "  Created: .env" -ForegroundColor Gray
}

# Create docker/.env.example
$dockerEnvPath = Join-Path $RootPath "docker/.env.example"
if (-not (Test-Path $dockerEnvPath)) {
    $dockerEnvContent = @"
# Docker Compose Environment Configuration
# Copy this file to .env and customize for your environment

# ============================================================================
# REQUIRED SETTINGS
# ============================================================================

# Project name (used as container prefix)
COMPOSE_PROJECT_NAME=aitheros

# AitherOS root directory (absolute path)
AITHEROS_ROOT=/path/to/AitherOS-Fresh

# ============================================================================
# PORTS
# ============================================================================

# Genesis bootloader
GENESIS_PORT=8001

# Veil dashboard
VEIL_PORT=3000

# Chronicle logging
CHRONICLE_PORT=8121

# Canvas (ComfyUI)
CANVAS_PORT=8108

# ============================================================================
# AI/ML CONFIGURATION (vLLM Multi-Model)
# ============================================================================

# vLLM worker ports
VLLM_MULTI_PORT_ORCH=8200
VLLM_MULTI_PORT_REASON=8201
VLLM_MULTI_PORT_VISION=8202
VLLM_MULTI_PORT_CODE=8203

# GPU devices (comma-separated for multiple)
NVIDIA_VISIBLE_DEVICES=all
CUDA_VISIBLE_DEVICES=0

# ============================================================================
# SECURITY
# ============================================================================

# Secret key for signing (change in production!)
AITHEROS_SECRET_KEY=change-me-in-production

# Enable authentication
ENABLE_AUTH=false

# ============================================================================
# LOGGING
# ============================================================================

# Log level: DEBUG, INFO, WARNING, ERROR
LOG_LEVEL=INFO

# Log format: json, text
LOG_FORMAT=json
"@
    $dockerEnvContent | Set-Content -Path $dockerEnvPath
    Write-Host "  Created: docker/.env.example" -ForegroundColor Gray
}

Write-Host "  Configuration files ready" -ForegroundColor Green
Write-Host ""

# ============================================================================
# PYTHON VIRTUAL ENVIRONMENT
# ============================================================================

if ($CreateVenv) {
    Write-Host "Setting up Python Virtual Environment" -ForegroundColor Yellow
    Write-Host "-" * 40
    
    $venvPath = Join-Path $RootPath "AitherOS/.venv"
    
    # Check if Python is available
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command python -ErrorAction SilentlyContinue
    }
    
    if ($python) {
        $pythonVersion = & $python.Source --version 2>&1
        Write-Host "  Found: $pythonVersion" -ForegroundColor Gray
        
        if (-not (Test-Path (Join-Path $venvPath "pyvenv.cfg"))) {
            Write-Host "  Creating virtual environment..." -ForegroundColor Gray
            & $python.Source -m venv $venvPath
            Write-Host "  Virtual environment created at: $venvPath" -ForegroundColor Green
            
            # Determine pip path
            $pipPath = if ($IsWindows -or $env:OS -eq "Windows_NT") {
                Join-Path $venvPath "Scripts/pip.exe"
            } else {
                Join-Path $venvPath "bin/pip"
            }
            
            # Upgrade pip
            if (Test-Path $pipPath) {
                Write-Host "  Upgrading pip..." -ForegroundColor Gray
                & $pipPath install --upgrade pip setuptools wheel
            }
        } else {
            Write-Host "  Virtual environment already exists" -ForegroundColor Green
        }
    } else {
        Write-Warning "Python not found. Skipping virtual environment setup."
    }
    
    Write-Host ""
}

# ============================================================================
# SHELL CONFIGURATION
# ============================================================================

if ($ConfigureShell) {
    Write-Host "Configuring Shell Aliases" -ForegroundColor Yellow
    Write-Host "-" * 40
    
    # PowerShell profile additions
    $profileContent = @"

# ============================================================================
# AitherOS Shell Configuration
# Added by 0005_Configure-Environment.ps1
# ============================================================================

# Environment
`$env:AITHEROS_ROOT = "$RootPath"

# Aliases
Set-Alias -Name aither -Value (Join-Path `$env:AITHEROS_ROOT "bootstrap.ps1")

function Start-AitherOS {
    Push-Location `$env:AITHEROS_ROOT
    ./bootstrap.ps1 -Playbook deploy-local
    Pop-Location
}

function Stop-AitherOS {
    docker compose -f (Join-Path `$env:AITHEROS_ROOT "docker-compose.aitheros.yml") down
}

function Get-AitherStatus {
    Invoke-RestMethod -Uri "http://localhost:8001/api/services" -ErrorAction SilentlyContinue | Format-Table
}

function Open-AitherDashboard {
    Start-Process "http://localhost:3000"
}

# Quick navigation
function Enter-AitherOS { Set-Location `$env:AITHEROS_ROOT }
Set-Alias -Name cdaither -Value Enter-AitherOS

Write-Host "AitherOS environment loaded. Commands: Start-AitherOS, Stop-AitherOS, Get-AitherStatus, Open-AitherDashboard" -ForegroundColor Cyan
"@

    # Check if profile exists and doesn't already have AitherOS config
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir = Split-Path $profilePath -Parent
    
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    
    if (Test-Path $profilePath) {
        $existingProfile = Get-Content $profilePath -Raw
        if ($existingProfile -notmatch "AitherOS Shell Configuration") {
            Add-Content -Path $profilePath -Value $profileContent
            Write-Host "  Added AitherOS config to PowerShell profile" -ForegroundColor Gray
        } else {
            Write-Host "  AitherOS config already in profile" -ForegroundColor Gray
        }
    } else {
        $profileContent | Set-Content -Path $profilePath
        Write-Host "  Created PowerShell profile with AitherOS config" -ForegroundColor Gray
    }
    
    # For Linux/macOS, also create bash/zsh aliases
    if ($IsLinux -or $IsMacOS) {
        $bashAliases = @"

# AitherOS aliases
export AITHEROS_ROOT="$RootPath"
alias aither='cd \$AITHEROS_ROOT && ./bootstrap.ps1'
alias start-aither='cd \$AITHEROS_ROOT && docker compose -f docker-compose.aitheros.yml up -d'
alias stop-aither='cd \$AITHEROS_ROOT && docker compose -f docker-compose.aitheros.yml down'
alias aither-status='curl -s http://localhost:8001/api/services | jq'
alias cdaither='cd \$AITHEROS_ROOT'
"@
        
        $bashrcPath = Join-Path $HOME ".bashrc"
        if (Test-Path $bashrcPath) {
            $existingBashrc = Get-Content $bashrcPath -Raw
            if ($existingBashrc -notmatch "AitherOS aliases") {
                Add-Content -Path $bashrcPath -Value $bashAliases
                Write-Host "  Added AitherOS aliases to .bashrc" -ForegroundColor Gray
            }
        }
        
        $zshrcPath = Join-Path $HOME ".zshrc"
        if (Test-Path $zshrcPath) {
            $existingZshrc = Get-Content $zshrcPath -Raw
            if ($existingZshrc -notmatch "AitherOS aliases") {
                Add-Content -Path $zshrcPath -Value $bashAliases
                Write-Host "  Added AitherOS aliases to .zshrc" -ForegroundColor Gray
            }
        }
    }
    
    Write-Host "  Shell configuration complete" -ForegroundColor Green
    Write-Host ""
}

# ============================================================================
# DOCKER CONFIGURATION
# ============================================================================

Write-Host "Configuring Docker Settings" -ForegroundColor Yellow
Write-Host "-" * 40

# Create Docker daemon configuration if Docker is installed
$dockerInstalled = Get-Command docker -ErrorAction SilentlyContinue

if ($dockerInstalled) {
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        # Docker Desktop on Windows uses its own configuration UI
        Write-Host "  Docker Desktop detected - configure via Docker Desktop Settings" -ForegroundColor Gray
    } else {
        # Linux Docker daemon configuration
        $daemonConfigPath = "/etc/docker/daemon.json"
        
        if (-not (Test-Path $daemonConfigPath)) {
            $daemonConfig = @{
                "log-driver" = "json-file"
                "log-opts" = @{
                    "max-size" = "100m"
                    "max-file" = "3"
                }
                "storage-driver" = "overlay2"
            }
            
            # Add NVIDIA runtime if available
            if (Test-Path "/usr/bin/nvidia-container-runtime") {
                $daemonConfig["runtimes"] = @{
                    "nvidia" = @{
                        "path" = "nvidia-container-runtime"
                        "runtimeArgs" = @()
                    }
                }
                $daemonConfig["default-runtime"] = "nvidia"
            }
            
            $daemonConfig | ConvertTo-Json -Depth 5 | sudo tee $daemonConfigPath > $null
            sudo systemctl restart docker
            Write-Host "  Docker daemon configured" -ForegroundColor Gray
        } else {
            Write-Host "  Docker daemon config exists" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "  Docker not installed - skipping daemon config" -ForegroundColor Gray
}

Write-Host "  Docker configuration complete" -ForegroundColor Green
Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Environment configuration complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Quick Start Commands:" -ForegroundColor Yellow
Write-Host "    Start-AitherOS    - Start all services" -ForegroundColor White
Write-Host "    Stop-AitherOS     - Stop all services" -ForegroundColor White
Write-Host "    Get-AitherStatus  - View service status" -ForegroundColor White
Write-Host "    Open-AitherDashboard - Open web dashboard" -ForegroundColor White
Write-Host ""
Write-Host "  Next Steps:" -ForegroundColor Yellow
Write-Host "    1. Restart your terminal to load new aliases" -ForegroundColor White
Write-Host "    2. Run: ./bootstrap.ps1 -Playbook build" -ForegroundColor White
Write-Host "    3. Run: ./bootstrap.ps1 -Playbook deploy-local" -ForegroundColor White
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
