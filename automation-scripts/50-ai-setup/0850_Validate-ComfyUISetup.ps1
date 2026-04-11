#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Validates ComfyUI Docker container setup for AitherCompute/MicroScheduler integration.

.DESCRIPTION
    This script performs comprehensive validation of the ComfyUI container configuration:
    - Docker compose configuration parsing
    - Container health status
    - Network connectivity
    - VRAM allocation settings
    - GPU coordinator integration
    - Port accessibility

.PARAMETER CheckOnly
    Only check status without starting containers.

.PARAMETER StartContainers
    Attempt to start the ComfyUI container if not running.

.PARAMETER Profile
    Docker compose profile to use (default: external).

.EXAMPLE
    ./0850_Validate-ComfyUISetup.ps1
    Validates ComfyUI setup and reports issues.

.EXAMPLE
    ./0850_Validate-ComfyUISetup.ps1 -StartContainers
    Validates and attempts to start ComfyUI if not running.

.NOTES
    Author: AitherOS Team
    Part of AitherZero automation scripts (0800-0899: Ecosystem startup/validation)
#>

[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$StartContainers,
    [string]$Profile = "external",
    [string]$ComposeFile = "docker-compose.aitheros.yml"
)

$ErrorActionPreference = 'Continue'
$script:ValidationResults = @()

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Add-ValidationResult {
    param(
        [string]$Category,
        [string]$Check,
        [string]$Status,  # Pass, Fail, Warn, Info
        [string]$Message,
        [string]$Details = ""
    )
    
    $script:ValidationResults += [PSCustomObject]@{
        Category = $Category
        Check    = $Check
        Status   = $Status
        Message  = $Message
        Details  = $Details
    }
    
    $icon = switch ($Status) {
        'Pass' { '✅' }
        'Fail' { '❌' }
        'Warn' { '⚠️' }
        'Info' { 'ℹ️' }
        default { '❓' }
    }
    
    $color = switch ($Status) {
        'Pass' { 'Green' }
        'Fail' { 'Red' }
        'Warn' { 'Yellow' }
        'Info' { 'Cyan' }
        default { 'White' }
    }
    
    Write-Host "$icon [$Category] ${Check}: $Message" -ForegroundColor $color
    if ($Details) {
        Write-Host "   Details: $Details" -ForegroundColor DarkGray
    }
}

function Test-PortAccessibility {
    param([string]$Host, [int]$Port, [int]$TimeoutMs = 2000)
    
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcpClient.BeginConnect($Host, $Port, $null, $null)
        $waitHandle = $asyncResult.AsyncWaitHandle
        
        if ($waitHandle.WaitOne($TimeoutMs, $false)) {
            $tcpClient.EndConnect($asyncResult)
            $tcpClient.Close()
            return $true
        }
        $tcpClient.Close()
        return $false
    }
    catch {
        return $false
    }
}

