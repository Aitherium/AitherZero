#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Automated setup for OmniParser V2 — screen parsing for GUI agents.

.DESCRIPTION
    End-to-end provisioning of Microsoft OmniParser V2 for AitherOS:

    1. Python dependency installation (ultralytics, transformers, easyocr, torch)
    2. Model weight download from HuggingFace (icon_detect YOLO + icon_caption Florence)
    3. Weight verification (file existence, minimum size, structure)
    4. CUDA/GPU availability check
    5. AitherOmniParser service health check (port 8191)
    6. Optional: clone your OmniParser fork for reference/dev

    Models downloaded (~2.5GB total):
      icon_detect/          — YOLO-based UI element detection (~50MB)
      icon_caption_florence/ — Florence-2 icon captioning (~1.5GB)

    This script is idempotent — already-downloaded models are skipped.

.PARAMETER Force
    Re-download models even if they already exist.

.PARAMETER WeightsDir
    Override the model weights directory.
    Default: AitherOS/Library/Models/omniparser (or $env:OMNIPARSER_WEIGHTS_DIR).

.PARAMETER SkipModels
    Skip model downloads (only install Python deps + verify).

.PARAMETER SkipDeps
    Skip Python dependency installation.

.PARAMETER SkipHealthCheck
    Skip the service health check at the end.

.PARAMETER CloneFork
    Also clone the OmniParser fork repo for reference/development.

.PARAMETER ForkUrl
    URL of the OmniParser fork. Default: https://github.com/wizzense/OmniParser.

.PARAMETER HFToken
    HuggingFace API token for gated model downloads. Falls back to $env:HF_TOKEN.

.PARAMETER UseConda
    Create a separate conda environment for OmniParser (omniparser-env, Python 3.12).

.PARAMETER ShowOutput
    Display verbose output during execution.

.EXAMPLE
    .\5004_Setup-OmniParser.ps1
    Full setup: deps + models + health check.

.EXAMPLE
    .\5004_Setup-OmniParser.ps1 -SkipDeps -Force
    Re-download all models without reinstalling Python deps.

.EXAMPLE
    .\5004_Setup-OmniParser.ps1 -CloneFork -UseConda
    Full setup with fork clone and isolated conda env.

.NOTES
    Category: ai-setup
    Dependencies: Python 3.10+, pip, git (optional for clone)
    Platform: Windows, Linux, macOS
    Service: AitherOmniParser (port 8191, perception layer 2)
    License: icon_detect = AGPL (YOLO), icon_caption = MIT (Florence)
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$WeightsDir = "",
    [switch]$SkipModels,
    [switch]$SkipDeps,
    [switch]$SkipHealthCheck,
    [switch]$CloneFork,
    [string]$ForkUrl = "https://github.com/wizzense/OmniParser",
    [string]$HFToken = "",
    [switch]$UseConda,
    [switch]$ShowOutput
)

# Initialize
. "$PSScriptRoot/../_init.ps1"

$ErrorActionPreference = 'Continue'

# ============================================================================
# PLATFORM DETECTION
# ============================================================================

$platform = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows' }
             elseif ($IsLinux) { 'Linux' }
             elseif ($IsMacOS) { 'macOS' }
             else { 'Unknown' }

# ============================================================================
# RESOLVE PATHS
# ============================================================================

# Find workspace root (walk up to find docker-compose.aitheros.yml)
$scriptDir = $PSScriptRoot
$workspaceRoot = $scriptDir
for ($i = 0; $i -lt 6; $i++) {
    if (Test-Path (Join-Path $workspaceRoot "docker-compose.aitheros.yml")) { break }
    $workspaceRoot = Split-Path $workspaceRoot -Parent
}

$aitherOSRoot = Join-Path $workspaceRoot "AitherOS"

# Resolve weights directory
if (-not $WeightsDir) {
    $WeightsDir = $env:OMNIPARSER_WEIGHTS_DIR
}
if (-not $WeightsDir) {
    $WeightsDir = Join-Path $aitherOSRoot "Library/Models/omniparser"
}

