<#
.SYNOPSIS
    Setup GPU/CUDA dependencies for AitherOS image generation.

.DESCRIPTION
    Installs PyTorch with proper CUDA support and ComfyUI dependencies.
    Automatically detects GPU architecture (Blackwell/Ada/Ampere) and selects
    the appropriate CUDA version.

    This script ensures:
    - PyTorch with CUDA is installed in the AitherOS venv
    - ComfyUI dependencies (einops, torchsde, kornia, etc.) are installed
    - ComfyUI path is auto-detected

.PARAMETER Force
    Force reinstall even if packages appear to be installed correctly.

.PARAMETER SkipVerify
    Skip the verification step at the end.

.EXAMPLE
    # Standard setup
    .\0059_Setup-GPUDependencies.ps1

    # Force reinstall
    .\0059_Setup-GPUDependencies.ps1 -Force

.NOTES
    Author: Aitherium
    Version: 1.0.0
    Category: Environment Setup
    
    GPU Support:
    - RTX 50xx (Blackwell): CUDA 12.8
    - RTX 40xx (Ada): CUDA 12.4
    - RTX 30xx (Ampere): CUDA 12.4
    - Older cards: CUDA 11.8
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"

# Find AitherOS root
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AitherZeroRoot = Split-Path -Parent (Split-Path -Parent $ScriptRoot)
$AitherOSRoot = Join-Path (Split-Path -Parent $AitherZeroRoot) "AitherOS"

# Handle both locations (AitherZero/library vs AitherOS/scripts)
if (-not (Test-Path (Join-Path $AitherOSRoot ".venv"))) {
    $AitherOSRoot = Join-Path (Split-Path -Parent $AitherZeroRoot) "AitherOS"
}
if (-not (Test-Path (Join-Path $AitherOSRoot ".venv"))) {
    # We're in AitherOS/scripts
    $AitherOSRoot = Split-Path -Parent $ScriptRoot
}

$VenvPython = Join-Path $AitherOSRoot ".venv\Scripts\python.exe"
$VenvPip = Join-Path $AitherOSRoot ".venv\Scripts\pip.exe"

Write-Host "================================================" -ForegroundColor Cyan
Write-Host " AitherOS GPU/CUDA Dependencies Setup" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Check venv exists
if (-not (Test-Path $VenvPython)) {
    Write-Error "AitherOS venv not found at $AitherOSRoot\.venv. Run bootstrap.ps1 first!"
    exit 1
}

Write-Host "Using venv: $AitherOSRoot\.venv" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# DETECT GPU
# ============================================================================
Write-Host "[1/4] Detecting GPU..." -ForegroundColor Yellow
$cudaVersion = "cpu"
$gpuDetected = $false

try {
    $gpuInfo = nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>$null
    if ($gpuInfo -and $LASTEXITCODE -eq 0) {
        $parts = $gpuInfo -split ","
        $gpuName = $parts[0].Trim()
        $driverVersion = $parts[1].Trim()
        $computeCap = $parts[2].Trim()
        $gpuDetected = $true
        
        Write-Host "  ✓ GPU: $gpuName" -ForegroundColor Green
        Write-Host "    Driver: $driverVersion" -ForegroundColor Gray
        Write-Host "    Compute: $computeCap" -ForegroundColor Gray
        
        # Determine CUDA version based on compute capability
        $computeMajor = [int]($computeCap -split "\.")[0]
        
        if ($computeMajor -ge 12) {
            # Blackwell (RTX 50xx) - needs CUDA 12.8
            $cudaVersion = "cu128"
            Write-Host "    → CUDA 12.8 (Blackwell architecture)" -ForegroundColor Cyan
        } elseif ($computeMajor -ge 8) {
            # Ada/Ampere (RTX 40xx/30xx)
            $cudaVersion = "cu124"
            Write-Host "    → CUDA 12.4 (Ada/Ampere architecture)" -ForegroundColor Cyan
        } else {
            # Older cards
            $cudaVersion = "cu118"
            Write-Host "    → CUDA 11.8 (Legacy architecture)" -ForegroundColor Cyan
        }
    }
} catch {
    Write-Host "  ⚠ nvidia-smi not found" -ForegroundColor Yellow
}

if (-not $gpuDetected) {
    Write-Host "  ⚠ No NVIDIA GPU detected - CPU-only mode" -ForegroundColor Yellow
}

Write-Host ""

# ============================================================================
# CHECK CURRENT PYTORCH
# ============================================================================
Write-Host "[2/4] Checking PyTorch installation..." -ForegroundColor Yellow
$installTorch = $Force

try {
    $checkScript = "import torch; print(f'{torch.__version__}|{torch.cuda.is_available()}')"
    $currentTorch = & $VenvPython -c $checkScript 2>$null
    
    if ($currentTorch -and $currentTorch -match "\|") {
        $torchParts = $currentTorch -split "\|"
        $torchVersion = $torchParts[0]
        $cudaAvailable = $torchParts[1] -eq "True"
        
        Write-Host "  Current: PyTorch $torchVersion" -ForegroundColor Gray
        Write-Host "  CUDA: $(if ($cudaAvailable) { '✓ Available' } else { '✗ Not available' })" -ForegroundColor $(if ($cudaAvailable) { 'Green' } else { 'Red' })
        
        if ($cudaAvailable -and $gpuDetected -and -not $Force) {
            Write-Host "  → Already configured correctly" -ForegroundColor Green
        } elseif ($gpuDetected -and -not $cudaAvailable) {
            Write-Host "  → Need to install CUDA version" -ForegroundColor Yellow
            $installTorch = $true
        }
    } else {
        Write-Host "  PyTorch not installed" -ForegroundColor Gray
        $installTorch = $true
    }
} catch {
    Write-Host "  PyTorch not installed" -ForegroundColor Gray
    $installTorch = $true
}

