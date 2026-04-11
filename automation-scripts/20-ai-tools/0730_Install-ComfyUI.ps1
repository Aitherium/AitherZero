#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: Git, Python
# Description: Installs ComfyUI and ComfyUI Manager
# Tags: ai, comfyui, image-generation, flux

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$InstallPath,

    [Parameter()]
    [switch]$SkipRequirements,

    [Parameter()]
    [ValidateSet("11.8", "12.1", "12.4", "12.6", "12.8")]
    [string]$CudaVersion = "12.8"
)

. "$PSScriptRoot/_init.ps1"

# Set default InstallPath if not provided
if ([string]::IsNullOrEmpty($InstallPath)) {
    if ($IsWindows) {
        # 1. Check for existing installation
        $PossiblePaths = @("E:\ComfyUI", "D:\ComfyUI", "C:\ComfyUI", "$env:USERPROFILE\ComfyUI")
        foreach ($path in $PossiblePaths) {
            if (Test-Path $path) {
                $InstallPath = $path
                Write-Host "Found existing ComfyUI at: $InstallPath" -ForegroundColor Cyan
                break
            }
        }

        # 2. If not found, pick best drive for new install
        if ([string]::IsNullOrEmpty($InstallPath)) {
            if (Test-Path "E:\") {
                $InstallPath = "E:\ComfyUI"
            }
            elseif (Test-Path "D:\") {
                $InstallPath = "D:\ComfyUI"
            }
            else {
                $InstallPath = "C:\ComfyUI"
            }
            Write-Host "Targeting install path: $InstallPath" -ForegroundColor Cyan
        }
    }
    else {
        $InstallPath = Join-Path $env:HOME "ComfyUI"
    }
}

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0730_Install-ComfyUI'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting ComfyUI installation..."

# Determine Torch URL based on CudaVersion
$TorchUrl = ""
switch ($CudaVersion) {
    "11.8" { $TorchUrl = "https://download.pytorch.org/whl/cu118" }
    "12.1" { $TorchUrl = "https://download.pytorch.org/whl/cu121" }
    "12.4" { $TorchUrl = "https://download.pytorch.org/whl/cu124" }
    "12.6" { $TorchUrl = "https://download.pytorch.org/whl/cu126" }
    "12.8" { $TorchUrl = "https://download.pytorch.org/whl/cu128" }
}