# Resolve HF token
if (-not $HFToken) {
    $HFToken = $env:HF_TOKEN
}
if (-not $HFToken) {
    # Try .env file
    $envFile = Join-Path $workspaceRoot ".env"
    if (Test-Path $envFile) {
        $tokenLine = Get-Content $envFile | Where-Object { $_ -match '^HF_TOKEN=' }
        if ($tokenLine) {
            $HFToken = ($tokenLine -split '=', 2)[1].Trim()
        }
    }
}

# ============================================================================
# BANNER
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  OmniParser V2 Setup — Screen Parsing for GUI Agents" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Platform:    $platform" -ForegroundColor DarkGray
Write-Host "  Weights Dir: $WeightsDir" -ForegroundColor DarkGray
Write-Host "  HF Token:    $(if ($HFToken) { '✅ Available' } else { '⚠️ Not set (may need for gated models)' })" -ForegroundColor DarkGray
Write-Host "  Service:     AitherOmniParser (port 8191)" -ForegroundColor DarkGray
Write-Host ""

# Counters
$stepsDone = 0
$stepsSkipped = 0
$stepsFailed = 0

# ============================================================================
# STEP 1: PYTHON CHECK
# ============================================================================

Write-Host "━━━ Step 1: Python Environment ━━━" -ForegroundColor White

$pythonCmd = $null
$pipCmd = $null

# Find Python
foreach ($candidate in @("python3", "python", "py")) {
    try {
        $ver = & $candidate --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $ver -match 'Python 3\.\d+') {
            $pythonCmd = $candidate
            break
        }
    } catch {}
}

if (-not $pythonCmd) {
    Write-Host "  ❌ Python 3 not found. Install Python 3.10+ first." -ForegroundColor Red
    Write-Host "     Windows: winget install Python.Python.3.12" -ForegroundColor DarkGray
    Write-Host "     Linux:   sudo apt install python3 python3-pip" -ForegroundColor DarkGray
    Write-Host "     macOS:   brew install python@3.12" -ForegroundColor DarkGray
    $stepsFailed++
    exit 2
}

$pyVersion = & $pythonCmd --version 2>&1
Write-Host "  ✅ Found: $pyVersion ($pythonCmd)" -ForegroundColor Green

# Determine pip command
$pipCmd = if ($pythonCmd -eq "python3") { "pip3" } else { "pip" }
# Verify pip
try {
    $null = & $pythonCmd -m pip --version 2>&1
    $pipCmd = "$pythonCmd -m pip"
} catch {
    Write-Host "  ⚠️ pip not available via module, trying $pipCmd directly" -ForegroundColor Yellow
}

$stepsDone++

# ============================================================================
# STEP 2: CONDA ENVIRONMENT (Optional)
# ============================================================================

if ($UseConda) {
    Write-Host ""
    Write-Host "━━━ Step 2: Conda Environment ━━━" -ForegroundColor White

    $condaCmd = $null
    foreach ($c in @("conda", "mamba", "micromamba")) {
        try {
            $null = & $c --version 2>&1
            if ($LASTEXITCODE -eq 0) { $condaCmd = $c; break }
        } catch {}
    }

    if ($condaCmd) {
        # Check if env exists
        $envExists = & $condaCmd env list 2>&1 | Select-String "omniparser-env"
        if ($envExists -and -not $Force) {
            Write-Host "  ✅ Conda env 'omniparser-env' already exists" -ForegroundColor Green
            $stepsSkipped++
        } else {
            Write-Host "  ⬇️  Creating conda env 'omniparser-env' (Python 3.12)..." -ForegroundColor Cyan
            & $condaCmd create -n omniparser-env python=3.12 -y 2>&1 | ForEach-Object {
                if ($ShowOutput) { Write-Host "    $_" -ForegroundColor DarkGray }
            }
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ Conda env created. Activate with: conda activate omniparser-env" -ForegroundColor Green
                $stepsDone++
            } else {
                Write-Host "  ❌ Conda env creation failed" -ForegroundColor Red
                $stepsFailed++
            }
        }

        Write-Host "  ⚠️ NOTE: Activate the conda env before running the service:" -ForegroundColor Yellow
        Write-Host "     conda activate omniparser-env" -ForegroundColor DarkGray
    } else {
        Write-Host "  ⚠️ Conda not found, skipping env creation" -ForegroundColor Yellow
        Write-Host "     Install: https://docs.conda.io/en/latest/miniconda.html" -ForegroundColor DarkGray
        $stepsSkipped++
    }
}