Write-Host ""

# ============================================================================
# INSTALL PYTORCH
# ============================================================================
if ($installTorch) {
    Write-Host "[3/4] Installing PyTorch with CUDA $cudaVersion..." -ForegroundColor Yellow
    Write-Host "  This may take a few minutes (2-3GB download)" -ForegroundColor Gray
    
    if ($cudaVersion -eq "cpu") {
        & $VenvPip install torch torchvision torchaudio --upgrade 2>&1 | ForEach-Object {
            if ($_ -match "Successfully") { Write-Host "  $_" -ForegroundColor Green }
        }
    } else {
        & $VenvPip install torch torchvision torchaudio --index-url "https://download.pytorch.org/whl/$cudaVersion" --upgrade 2>&1 | ForEach-Object {
            if ($_ -match "Successfully|Downloading") { Write-Host "  $_" -ForegroundColor Gray }
        }
    }
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install PyTorch"
        exit 1
    }
    Write-Host "  ✓ PyTorch installed" -ForegroundColor Green
} else {
    Write-Host "[3/4] PyTorch already installed correctly" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# INSTALL COMFYUI DEPENDENCIES
# ============================================================================
Write-Host "[4/4] Installing ComfyUI dependencies..." -ForegroundColor Yellow

# Core dependencies for ComfyUI
$comfyDeps = @(
    # PyTorch ecosystem
    "einops",
    "torchsde",
    "kornia",
    "spandrel",
    "safetensors",
    # ComfyUI frontend (required since they moved to pip packages)
    "comfyui-frontend-package",
    "comfyui-workflow-templates",
    "comfyui-embedded-docs",
    # Media processing
    "av",
    "soundfile",
    "piexif",
    "matplotlib",
    # Diffusion/ML
    "diffusers",
    "accelerate",
    "transformers",
    # Custom node dependencies
    "dill",
    "pyhocon"
)

$installed = 0
$failed = @()
foreach ($dep in $comfyDeps) {
    $result = & $VenvPip install $dep --quiet 2>&1
    if ($LASTEXITCODE -eq 0) {
        $installed++
    } else {
        $failed += $dep
    }
}

Write-Host "  ✓ Installed $installed/$($comfyDeps.Count) dependencies" -ForegroundColor Green
if ($failed.Count -gt 0) {
    Write-Host "  ⚠ Failed to install: $($failed -join ', ')" -ForegroundColor Yellow
}

# Install ComfyUI requirements.txt if found
$comfyReqFile = $null
foreach ($path in $comfyPaths) {
    $reqPath = Join-Path $path "requirements.txt"
    if (Test-Path $reqPath) {
        $comfyReqFile = $reqPath
        break
    }
}

if ($comfyReqFile) {
    Write-Host "  Installing ComfyUI requirements.txt..." -ForegroundColor Gray
    & $VenvPip install -r $comfyReqFile --quiet 2>&1 | Out-Null
    Write-Host "  ✓ ComfyUI requirements installed" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# FIND COMFYUI
# ============================================================================
Write-Host "Locating ComfyUI installation..." -ForegroundColor Yellow

$comfyPaths = @(
    "D:\ComfyUI",
    "C:\ComfyUI",
    "$env:USERPROFILE\ComfyUI",
    "D:\ai-rpg-project\ComfyUI"
)

$comfyFound = $null
foreach ($path in $comfyPaths) {
    if (Test-Path (Join-Path $path "main.py")) {
        $comfyFound = $path
        break
    }
}

if ($comfyFound) {
    Write-Host "  ✓ Found ComfyUI at: $comfyFound" -ForegroundColor Green
    
    # Set environment variable for current session
    $env:COMFYUI_PATH = $comfyFound
    
    # Suggest permanent setting
    Write-Host "  Tip: Set COMFYUI_PATH environment variable for persistence:" -ForegroundColor Gray
    Write-Host "    [Environment]::SetEnvironmentVariable('COMFYUI_PATH', '$comfyFound', 'User')" -ForegroundColor Gray
} else {
    Write-Host "  ⚠ ComfyUI not found at common locations" -ForegroundColor Yellow
    Write-Host "  Set COMFYUI_PATH environment variable to your ComfyUI installation" -ForegroundColor Gray
}

Write-Host ""

# ============================================================================
# VERIFY
# ============================================================================
if (-not $SkipVerify) {
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host " Verification" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    
    $verifyScript = @"
import torch
print(f'PyTorch: {torch.__version__}')
print(f'CUDA Available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU: {torch.cuda.get_device_name(0)}')
    props = torch.cuda.get_device_properties(0)
    print(f'VRAM: {props.total_memory / 1024**3:.1f} GB')
    print(f'Compute Capability: {props.major}.{props.minor}')
"@
    
    & $VenvPython -c $verifyScript 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor $(if ($_ -match "True|GPU:|VRAM:") { 'Green' } else { 'Gray' }) }
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host " Setup Complete!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Start ComfyUI via AitherCanvas:" -ForegroundColor Gray
Write-Host "  curl -X POST http://localhost:8108/comfyui/start" -ForegroundColor Gray
Write-Host ""
