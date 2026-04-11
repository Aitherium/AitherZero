#Requires -Version 7.0
<#
.SYNOPSIS
    Setup and start the vLLM Multi-Model stack.

.DESCRIPTION
    Cross-platform script that provisions and starts the vLLM multi-model
    Docker stack for local GPU-accelerated inference. Handles:
    - Creating required external Docker volumes (aither-hf-cache, aither-vllm-cache)
    - Starting the multi-model compose stack (Orchestrator, Reasoning, Vision, Coding)
    - Health-checking all 4 vLLM workers
    - Idempotent: safe to run multiple times

    Workers and their default models:
      Orchestrator (8200): cerebras/GLM-4.7-Flash-REAP-23B-A3B
      Reasoning    (8201): cerebras/Qwen3-Coder-REAP-25B-A3B
      Vision       (8202): Qwen/Qwen2.5-VL-7B-Instruct
      Coding       (8203): deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct

.PARAMETER ComposeFile
    Path to the vLLM multi-model compose file. Default: auto-detected from workspace root.

.PARAMETER SkipHealthCheck
    Skip waiting for health checks after starting.

.PARAMETER ShowOutput
    Display verbose output during execution.

.EXAMPLE
    .\5001_Setup-vLLM.ps1
    # Starts the full vLLM multi-model stack

.EXAMPLE
    .\5001_Setup-vLLM.ps1 -SkipHealthCheck
    # Starts without waiting for health

.NOTES
    Category: ai-setup
    Dependencies: Docker
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [string]$ComposeFile,
    [switch]$SkipHealthCheck,
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Continue'

# ============================================================================
# PLATFORM DETECTION
# ============================================================================

$platform = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows' }
             elseif ($IsLinux) { 'Linux' }
             elseif ($IsMacOS) { 'macOS' }
             else { 'Unknown' }

Write-Host "[vLLM Setup] Platform: $platform" -ForegroundColor Cyan

# ============================================================================
# RESOLVE PATHS
# ============================================================================

# Find workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = $scriptDir
for ($i = 0; $i -lt 5; $i++) {
    if (Test-Path (Join-Path $workspaceRoot "docker-compose.aitheros.yml")) { break }
    $workspaceRoot = Split-Path $workspaceRoot -Parent
}

if (-not $ComposeFile) {
    $ComposeFile = Join-Path $workspaceRoot "docker-compose.vllm-multimodel.yml"
}

if (-not (Test-Path $ComposeFile)) {
    Write-Host "[ERROR] vLLM compose file not found: $ComposeFile" -ForegroundColor Red
    exit 1
}

Write-Host "[vLLM Setup] Compose file: $ComposeFile" -ForegroundColor Gray

# ============================================================================
# CHECK DOCKER
# ============================================================================

Write-Host "[vLLM Setup] Checking Docker..." -ForegroundColor Yellow

$dockerOk = $false
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerOk = $true }
} catch { }

if (-not $dockerOk) {
    Write-Host "[ERROR] Docker is not running. Please start Docker first." -ForegroundColor Red

    if ($platform -eq 'Windows') {
        Write-Host "  Try: Start Docker Desktop" -ForegroundColor Gray
    } elseif ($platform -eq 'Linux') {
        Write-Host "  Try: sudo systemctl start docker" -ForegroundColor Gray
    } elseif ($platform -eq 'macOS') {
        Write-Host "  Try: open -a Docker" -ForegroundColor Gray
    }
    exit 1
}

# ============================================================================
# CHECK GPU AVAILABILITY
# ============================================================================

Write-Host "[vLLM Setup] Checking GPU..." -ForegroundColor Yellow

$gpuAvailable = $false
try {
    $nvidiaInfo = docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi 2>&1
    if ($LASTEXITCODE -eq 0) {
        $gpuAvailable = $true
        Write-Host "  GPU detected via NVIDIA Container Toolkit" -ForegroundColor Green
    }
} catch { }

