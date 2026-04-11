<#
.SYNOPSIS
    Fixes common ComfyUI CUDA and PyTorch issues on the local machine.

.DESCRIPTION
    This script helps troubleshoot and fix "CUDA error: no kernel image is available" and other
    PyTorch/CUDA mismatch errors in a local ComfyUI installation.
    It can reinstall PyTorch with specific CUDA versions (11.8 or 12.1) and check driver status.

.PARAMETER ComfyPath
    Path to the ComfyUI installation. Defaults to "C:\ComfyUI".

.PARAMETER CudaVersion
    The CUDA version to target for PyTorch. Options: "11.8", "12.1", "12.4", "12.6". Default is "12.4".
    Use "12.4" or "12.6" for RTX 40/50 series.
    Use "11.8" for older GPUs (Pascal/10-series).

.EXAMPLE
    .\0733_Fix-ComfyUI-CUDA.ps1 -CudaVersion "12.4"
#>

[CmdletBinding()]
param(
    [string]$ComfyPath,
    [ValidateSet("11.8", "12.1", "12.4", "12.6", "12.8")]
    [string]$CudaVersion = "12.8"
)

. "$PSScriptRoot/_init.ps1"

# Ensure Feature is Enabled
Ensure-FeatureEnabled -Section "Features" -Key "AI.ComfyUI" -Name "ComfyUI"

$Config = Get-AitherConfigs -ErrorAction SilentlyContinue

$ErrorActionPreference = "Stop"

# Auto-detect ComfyUI location if not provided
if ([string]::IsNullOrWhiteSpace($ComfyPath)) {
    # Try Config first
    if ($Config.Features.AI.ComfyUI.InstallPath) {
        $ComfyPath = $Config.Features.AI.ComfyUI.InstallPath
    }
}

if ([string]::IsNullOrWhiteSpace($ComfyPath)) {
    $PossiblePaths = @("E:\ComfyUI", "D:\ComfyUI", "C:\ComfyUI", "$env:USERPROFILE\ComfyUI")
    foreach ($path in $PossiblePaths) {
        if (Test-Path $path) {
            $ComfyPath = $path
            Write-Host "Auto-detected ComfyUI at: $ComfyPath" -ForegroundColor Cyan
            break
        }
    }
    # Fallback
    if ([string]::IsNullOrWhiteSpace($ComfyPath)) {
        if (Test-Path "E:\") {
            $ComfyPath = "E:\ComfyUI"
        }
        elseif (Test-Path "D:\") {
            $ComfyPath = "D:\ComfyUI"
        }
        else {
            $ComfyPath = "C:\ComfyUI"
        }
    }
}

function Write-Header {
    param([string]$Message)
    Write-Host -ForegroundColor Cyan "`n=== $Message ==="
}

function Write-Success {
    param([string]$Message)
    Write-Host -ForegroundColor Green "SUCCESS: $Message"
}

function Write-Warning {
    param([string]$Message)
    Write-Host -ForegroundColor Yellow "WARNING: $Message"
}

# 1. Check Environment
Write-Header "Checking Environment"

if (-not (Test-Path $ComfyPath)) {
    throw "ComfyUI directory not found at $ComfyPath. Please specify the correct path with -ComfyPath."
}

$VenvPath = Join-Path $ComfyPath "venv"
$PythonPath = Join-Path $VenvPath "Scripts\python.exe"

if (-not (Test-Path $PythonPath)) {
    # Try looking for python_embeded
    $PythonPath = Join-Path $ComfyPath "python_embeded\python.exe"
    if (-not (Test-Path $PythonPath)) {
        throw "Could not find python.exe in venv or python_embeded at $ComfyPath."
    }
}

Write-Host "Found Python at: $PythonPath"

# Check Python Version
$PyVer = & $PythonPath --version
Write-Host "Python Version: $PyVer"

# Check Architecture (Must be 64-bit)
$Arch = & $PythonPath -c "import struct; print(struct.calcsize('P') * 8)"
Write-Host "Architecture: $Arch-bit"
if ($Arch -ne "64") {
    throw "Detected $Arch-bit Python. PyTorch requires 64-bit Python. Please reinstall 64-bit Python."
}

# Upgrade pip
Write-Header "Upgrading pip"
& $PythonPath -m pip install --upgrade pip