# ============================================================================
# STEP 3: PYTHON DEPENDENCIES
# ============================================================================

if (-not $SkipDeps) {
    Write-Host ""
    Write-Host "━━━ Step 3: Python Dependencies ━━━" -ForegroundColor White

    # Core dependencies for OmniParser
    $requiredPackages = @(
        @{ Name = "ultralytics";  Desc = "YOLO icon detection engine" }
        @{ Name = "transformers"; Desc = "Florence caption model (HuggingFace)" }
        @{ Name = "Pillow";       Desc = "Image processing" }
        @{ Name = "easyocr";      Desc = "OCR text extraction" }
    )

    # Check and install torch separately (needs special index for CUDA)
    Write-Host "  Checking PyTorch..." -ForegroundColor DarkGray
    $torchInstalled = $false
    try {
        $torchCheck = & $pythonCmd -c "import torch; print(f'torch={torch.__version__} cuda={torch.cuda.is_available()}')" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ PyTorch: $torchCheck" -ForegroundColor Green
            $torchInstalled = $true
            $stepsSkipped++
        }
    } catch {}

    if (-not $torchInstalled) {
        Write-Host "  ⬇️  Installing PyTorch (with CUDA support)..." -ForegroundColor Cyan
        if ($platform -eq 'macOS') {
            # macOS: no CUDA, use default
            Invoke-Expression "$pipCmd install torch torchvision" 2>&1 | ForEach-Object {
                if ($ShowOutput -or $_ -match "error|Error") { Write-Host "    $_" -ForegroundColor DarkGray }
            }
        } else {
            # Windows/Linux: try CUDA 12.1 index
            Invoke-Expression "$pipCmd install torch torchvision --index-url https://download.pytorch.org/whl/cu121" 2>&1 | ForEach-Object {
                if ($ShowOutput -or $_ -match "error|Error") { Write-Host "    $_" -ForegroundColor DarkGray }
            }
        }

        # Verify
        try {
            $torchCheck = & $pythonCmd -c "import torch; print(f'torch={torch.__version__} cuda={torch.cuda.is_available()}')" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ PyTorch installed: $torchCheck" -ForegroundColor Green
                $stepsDone++
            } else {
                Write-Host "  ❌ PyTorch install verification failed" -ForegroundColor Red
                $stepsFailed++
            }
        } catch {
            Write-Host "  ❌ PyTorch installation failed: $_" -ForegroundColor Red
            $stepsFailed++
        }
    }

    # Install remaining packages
    foreach ($pkg in $requiredPackages) {
        $installed = $false
        try {
            $null = & $pythonCmd -c "import $($pkg.Name.ToLower() -replace '-','_')" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
            }
        } catch {}

        # Special case: Pillow is imported as PIL
        if ($pkg.Name -eq "Pillow") {
            try {
                $null = & $pythonCmd -c "from PIL import Image" 2>&1
                if ($LASTEXITCODE -eq 0) { $installed = $true }
            } catch {}
        }

        if ($installed -and -not $Force) {
            Write-Host "  ✅ $($pkg.Name) — $($pkg.Desc)" -ForegroundColor Green
            $stepsSkipped++
        } else {
            Write-Host "  ⬇️  Installing $($pkg.Name) — $($pkg.Desc)..." -ForegroundColor Cyan
            Invoke-Expression "$pipCmd install $($pkg.Name)" 2>&1 | ForEach-Object {
                if ($ShowOutput -or $_ -match "error|Error") { Write-Host "    $_" -ForegroundColor DarkGray }
            }
            if ($LASTEXITCODE -eq 0) {
                Write-Host "     Installed ✅" -ForegroundColor Green
                $stepsDone++
            } else {
                Write-Host "     Failed ❌" -ForegroundColor Red
                $stepsFailed++
            }
        }
    }

    # HuggingFace CLI (needed for model downloads)
    $hfCliInstalled = $false
    try {
        $null = & huggingface-cli version 2>&1
        if ($LASTEXITCODE -eq 0) { $hfCliInstalled = $true }
    } catch {}

    # Also check via python module
    if (-not $hfCliInstalled) {
        try {
            $null = & $pythonCmd -m huggingface_hub version 2>&1
            if ($LASTEXITCODE -eq 0) { $hfCliInstalled = $true }
        } catch {}
    }

    if (-not $hfCliInstalled) {
        Write-Host "  ⬇️  Installing huggingface-hub (HF CLI)..." -ForegroundColor Cyan
        Invoke-Expression "$pipCmd install huggingface_hub[cli]" 2>&1 | ForEach-Object {
            if ($ShowOutput) { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        $stepsDone++
    } else {
        Write-Host "  ✅ huggingface-cli — Model download tool" -ForegroundColor Green
        $stepsSkipped++
    }
} else {
    Write-Host ""
    Write-Host "━━━ Step 3: Python Dependencies (SKIPPED) ━━━" -ForegroundColor DarkGray
}

# ============================================================================
# STEP 4: GPU / CUDA CHECK
# ============================================================================

Write-Host ""
Write-Host "━━━ Step 4: GPU / CUDA Check ━━━" -ForegroundColor White

$cudaAvailable = $false
try {
    $cudaCheck = & $pythonCmd -c "import torch; print(torch.cuda.is_available())" 2>&1
    if ($cudaCheck -match "True") {
        $cudaAvailable = $true
        $gpuName = & $pythonCmd -c "import torch; print(torch.cuda.get_device_name(0))" 2>&1
        $vram = & $pythonCmd -c "import torch; print(f'{torch.cuda.get_device_properties(0).total_mem / 1024**3:.1f}GB')" 2>&1
        Write-Host "  ✅ CUDA available: $gpuName ($vram VRAM)" -ForegroundColor Green
        $stepsDone++
    }
} catch {}

if (-not $cudaAvailable) {
    # Try nvidia-smi directly
    try {
        $smiOut = nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ GPU detected: $smiOut" -ForegroundColor Green
            Write-Host "  ⚠️ CUDA not available in Python (torch may need reinstall with CUDA)" -ForegroundColor Yellow
        } else {
            Write-Host "  ⚠️ No NVIDIA GPU detected — OmniParser will use CPU (slower)" -ForegroundColor Yellow
            Write-Host "     GPU recommended for real-time UI parsing" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  ⚠️ No NVIDIA GPU detected — OmniParser will use CPU (slower)" -ForegroundColor Yellow
    }
    $stepsSkipped++
}

# ============================================================================
# STEP 5: MODEL WEIGHT DOWNLOAD
# ============================================================================

if (-not $SkipModels) {
    Write-Host ""
    Write-Host "━━━ Step 5: Model Weights ━━━" -ForegroundColor White
    Write-Host "  Target: $WeightsDir" -ForegroundColor DarkGray

    # Ensure directory exists
    if (-not (Test-Path $WeightsDir)) {
        New-Item -ItemType Directory -Path $WeightsDir -Force | Out-Null
        Write-Host "  📁 Created: $WeightsDir" -ForegroundColor DarkGray
    }

    # Model manifest
    $RequiredModels = @(
        @{
            Name     = "icon_detect"
            Files    = @("model.pt", "model.yaml", "train_args.yaml")
            MinSize  = 10MB   # model.pt should be ~50MB
            Desc     = "YOLO icon detection model (~50MB)"
            License  = "AGPL"
        },
        @{
            Name     = "icon_caption_florence"
            Files    = @("config.json", "generation_config.json")
            MinSize  = 100MB  # model.safetensors should be ~1.5GB
            Desc     = "Florence-2 icon captioning model (~1.5GB)"
            License  = "MIT"
        }
    )

    # Check if models already exist
    $allPresent = $true
    foreach ($model in $RequiredModels) {
        $modelDir = Join-Path $WeightsDir $model.Name
        $hasFiles = $false
        if (Test-Path $modelDir) {
            $dirSize = (Get-ChildItem $modelDir -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($dirSize -gt $model.MinSize) {
                $sizeMB = [math]::Round($dirSize / 1MB, 1)
                Write-Host "  ✅ $($model.Name) — ${sizeMB}MB ($($model.Desc))" -ForegroundColor Green
                $hasFiles = $true
                $stepsSkipped++
            }
        }
        if (-not $hasFiles) {
            $allPresent = $false
        }
    }

    if ($allPresent -and -not $Force) {
        Write-Host "  All models present. Use -Force to re-download." -ForegroundColor DarkGray
    } else {
        # Download via huggingface-cli
        Write-Host ""
        Write-Host "  ⬇️  Downloading OmniParser V2 weights from HuggingFace..." -ForegroundColor Cyan
        Write-Host "     Repo: microsoft/OmniParser-v2.0" -ForegroundColor DarkGray
        Write-Host "     This may take a few minutes (~2.5GB total)..." -ForegroundColor DarkGray

        # Build HF CLI command
        $hfArgs = @(
            "download"
            "microsoft/OmniParser-v2.0"
            "--local-dir"
            $WeightsDir
        )

        # Add token if available
        if ($HFToken) {
            $hfArgs += @("--token", $HFToken)
        }

        # Try huggingface-cli first
        $downloadSuccess = $false

        try {
            Write-Host "  Running: huggingface-cli $($hfArgs -join ' ')" -ForegroundColor DarkGray

            $hfProcess = Start-Process -FilePath "huggingface-cli" -ArgumentList $hfArgs `
                -NoNewWindow -PassThru -Wait -RedirectStandardOutput "$env:TEMP/hf_omni_stdout.log" `
                -RedirectStandardError "$env:TEMP/hf_omni_stderr.log" -ErrorAction Stop

            if ($hfProcess.ExitCode -eq 0) {
                $downloadSuccess = $true
                Write-Host "  ✅ HuggingFace download complete" -ForegroundColor Green
                $stepsDone++
            } else {
                $stderr = Get-Content "$env:TEMP/hf_omni_stderr.log" -ErrorAction SilentlyContinue
                Write-Host "  ⚠️ huggingface-cli exited with code $($hfProcess.ExitCode)" -ForegroundColor Yellow
                if ($stderr) {
                    $stderr | Select-Object -Last 5 | ForEach-Object {
                        Write-Host "     $_" -ForegroundColor DarkGray
                    }
                }
            }
        } catch {
            Write-Host "  ⚠️ huggingface-cli not found, trying Python module..." -ForegroundColor Yellow
        }

        # Fallback: python -m huggingface_hub
        if (-not $downloadSuccess) {
            try {
                $pyHfArgs = "-m huggingface_hub download microsoft/OmniParser-v2.0 --local-dir `"$WeightsDir`""
                if ($HFToken) {
                    $pyHfArgs += " --token $HFToken"
                }

                Write-Host "  Running: $pythonCmd $pyHfArgs" -ForegroundColor DarkGray
                Invoke-Expression "$pythonCmd $pyHfArgs" 2>&1 | ForEach-Object {
                    if ($ShowOutput -or $_ -match "error|Error|Downloading") {
                        Write-Host "    $_" -ForegroundColor DarkGray
                    }
                }
                if ($LASTEXITCODE -eq 0) {
                    $downloadSuccess = $true
                    Write-Host "  ✅ Download complete (via Python module)" -ForegroundColor Green
                    $stepsDone++
                }
            } catch {
                Write-Host "  ❌ Python huggingface_hub module also failed" -ForegroundColor Red
            }
        }

        # Fallback: git clone
        if (-not $downloadSuccess) {
            Write-Host "  ⚠️ HF CLI failed. Trying git clone fallback..." -ForegroundColor Yellow
            try {
                $null = git lfs install 2>&1
                git clone "https://huggingface.co/microsoft/OmniParser-v2.0" $WeightsDir 2>&1 | ForEach-Object {
                    if ($ShowOutput -or $_ -match "error|Error|Downloading") {
                        Write-Host "    $_" -ForegroundColor DarkGray
                    }
                }
                if ($LASTEXITCODE -eq 0) {
                    $downloadSuccess = $true
                    Write-Host "  ✅ Download complete (via git clone)" -ForegroundColor Green
                    $stepsDone++
                }
            } catch {
                Write-Host "  ❌ git clone also failed: $_" -ForegroundColor Red
            }
        }

        if (-not $downloadSuccess) {
            Write-Host "  ❌ All download methods failed. Manual download required:" -ForegroundColor Red
            Write-Host "     huggingface-cli download microsoft/OmniParser-v2.0 --local-dir `"$WeightsDir`"" -ForegroundColor Yellow
            $stepsFailed++
        }
    }

    # ============================================================================
    # STEP 5b: VERIFY MODEL WEIGHTS
    # ============================================================================

    Write-Host ""
    Write-Host "━━━ Step 5b: Model Verification ━━━" -ForegroundColor White

    $modelsVerified = 0
    $modelsFailedVerify = 0

    foreach ($model in $RequiredModels) {
        $modelDir = Join-Path $WeightsDir $model.Name
        $issues = @()

        if (-not (Test-Path $modelDir)) {
            $issues += "Directory missing"
        } else {
            foreach ($f in $model.Files) {
                $fPath = Join-Path $modelDir $f
                if (-not (Test-Path $fPath)) {
                    $issues += "Missing file: $f"
                } elseif ((Get-Item $fPath).Length -lt 100) {
                    $issues += "Suspiciously small: $f ($(Get-Item $fPath).Length bytes)"
                }
            }

            # Check total size
            $dirSize = (Get-ChildItem $modelDir -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($dirSize -lt $model.MinSize) {
                $issues += "Total size too small: $([math]::Round($dirSize / 1MB, 1))MB (expected > $([math]::Round($model.MinSize / 1MB, 1))MB)"
            }
        }

        if ($issues.Count -eq 0) {
            $dirSize = (Get-ChildItem $modelDir -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $sizeMB = [math]::Round($dirSize / 1MB, 1)
            Write-Host "  ✅ $($model.Name) — verified (${sizeMB}MB, license: $($model.License))" -ForegroundColor Green
            $modelsVerified++
        } else {
            Write-Host "  ❌ $($model.Name) — verification failed:" -ForegroundColor Red
            foreach ($issue in $issues) {
                Write-Host "     • $issue" -ForegroundColor Yellow
            }
            $modelsFailedVerify++
        }
    }

    if ($modelsFailedVerify -gt 0) {
        $stepsFailed += $modelsFailedVerify
    } else {
        $stepsDone++
    }
} else {
    Write-Host ""
    Write-Host "━━━ Step 5: Model Weights (SKIPPED) ━━━" -ForegroundColor DarkGray
}

# ============================================================================
# STEP 6: CLONE FORK (Optional)
# ============================================================================

if ($CloneFork) {
    Write-Host ""
    Write-Host "━━━ Step 6: Clone OmniParser Fork ━━━" -ForegroundColor White

    $cloneTarget = Join-Path $workspaceRoot "OmniParser"

    if ((Test-Path $cloneTarget) -and -not $Force) {
        Write-Host "  ✅ Fork already cloned: $cloneTarget" -ForegroundColor Green
        $stepsSkipped++
    } else {
        Write-Host "  ⬇️  Cloning $ForkUrl..." -ForegroundColor Cyan
        try {
            git clone $ForkUrl $cloneTarget 2>&1 | ForEach-Object {
                if ($ShowOutput) { Write-Host "    $_" -ForegroundColor DarkGray }
            }
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ Cloned to: $cloneTarget" -ForegroundColor Green
                Write-Host "     Demo:   cd OmniParser && python gradio_demo.py" -ForegroundColor DarkGray
                Write-Host "     Weights: Symlink or copy $WeightsDir -> OmniParser/weights/" -ForegroundColor DarkGray
                $stepsDone++
            } else {
                Write-Host "  ❌ Clone failed" -ForegroundColor Red
                $stepsFailed++
            }
        } catch {
            Write-Host "  ❌ Clone failed: $_" -ForegroundColor Red
            $stepsFailed++
        }
    }
}

# ============================================================================
# STEP 7: SET ENVIRONMENT VARIABLE
# ============================================================================

Write-Host ""
Write-Host "━━━ Step 7: Environment Configuration ━━━" -ForegroundColor White

# Set env var for current session
$env:OMNIPARSER_WEIGHTS_DIR = $WeightsDir
Write-Host "  ✅ Set OMNIPARSER_WEIGHTS_DIR=$WeightsDir (current session)" -ForegroundColor Green

# Suggest persistent env var
if ($platform -eq 'Windows') {
    Write-Host "  To persist across sessions:" -ForegroundColor DarkGray
    Write-Host "     [Environment]::SetEnvironmentVariable('OMNIPARSER_WEIGHTS_DIR', '$WeightsDir', 'User')" -ForegroundColor DarkGray
} else {
    Write-Host "  To persist across sessions:" -ForegroundColor DarkGray
    Write-Host "     echo 'export OMNIPARSER_WEIGHTS_DIR=$WeightsDir' >> ~/.bashrc" -ForegroundColor DarkGray
}
$stepsDone++

# ============================================================================
# STEP 8: SERVICE HEALTH CHECK
# ============================================================================

if (-not $SkipHealthCheck) {
    Write-Host ""
    Write-Host "━━━ Step 8: Service Health Check ━━━" -ForegroundColor White

    $servicePort = 8191
    $serviceHealthy = $false
    $maxWait = 10  # Quick check, not startup wait

    try {
        $response = Invoke-RestMethod -Uri "http://localhost:${servicePort}/health" -TimeoutSec 5 -ErrorAction SilentlyContinue
        if ($response) {
            $serviceHealthy = $true
            Write-Host "  ✅ AitherOmniParser running on port $servicePort" -ForegroundColor Green

            if ($response.models_loaded -eq $true) {
                Write-Host "     Models loaded: YES" -ForegroundColor Green
            } elseif ($response.models_available -eq $true) {
                Write-Host "     Models available but not loaded (load on first parse)" -ForegroundColor DarkGray
            }
            $stepsDone++
        }
    } catch {}

    if (-not $serviceHealthy) {
        Write-Host "  ⚠️ AitherOmniParser not running on port $servicePort" -ForegroundColor Yellow
        Write-Host "     Start with: cd AitherOS && python services/perception/AitherOmniParser.py" -ForegroundColor DarkGray
        Write-Host "     Or via Docker: docker compose -f docker-compose.aitheros.yml up -d aither-omniparser" -ForegroundColor DarkGray
        $stepsSkipped++
    }
} else {
    Write-Host ""
    Write-Host "━━━ Step 8: Service Health Check (SKIPPED) ━━━" -ForegroundColor DarkGray
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  OmniParser V2 Setup — Results" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✅ Completed: $stepsDone" -ForegroundColor Green
Write-Host "  ⏭️  Skipped:   $stepsSkipped (already done)" -ForegroundColor DarkGray
if ($stepsFailed -gt 0) {
    Write-Host "  ❌ Failed:    $stepsFailed" -ForegroundColor Red
}
Write-Host ""
Write-Host "  Weights:  $WeightsDir" -ForegroundColor White
Write-Host "  Service:  AitherOmniParser (port 8191)" -ForegroundColor White
Write-Host "  Client:   from lib.clients.omniparser import get_omniparser_client" -ForegroundColor White
Write-Host ""

# Usage examples
Write-Host "  Usage Examples:" -ForegroundColor White
Write-Host "    # Parse a screenshot" -ForegroundColor DarkGray
Write-Host '    curl -X POST http://localhost:8191/parse -H "Content-Type: application/json" \' -ForegroundColor DarkGray
Write-Host '      -d "{\"image_path\": \"C:/screenshot.png\"}"' -ForegroundColor DarkGray
Write-Host "" -ForegroundColor DarkGray
Write-Host "    # Find a button" -ForegroundColor DarkGray
Write-Host '    curl -X POST "http://localhost:8191/find_element?image_path=C:/shot.png&description=Submit"' -ForegroundColor DarkGray
Write-Host "" -ForegroundColor DarkGray
Write-Host "    # Python client" -ForegroundColor DarkGray
Write-Host "    client = get_omniparser_client()" -ForegroundColor DarkGray
Write-Host "    result = await client.parse('/path/to/screenshot.png')" -ForegroundColor DarkGray
Write-Host "    for el in result.interactable:" -ForegroundColor DarkGray
Write-Host "        print(f'{el[\"label\"]}: click at {el[\"center_px\"]}')" -ForegroundColor DarkGray
Write-Host ""

if ($stepsFailed -gt 0) {
    exit 1
}
exit 0