if (-not $gpuAvailable) {
    Write-Host "  [WARN] No GPU detected. vLLM requires an NVIDIA GPU with the Container Toolkit." -ForegroundColor Yellow
    Write-Host "  Install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/" -ForegroundColor Gray

    if ($platform -eq 'Linux') {
        Write-Host "  Try: sudo apt install -y nvidia-container-toolkit && sudo systemctl restart docker" -ForegroundColor Gray
    }
    exit 2
}

# ============================================================================
# CREATE EXTERNAL VOLUMES
# ============================================================================

Write-Host "[vLLM Setup] Creating external Docker volumes..." -ForegroundColor Yellow

$requiredVolumes = @("aither-hf-cache", "aither-vllm-cache")
foreach ($vol in $requiredVolumes) {
    $exists = docker volume ls -q | Where-Object { $_ -eq $vol }
    if (-not $exists) {
        docker volume create --name $vol | Out-Null
        Write-Host "  Created: $vol" -ForegroundColor Green
    } else {
        Write-Host "  Exists:  $vol" -ForegroundColor DarkGray
    }
}

# ============================================================================
# CREATE NETWORK (if not exists)
# ============================================================================

$networkExists = docker network ls -q --filter name=aither-network
if (-not $networkExists) {
    Write-Host "[vLLM Setup] Creating aither-network..." -ForegroundColor Yellow
    docker network create aither-network | Out-Null
    Write-Host "  Created: aither-network" -ForegroundColor Green
}

# ============================================================================
# START vLLM STACK
# ============================================================================

Write-Host "[vLLM Setup] Starting Multi-Model vLLM Stack..." -ForegroundColor Yellow

Push-Location $workspaceRoot

$composeCmd = "docker compose -f `"$ComposeFile`" up -d"
Write-Host "  Running: $composeCmd" -ForegroundColor DarkGray

Invoke-Expression $composeCmd 2>&1 | ForEach-Object {
    if ($ShowOutput -or $_ -match "error|Error|ERROR|failed|Failed") {
        Write-Host "  $_" -ForegroundColor $(if ($_ -match "error|Error|ERROR|failed|Failed") { 'Yellow' } else { 'Gray' })
    }
}

Pop-Location

# ============================================================================
# HEALTH CHECK
# ============================================================================

if (-not $SkipHealthCheck) {
    Write-Host "[vLLM Setup] Waiting for workers to become healthy..." -ForegroundColor Yellow
    Write-Host "  (vLLM models can take 5-10 minutes to load on first start)" -ForegroundColor DarkGray

    $workers = @(
        @{ Name = "Orchestrator"; Port = 8200 }
        @{ Name = "Reasoning";    Port = 8201 }
        @{ Name = "Vision";       Port = 8202 }
        @{ Name = "Coding";       Port = 8203 }
    )

    $maxWait = 600  # 10 minutes
    $interval = 15

    foreach ($worker in $workers) {
        $healthy = $false
        $waited = 0

        while ($waited -lt $maxWait -and -not $healthy) {
            try {
                $response = Invoke-RestMethod -Uri "http://localhost:$($worker.Port)/health" -TimeoutSec 5 -ErrorAction SilentlyContinue
                $healthy = $true
            } catch {
                $waited += $interval
                if (($waited % 60) -eq 0) {
                    Write-Host "    $($worker.Name): waiting... ($waited`s)" -ForegroundColor DarkGray
                }
                Start-Sleep -Seconds $interval
            }
        }

        if ($healthy) {
            Write-Host "  ✓ $($worker.Name) (port $($worker.Port)) — healthy" -ForegroundColor Green
        } else {
            Write-Host "  ✗ $($worker.Name) (port $($worker.Port)) — not healthy after ${maxWait}s" -ForegroundColor Red
        }
    }
}

# ============================================================================
# SUCCESS
# ============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "         vLLM MULTI-MODEL STACK READY                          " -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Orchestrator: http://localhost:8200/v1/models" -ForegroundColor White
Write-Host "  Reasoning:    http://localhost:8201/v1/models" -ForegroundColor White
Write-Host "  Vision:       http://localhost:8202/v1/models" -ForegroundColor White
Write-Host "  Coding:       http://localhost:8203/v1/models" -ForegroundColor White
Write-Host ""

exit 0