# 2. Check GPU Drivers
Write-Header "Checking GPU Drivers"
try {
    $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if ($nvidiaSmi) {
        & nvidia-smi
    }
    else {
        Write-Warning "nvidia-smi not found. Ensure NVIDIA drivers are installed and in PATH."
    }
}
catch {
    Write-Warning "Failed to run nvidia-smi."
}

# 3. Reinstall PyTorch
Write-Header "Reinstalling PyTorch (CUDA $CudaVersion)"

$TorchUrl = ""
switch ($CudaVersion) {
    "11.8" { $TorchUrl = "https://download.pytorch.org/whl/cu118" }
    "12.1" { $TorchUrl = "https://download.pytorch.org/whl/cu121" }
    "12.4" { $TorchUrl = "https://download.pytorch.org/whl/cu124" }
    "12.6" { $TorchUrl = "https://download.pytorch.org/whl/cu126" }
    "12.8" { $TorchUrl = "https://download.pytorch.org/whl/cu128" }
}

Write-Host "Uninstalling existing torch packages..."
& $PythonPath -m pip uninstall -y torch torchvision torchaudio

Write-Host "Installing PyTorch with CUDA $CudaVersion from $TorchUrl..."
& $PythonPath -m pip install torch torchvision torchaudio --index-url $TorchUrl

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Standard installation failed. Trying with --pre (Pre-release) in case Python version is too new..."
    & $PythonPath -m pip install torch torchvision torchaudio --index-url $TorchUrl --pre
}

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Pre-release failed. Trying Nightly builds (often needed for Python 3.13+)..."
    # Nightly URL format: https://download.pytorch.org/whl/nightly/cu124 (matches version)
    # Note: Nightly usually has newer CUDA versions.
    $NightlyUrl = "https://download.pytorch.org/whl/nightly/cu$($CudaVersion.Replace('.',''))"
    Write-Host "Trying Nightly URL: $NightlyUrl"
    & $PythonPath -m pip install torch torchvision torchaudio --index-url $NightlyUrl --pre
}

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Nightly failed. Trying standard PyPI (might get CPU version, but better than nothing)..."
    & $PythonPath -m pip install torch torchvision torchaudio
}

if ($LASTEXITCODE -eq 0) {
    Write-Success "PyTorch reinstalled successfully."

    # Check if we got a CPU version
    $CheckCpu = & $PythonPath -c "import torch; print('CPU' if not torch.cuda.is_available() else 'CUDA')"
    if ($CheckCpu -eq "CPU") {
        Write-Warning "INSTALLED CPU VERSION! This will be very slow."
        Write-Warning "It seems Python 3.13+ does not yet have stable CUDA wheels."
        Write-Warning "RECOMMENDATION: Downgrade to Python 3.11 or 3.12 for stable CUDA support."
    }
    else {
        # Check for CUDA capability mismatch (Kernel Image Error)
        # We try to run a tiny tensor operation on CUDA
        Write-Host "Testing CUDA tensor operation..."
        try {
            & $PythonPath -c "import torch; x = torch.tensor([1.0]).cuda(); print('Tensor Test: Success')"
        }
        catch {
            Write-Warning "CUDA is available but tensor operation FAILED."
            Write-Warning "This usually means 'no kernel image is available' (Architecture Mismatch)."
            Write-Warning "Your GPU might be too old for CUDA $CudaVersion."
            Write-Warning "RECOMMENDATION: Run this script again with -CudaVersion '11.8'"
        }
    }
}
else {
    throw "Failed to install PyTorch."
}

# 4. Verify Installation
Write-Header "Verifying Installation"
$VerifyScript = "import torch; print(f'Torch: {torch.__version__}'); print(f'CUDA Available: {torch.cuda.is_available()}'); print(f'CUDA Version: {torch.version.cuda}'); print(f'Device: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else ''}')"

& $PythonPath -c $VerifyScript

Write-Header "Instructions"
Write-Host "If you still see 'no kernel image' errors:"
Write-Host "1. Try running this script again with -CudaVersion '11.8' (better for 10-series/Pascal cards)."
Write-Host "2. Ensure your NVIDIA drivers are fully up to date."
Write-Host "3. If using ComfyUI portable, ensure you are not mixing system python with embedded python."