function Test-HttpEndpoint {
    param([string]$Url, [int]$TimeoutSeconds = 5)
    
    try {
        $response = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return @{ Success = $true; Response = $response }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# ============================================================================
# VALIDATION CHECKS
# ============================================================================

Write-Host "`n=== ComfyUI Docker Setup Validation ===" -ForegroundColor Cyan
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor DarkGray

# ----------------------------------------------------------------------------
# 1. Docker Environment Check
# ----------------------------------------------------------------------------
Write-Host "`n📦 Docker Environment" -ForegroundColor Yellow

$dockerVersion = docker --version 2>$null
if ($dockerVersion) {
    Add-ValidationResult -Category "Docker" -Check "Installation" -Status "Pass" -Message "Docker is installed" -Details $dockerVersion
} else {
    Add-ValidationResult -Category "Docker" -Check "Installation" -Status "Fail" -Message "Docker is not installed or not in PATH"
}

$dockerRunning = docker info 2>$null
if ($LASTEXITCODE -eq 0) {
    Add-ValidationResult -Category "Docker" -Check "Daemon" -Status "Pass" -Message "Docker daemon is running"
} else {
    Add-ValidationResult -Category "Docker" -Check "Daemon" -Status "Fail" -Message "Docker daemon is not running"
}

# Check NVIDIA runtime
$nvidiaRuntime = docker info 2>$null | Select-String -Pattern "nvidia"
if ($nvidiaRuntime) {
    Add-ValidationResult -Category "Docker" -Check "NVIDIA Runtime" -Status "Pass" -Message "NVIDIA runtime is available"
} else {
    Add-ValidationResult -Category "Docker" -Check "NVIDIA Runtime" -Status "Warn" -Message "NVIDIA runtime not detected (required for GPU)"
}

# ----------------------------------------------------------------------------
# 2. Docker Compose Configuration Check
# ----------------------------------------------------------------------------
Write-Host "`n📋 Docker Compose Configuration" -ForegroundColor Yellow

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$composePath = Join-Path $repoRoot $ComposeFile

if (Test-Path $composePath) {
    Add-ValidationResult -Category "Compose" -Check "File Exists" -Status "Pass" -Message "Found $ComposeFile"
    
    # Parse ComfyUI configuration
    $composeContent = Get-Content $composePath -Raw
    
    # Check ComfyUI service definition
    if ($composeContent -match "comfyui:") {
        Add-ValidationResult -Category "Compose" -Check "ComfyUI Service" -Status "Pass" -Message "ComfyUI service is defined"
        
        # Check profile
        if ($composeContent -match 'comfyui:[\s\S]*?profiles:\s*\[.*?"external"') {
            Add-ValidationResult -Category "Compose" -Check "ComfyUI Profile" -Status "Pass" -Message "ComfyUI is in 'external' profile"
        }
        
        # Check image
        if ($composeContent -match 'comfyui:[\s\S]*?image:\s*([^\r\n]+)') {
            $imageMatch = $composeContent -match 'image:\s*ghcr\.io/ai-dock/comfyui:([^\r\n]+)'
            Add-ValidationResult -Category "Compose" -Check "ComfyUI Image" -Status "Pass" -Message "Using ai-dock ComfyUI image"
        }
        
        # Check GPU configuration
        if ($composeContent -match 'runtime:\s*nvidia') {
            Add-ValidationResult -Category "Compose" -Check "NVIDIA Runtime" -Status "Pass" -Message "ComfyUI configured with nvidia runtime"
        } else {
            Add-ValidationResult -Category "Compose" -Check "NVIDIA Runtime" -Status "Fail" -Message "ComfyUI missing nvidia runtime configuration"
        }
        
        # Check highvram optimization
        if ($composeContent -match '--highvram') {
            Add-ValidationResult -Category "Compose" -Check "VRAM Optimization" -Status "Pass" -Message "ComfyUI configured with --highvram for fast inference"
        } else {
            Add-ValidationResult -Category "Compose" -Check "VRAM Optimization" -Status "Warn" -Message "Missing --highvram flag (may cause slow inference)"
        }
        
        # Check port mapping
        if ($composeContent -match '"8188:8188"') {
            Add-ValidationResult -Category "Compose" -Check "Port Mapping" -Status "Pass" -Message "Port 8188 is mapped correctly"
        }
        
        # Check volume mounts
        if ($composeContent -match 'D:/ComfyUI') {
            Add-ValidationResult -Category "Compose" -Check "Volume Mounts" -Status "Pass" -Message "Local ComfyUI directories are mounted"
        }
    } else {
        Add-ValidationResult -Category "Compose" -Check "ComfyUI Service" -Status "Fail" -Message "ComfyUI service not found in compose file"
    }
    
    # Check MicroScheduler configuration
    if ($composeContent -match "aither-microscheduler:") {
        Add-ValidationResult -Category "Compose" -Check "MicroScheduler" -Status "Pass" -Message "MicroScheduler service is defined"
        
        # Check COMFYUI_URL environment
        if ($composeContent -match 'COMFYUI_URL:\s*http://comfyui:8188') {
            Add-ValidationResult -Category "Compose" -Check "ComfyUI URL" -Status "Pass" -Message "MicroScheduler has correct COMFYUI_URL"
        }
        
        # Check VRAM settings
        if ($composeContent -match 'COMFYUI_MAX_VRAM_MB:\s*"(\d+)"') {
            $vramMatch = [regex]::Match($composeContent, 'COMFYUI_MAX_VRAM_MB:\s*"(\d+)"')
            $maxVram = $vramMatch.Groups[1].Value
            Add-ValidationResult -Category "Compose" -Check "VRAM Allocation" -Status "Pass" -Message "ComfyUI max VRAM: ${maxVram}MB"
        }
        
        if ($composeContent -match 'GPU_TOTAL_VRAM_MB:\s*"(\d+)"') {
            $vramMatch = [regex]::Match($composeContent, 'GPU_TOTAL_VRAM_MB:\s*"(\d+)"')
            $totalVram = $vramMatch.Groups[1].Value
            Add-ValidationResult -Category "Compose" -Check "Total VRAM" -Status "Info" -Message "Total GPU VRAM configured: ${totalVram}MB"
        }
    }
} else {
    Add-ValidationResult -Category "Compose" -Check "File Exists" -Status "Fail" -Message "Cannot find $ComposeFile"
}

# ----------------------------------------------------------------------------
# 3. Local ComfyUI Directory Check
# ----------------------------------------------------------------------------
Write-Host "`n📁 Local ComfyUI Directories" -ForegroundColor Yellow

$comfyuiPaths = @(
    @{ Path = "D:/ComfyUI"; Type = "Root" },
    @{ Path = "D:/ComfyUI/models"; Type = "Models" },
    @{ Path = "D:/ComfyUI/output"; Type = "Output" },
    @{ Path = "D:/ComfyUI/custom_nodes"; Type = "Custom Nodes" }
)

foreach ($pathInfo in $comfyuiPaths) {
    if (Test-Path $pathInfo.Path) {
        $itemCount = (Get-ChildItem -Path $pathInfo.Path -ErrorAction SilentlyContinue | Measure-Object).Count
        Add-ValidationResult -Category "Directories" -Check $pathInfo.Type -Status "Pass" -Message "Directory exists" -Details "$($pathInfo.Path) ($itemCount items)"
    } else {
        Add-ValidationResult -Category "Directories" -Check $pathInfo.Type -Status "Warn" -Message "Directory missing" -Details "Expected: $($pathInfo.Path)"
    }
}

# Check for essential models
$modelsPath = "D:/ComfyUI/models"
if (Test-Path $modelsPath) {
    $checkpoints = Get-ChildItem -Path "$modelsPath/checkpoints" -Recurse -ErrorAction SilentlyContinue | 
                   Where-Object { $_.Extension -in '.safetensors', '.ckpt' }
    if ($checkpoints) {
        Add-ValidationResult -Category "Directories" -Check "Checkpoints" -Status "Pass" -Message "Found $($checkpoints.Count) model checkpoints"
    } else {
        Add-ValidationResult -Category "Directories" -Check "Checkpoints" -Status "Warn" -Message "No model checkpoints found in models/checkpoints"
    }
}

# ----------------------------------------------------------------------------
# 4. Container Status Check
# ----------------------------------------------------------------------------
Write-Host "`n🐳 Container Status" -ForegroundColor Yellow

$comfyuiContainer = docker ps -a --filter "name=aither-comfyui" --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>$null
if ($comfyuiContainer) {
    $parts = $comfyuiContainer -split "`t"
    $status = $parts[1] -replace "^Up\s+", "Running for "
    
    if ($comfyuiContainer -match "Up") {
        Add-ValidationResult -Category "Containers" -Check "ComfyUI" -Status "Pass" -Message "Container is running" -Details $status
    } else {
        Add-ValidationResult -Category "Containers" -Check "ComfyUI" -Status "Fail" -Message "Container exists but not running" -Details $status
    }
} else {
    Add-ValidationResult -Category "Containers" -Check "ComfyUI" -Status "Info" -Message "Container not created (use --profile external to start)"
}

$microContainer = docker ps -a --filter "name=aither-microscheduler" --format "{{.Names}}\t{{.Status}}" 2>$null
if ($microContainer) {
    if ($microContainer -match "Up") {
        Add-ValidationResult -Category "Containers" -Check "MicroScheduler" -Status "Pass" -Message "Container is running"
    } else {
        Add-ValidationResult -Category "Containers" -Check "MicroScheduler" -Status "Fail" -Message "Container exists but not running"
    }
} else {
    Add-ValidationResult -Category "Containers" -Check "MicroScheduler" -Status "Info" -Message "Container not created (use --profile autonomic)"
}

# ----------------------------------------------------------------------------
# 5. Network Connectivity Check
# ----------------------------------------------------------------------------
Write-Host "`n🌐 Network Connectivity" -ForegroundColor Yellow

# Check localhost ComfyUI
$comfyuiLocalPort = Test-PortAccessibility -Host "localhost" -Port 8188
if ($comfyuiLocalPort) {
    Add-ValidationResult -Category "Network" -Check "ComfyUI Port (8188)" -Status "Pass" -Message "Port is accessible"
    
    # Try health check
    $healthResult = Test-HttpEndpoint -Url "http://localhost:8188/system_stats"
    if ($healthResult.Success) {
        Add-ValidationResult -Category "Network" -Check "ComfyUI API" -Status "Pass" -Message "API is responding"
        
        # Check VRAM from ComfyUI
        if ($healthResult.Response.devices) {
            $gpu = $healthResult.Response.devices | Where-Object { $_.type -eq "cuda" } | Select-Object -First 1
            if ($gpu) {
                $vramTotal = [math]::Round($gpu.vram_total / 1GB, 2)
                $vramFree = [math]::Round($gpu.vram_free / 1GB, 2)
                Add-ValidationResult -Category "GPU" -Check "ComfyUI VRAM" -Status "Info" -Message "VRAM: ${vramFree}GB free / ${vramTotal}GB total"
            }
        }
    } else {
        Add-ValidationResult -Category "Network" -Check "ComfyUI API" -Status "Warn" -Message "Port open but API not responding" -Details $healthResult.Error
    }
} else {
    Add-ValidationResult -Category "Network" -Check "ComfyUI Port (8188)" -Status "Info" -Message "Port not accessible (container may not be running)"
}

# Check MicroScheduler port
$microPort = Test-PortAccessibility -Host "localhost" -Port 8150
if ($microPort) {
    Add-ValidationResult -Category "Network" -Check "MicroScheduler (8150)" -Status "Pass" -Message "Port is accessible"
    
    $healthResult = Test-HttpEndpoint -Url "http://localhost:8150/health"
    if ($healthResult.Success) {
        Add-ValidationResult -Category "Network" -Check "MicroScheduler API" -Status "Pass" -Message "API is healthy"
    }
} else {
    Add-ValidationResult -Category "Network" -Check "MicroScheduler (8150)" -Status "Info" -Message "Port not accessible"
}

# ----------------------------------------------------------------------------
# 6. GPU Coordinator Source Code Check
# ----------------------------------------------------------------------------
Write-Host "`n🔧 GPU Coordinator Integration" -ForegroundColor Yellow

$gpuCoordinatorPath = Join-Path $repoRoot "AitherOS/lib/compute/gpu_coordinator.py"
if (Test-Path $gpuCoordinatorPath) {
    Add-ValidationResult -Category "Integration" -Check "GPU Coordinator" -Status "Pass" -Message "gpu_coordinator.py exists"
    
    $gpuContent = Get-Content $gpuCoordinatorPath -Raw
    
    # Check ComfyUI integration
    if ($gpuContent -match "COMFYUI") {
        Add-ValidationResult -Category "Integration" -Check "ComfyUI Support" -Status "Pass" -Message "GPU Coordinator has ComfyUI support"
    }
    
    # Check VRAM management
    if ($gpuContent -match "vram_reserved_mb|vram_max_mb") {
        Add-ValidationResult -Category "Integration" -Check "VRAM Management" -Status "Pass" -Message "VRAM allocation management is implemented"
    }
    
    # Check model caching
    if ($gpuContent -match "CachedModel|ModelCacheState") {
        Add-ValidationResult -Category "Integration" -Check "Model Caching" -Status "Pass" -Message "Model cache management is implemented"
    }
}

$microSchedulerPath = Join-Path $repoRoot "AitherOS/services/orchestration/AitherMicroScheduler.py"
if (Test-Path $microSchedulerPath) {
    $microContent = Get-Content $microSchedulerPath -Raw
    
    if ($microContent -match "GPU_COORDINATOR_AVAILABLE") {
        Add-ValidationResult -Category "Integration" -Check "MicroScheduler GPU" -Status "Pass" -Message "MicroScheduler has GPU Coordinator integration"
    }
    
    if ($microContent -match "COMFYUI_URL|ComfyUI") {
        Add-ValidationResult -Category "Integration" -Check "ComfyUI Config" -Status "Pass" -Message "MicroScheduler has ComfyUI configuration"
    }
}

# ----------------------------------------------------------------------------
# 7. Summary
# ----------------------------------------------------------------------------
Write-Host "`n" + "=" * 60 -ForegroundColor Cyan
Write-Host "📊 VALIDATION SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan

$passed = ($script:ValidationResults | Where-Object { $_.Status -eq 'Pass' }).Count
$failed = ($script:ValidationResults | Where-Object { $_.Status -eq 'Fail' }).Count
$warnings = ($script:ValidationResults | Where-Object { $_.Status -eq 'Warn' }).Count
$info = ($script:ValidationResults | Where-Object { $_.Status -eq 'Info' }).Count

if ($failed -gt 0) { $summaryColor = 'Red' } 
elseif ($warnings -gt 0) { $summaryColor = 'Yellow' } 
else { $summaryColor = 'Green' }

Write-Host "`nResults: $([char]0x2705) $passed Passed | $([char]0x274C) $failed Failed | $([char]0x26A0) $warnings Warnings | $([char]0x2139) $info Info" -ForegroundColor $summaryColor

# Recommendations
if ($failed -gt 0 -or $warnings -gt 0) {
    Write-Host "`n📋 RECOMMENDATIONS:" -ForegroundColor Yellow
    
    $failedResults = $script:ValidationResults | Where-Object { $_.Status -eq 'Fail' }
    foreach ($result in $failedResults) {
        Write-Host "  ❌ Fix: $($result.Category) - $($result.Check): $($result.Message)" -ForegroundColor Red
    }
    
    # Common fixes
    $containerMissing = $script:ValidationResults | Where-Object { $_.Category -eq 'Containers' -and $_.Status -eq 'Info' }
    if ($containerMissing) {
        Write-Host "`n  To start ComfyUI container:" -ForegroundColor Cyan
        Write-Host "    docker compose -f docker-compose.aitheros.yml --profile external up -d comfyui" -ForegroundColor White
    }
    
    $dirMissing = $script:ValidationResults | Where-Object { $_.Category -eq 'Directories' -and $_.Status -eq 'Warn' }
    if ($dirMissing) {
        Write-Host "`n  To create missing directories:" -ForegroundColor Cyan
        Write-Host "    mkdir -p D:/ComfyUI/models/checkpoints D:/ComfyUI/output D:/ComfyUI/custom_nodes" -ForegroundColor White
    }
}

# Start containers if requested
if ($StartContainers -and -not $CheckOnly) {
    $notRunning = $script:ValidationResults | Where-Object { $_.Category -eq 'Containers' -and $_.Status -ne 'Pass' }
    if ($notRunning) {
        Write-Host "`n🚀 Starting containers..." -ForegroundColor Yellow
        
        Push-Location $repoRoot
        docker compose -f $ComposeFile --profile external up -d comfyui 2>&1
        Pop-Location
        
        Write-Host "Waiting 10 seconds for ComfyUI to start..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
        
        # Re-check
        $comfyuiPort = Test-PortAccessibility -Host "localhost" -Port 8188
        if ($comfyuiPort) {
            Write-Host "✅ ComfyUI is now accessible on port 8188" -ForegroundColor Green
        } else {
            Write-Host "⚠️ ComfyUI port not yet accessible - check docker logs" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n"
return $script:ValidationResults