try {
    # 1. Check Prerequisites
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed. Please run 0207_Install-Git.ps1 first."
    }

    # Check Disk Space (Windows specific check, skipped on others if complex)
    if ($IsWindows) {
        try {
            $drive = (Get-Item $env:USERPROFILE).Root.Name.TrimEnd('\') # Gets "C:" usually
            $disk = Get-PSDrive $drive.TrimEnd(':') -ErrorAction SilentlyContinue
            if ($disk -and $disk.Free -lt 10GB) {
                Write-ScriptLog "CRITICAL WARNING: Low disk space detected on drive ${drive}. Free space: $([math]::Round($disk.Free / 1GB, 2)) GB." "Warning"
                Write-ScriptLog "PyTorch installation requires ~3GB download + ~5GB extraction space. You may run out of space." "Warning"
                if (-not $PSCmdlet.ShouldProcess($drive, "Continue despite low disk space")) {
                    throw "Installation aborted due to low disk space."
                }
            }
        }
        catch {
            Write-ScriptLog "Could not verify disk space: $_" "Warning"
        }
    }

    # Check for python or python3
    $pythonCmd = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { "python3" }
    if (-not $pythonCmd) {
        throw "Python is not installed. Please run 0206_Install-Python.ps1 first."
    }

    # 2. Clone Repository
    if ($PSCmdlet.ShouldProcess($InstallPath, "Clone ComfyUI")) {
        if (Test-Path $InstallPath) {
            Write-ScriptLog "Directory exists at $InstallPath. Pulling latest changes..."
            Push-Location $InstallPath
            try {
                git pull
            }
            finally {
                Pop-Location
            }
        }
        else {
            Write-ScriptLog "Cloning ComfyUI to $InstallPath..."
            git clone https://github.com/comfyanonymous/ComfyUI $InstallPath
        }
    }

    # 3. Install ComfyUI Manager (Essential)
    $managerPath = Join-Path $InstallPath "custom_nodes/ComfyUI-Manager"
    Write-Host "Debug: Checking ComfyUI Manager at $managerPath" -ForegroundColor Magenta
    if ($PSCmdlet.ShouldProcess($managerPath, "Install ComfyUI Manager")) {
        if (-not (Test-Path $managerPath)) {
            Write-ScriptLog "Installing ComfyUI Manager..."
            git clone https://github.com/ltdrdata/ComfyUI-Manager.git $managerPath
        }
        else {
            Write-ScriptLog "Updating ComfyUI Manager..."
            Push-Location $managerPath
            try {
                git pull
            }
            finally {
                Pop-Location
            }
        }
    }
    Write-Host "Debug: ComfyUI Manager step completed" -ForegroundColor Magenta

    # 4. Install Requirements
    Write-Host "Debug: Starting Requirements step" -ForegroundColor Magenta
    if (-not $SkipRequirements -and $PSCmdlet.ShouldProcess($InstallPath, "Install Python Requirements")) {
        Write-ScriptLog "Setting up Python Virtual Environment..."
        Push-Location $InstallPath
        try {
            # Venv Setup
            $venvDir = Join-Path $InstallPath "venv"
            if (-not (Test-Path $venvDir)) {
                Write-ScriptLog "Creating virtual environment at $venvDir..."
                & $pythonCmd -m venv venv
            }

            # Determine Venv Python/Pip paths
            if ($IsWindows) {
                $venvPython = Join-Path $venvDir "Scripts/python.exe"
                $venvPip = Join-Path $venvDir "Scripts/pip.exe"
            }
            else {
                $venvPython = Join-Path $venvDir "bin/python"
                $venvPip = Join-Path $venvDir "bin/pip"
            }

            if (-not (Test-Path $venvPython)) {
                throw "Failed to create virtual environment or find python binary at $venvPython"
            }

            Write-ScriptLog "Installing Python requirements into venv..."

            # Clean up corrupted packages (folders starting with ~)
            $sitePackages = Join-Path $venvDir "Lib/site-packages"
            if (Test-Path $sitePackages) {
                Get-ChildItem $sitePackages -Filter "~*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            # Upgrade pip first
            Write-Host "Upgrading pip..." -ForegroundColor Cyan
            & $venvPython -m pip install --upgrade pip | Out-Host

            # Check if PyTorch is already installed and correct
            $shouldInstallTorch = $true
            try {
                $checkScript = "import torch; print(f'{torch.__version__}|{torch.version.cuda}')"
                $currentTorch = & $venvPython -c $checkScript 2>$null
                if ($currentTorch -match "(.+)\|(.+)") {
                    $installedVer = $matches[1]
                    $installedCuda = $matches[2]
                    # Simple check: if installed cuda matches requested cuda version
                    if ($installedCuda -eq $CudaVersion) {
                        Write-ScriptLog "PyTorch is already installed with CUDA $installedCuda. Skipping reinstall."
                        $shouldInstallTorch = $false
                    }
                }
            }
            catch {
                # Ignore errors, assume not installed
            }

            if ($shouldInstallTorch) {
                # Install torch first (attempting to detect CUDA)
                # RTX 50-series requires CUDA 12.4+ (Targeting $CudaVersion)
                Write-ScriptLog "Installing PyTorch (using CUDA $CudaVersion for compatibility)..."
                Write-Host "Downloading and Installing PyTorch from $TorchUrl. This may take several minutes..." -ForegroundColor Cyan

                # 1. Try Standard Install
                & $venvPip install torch torchvision torchaudio --index-url $TorchUrl --upgrade --force-reinstall --no-cache-dir | Out-Host

                if ($LASTEXITCODE -ne 0) {
                    Write-Host "Standard installation failed. Trying with --pre (Pre-release)..." -ForegroundColor Yellow
                    & $venvPip install torch torchvision torchaudio --index-url $TorchUrl --pre --upgrade --force-reinstall --no-cache-dir | Out-Host
                }

                if ($LASTEXITCODE -ne 0) {
                    Write-Host "Pre-release failed. Trying Nightly builds (Required for RTX 50-series/Blackwell)..." -ForegroundColor Yellow
                    $NightlyUrl = "https://download.pytorch.org/whl/nightly/cu$($CudaVersion.Replace('.',''))"
                    Write-Host "Trying Nightly URL: $NightlyUrl"
                    & $venvPip install torch torchvision torchaudio --index-url $NightlyUrl --pre --upgrade --force-reinstall --no-cache-dir | Out-Host
                }

                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to install PyTorch after multiple attempts (Standard, Pre-release, Nightly)."
                }

                # 2. Verify Installation (Tensor Test)
                Write-Host "Verifying PyTorch installation..." -ForegroundColor Cyan
                try {
                    $verifyCmd = "import torch; x = torch.tensor([1.0]).cuda(); print(f'CUDA Success: {torch.cuda.get_device_name(0)}')"
                    & $venvPython -c $verifyCmd
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "PyTorch Verification Passed!" -ForegroundColor Green
                    }
                    else {
                        Write-Host "PyTorch installed but CUDA check FAILED." -ForegroundColor Red
                        Write-Host "This usually means 'no kernel image is available' (Architecture Mismatch)." -ForegroundColor Red
                        Write-Host "For RTX 5080, ensure you are using the latest drivers." -ForegroundColor Red
                    }
                }
                catch {
                    Write-Host "Verification script failed to run." -ForegroundColor Yellow
                }

            }
            else {
                Write-Host "Skipping PyTorch installation (Already up to date)." -ForegroundColor Green
            }

            Write-ScriptLog "Installing ComfyUI requirements..."
            Write-Host "Installing ComfyUI dependencies..." -ForegroundColor Cyan
            & $venvPip install -r requirements.txt | Out-Host

            # Fix for "kernel ... built for sm37" error on RTX 50-series
            # This error is caused by incompatible xformers/flash-attention binaries.
            # We uninstall them to force ComfyUI to use PyTorch's native SDPA (Scaled Dot Product Attention),
            # which is highly optimized for newer GPUs and stable.
            Write-ScriptLog "Removing potentially incompatible attention kernels (xformers/flash-attn) to fix sm37/sm80 mismatch..."
            & $venvPip uninstall -y xformers flash-attention flash-attn | Out-Host

        }
        catch {
            Write-ScriptLog "Error installing requirements: $_" "Error"
            throw
        }
        finally {
            Pop-Location
        }
    }

    Write-ScriptLog "ComfyUI installation completed successfully."
    Write-ScriptLog "Location: $InstallPath"
    Write-ScriptLog "To start (Windows): $InstallPath\venv\Scripts\python.exe main.py"
    Write-ScriptLog "To start (Linux): $InstallPath/venv/bin/python main.py"

}
catch {
    Write-ScriptLog "Installation failed: $_" "Error"
    exit 1
}
