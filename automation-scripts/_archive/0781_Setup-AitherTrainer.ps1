<#
.SYNOPSIS
    Sets up the AitherTrainer environment (backend + frontend).

.DESCRIPTION
    Comprehensive setup for the AitherTrainer model training system:
    - Sets up Python virtual environment with training dependencies
    - Installs Node.js dependencies for the React frontend (optional)
    - Creates required directory structure for training data
    - Validates all dependencies are available
    
    The trainer consists of:
    - Backend: AitherOS/AitherNode/AitherTrainer.py (FastAPI on port 8107)
    - Frontend: AitherOS/AitherTrainer (React Vite app - optional, integrated into AitherVeil)

.PARAMETER IncludeFrontend
    Also install the AitherTrainer React frontend dependencies.
    
.PARAMETER Force
    Recreate virtual environment even if it exists.

.PARAMETER ShowOutput
    Display verbose output during execution.

.EXAMPLE
    ./0781_Setup-AitherTrainer.ps1 -ShowOutput
    
.EXAMPLE
    ./0781_Setup-AitherTrainer.ps1 -IncludeFrontend -Force

.NOTES
    Script ID: 0781
    Author: AitherZero
    Category: AI Services / Training Setup
    
    Related Scripts:
    - 0779_Start-AitherTrainer.ps1 - Start the training service
    - 0780_Start-AitherPrism.ps1 - Start video frame extraction
    - 0752_Setup-AgentVenv.ps1 - Generic venv setup
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$IncludeFrontend,
    
    [Parameter()]
    [switch]$Force,
    
    [Parameter()]
    [switch]$ShowOutput
)

# Initialize with common logging and functions
. "$PSScriptRoot/_init.ps1"

$ErrorActionPreference = 'Stop'

# Paths
$AitherNodePath = Join-Path $projectRoot "AitherOS" "AitherNode"
$TrainerFrontendPath = Join-Path $projectRoot "AitherOS" "AitherTrainer"
$VenvPath = Join-Path $projectRoot "AitherOS" "agents" "NarrativeAgent" ".venv"
# Use centralized Library/Training path
$TrainingDataPath = Join-Path $projectRoot "AitherOS" "Library" "Training"

# Required Python packages for training
$TrainingPackages = @(
    "torch>=2.0.0"
    "transformers>=5.0.0"
    "datasets>=2.14.0"
    "peft>=0.6.0"            # LoRA/QLoRA
    "bitsandbytes>=0.41.0"   # 4-bit quantization
    "accelerate>=0.24.0"
    "trl>=0.7.0"             # DPO training
    "wandb"                  # Experiment tracking
    "tensorboard"
    "scikit-learn"
    "numpy"
    "pandas"
    "tqdm"
    "scipy"
)

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    if ($ShowOutput) {
        $color = switch ($Level) {
            "Success" { "Green" }
            "Warning" { "Yellow" }
            "Error"   { "Red" }
            default   { "Cyan" }
        }
        Write-Host "[$Level] $Message" -ForegroundColor $color
    }
    Write-ScriptLog -Level $Level -Message $Message
}

# =============================================================================
# Step 1: Validate Prerequisites
# =============================================================================

Write-Log "=== AitherTrainer Setup ===" -Level Information
Write-Log "Validating prerequisites..." -Level Information

# Check Python
$pythonCmd = if ($IsWindows) { "python" } else { "python3" }
try {
    $pythonVersion = & $pythonCmd --version 2>&1
    Write-Log "Python: $pythonVersion" -Level Information
} catch {
    Write-Log "Python not found. Install Python 3.10+ first." -Level Error
    Write-Log "Run: ./AitherZero/library/automation-scripts/0206_Install-Python.ps1" -Level Information
    exit 1
}

# Check pip
try {
    $pipVersion = & $pythonCmd -m pip --version 2>&1
    Write-Log "Pip: $($pipVersion -split ' ' | Select-Object -First 2)" -Level Information
} catch {
    Write-Log "Pip not available. Install pip first." -Level Error
    exit 1
}

# Check Node.js (optional for frontend)
if ($IncludeFrontend) {
    try {
        $nodeVersion = & node --version 2>&1
        Write-Log "Node.js: $nodeVersion" -Level Information
    } catch {
        Write-Log "Node.js not found. Frontend setup will be skipped." -Level Warning
        $IncludeFrontend = $false
    }
}

# =============================================================================
# Step 2: Create Directory Structure
# =============================================================================

Write-Log "Creating training data directory structure..." -Level Information

$directories = @(
    (Join-Path $TrainingDataPath "datasets")
    (Join-Path $TrainingDataPath "checkpoints")
    (Join-Path $TrainingDataPath "benchmarks")
    (Join-Path $TrainingDataPath "cost_logs")
    (Join-Path $TrainingDataPath "models")
    (Join-Path $TrainingDataPath "exports")
    (Join-Path $TrainingDataPath "aither-7b" "conversations")
    (Join-Path $TrainingDataPath "aither-7b" "reasoning_traces")
    (Join-Path $TrainingDataPath "chronicle" "interactions")
)

foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Created: $dir" -Level Information
    }
}

# =============================================================================
# Step 3: Setup Python Virtual Environment
# =============================================================================

Write-Log "Setting up Python virtual environment..." -Level Information

$pipExe = if ($IsWindows) {
    Join-Path $VenvPath "Scripts" "pip.exe"
} else {
    Join-Path $VenvPath "bin" "pip"
}

$pythonExe = if ($IsWindows) {
    Join-Path $VenvPath "Scripts" "python.exe"
} else {
    Join-Path $VenvPath "bin" "python"
}

# Create venv if needed
if (-not (Test-Path $VenvPath) -or $Force) {
    Write-Log "Creating virtual environment at: $VenvPath" -Level Information
    
    if ($Force -and (Test-Path $VenvPath)) {
        Remove-Item -Path $VenvPath -Recurse -Force
    }
    
    $venvParent = Split-Path $VenvPath -Parent
    Push-Location $venvParent
    try {
        & $pythonCmd -m venv .venv
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create virtual environment"
        }
        Write-Log "Virtual environment created successfully" -Level Success
    } finally {
        Pop-Location
    }
}

# Upgrade pip
Write-Log "Upgrading pip..." -Level Information
& $pythonExe -m pip install --upgrade pip --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Log "Warning: pip upgrade failed" -Level Warning
}

# =============================================================================
# Step 4: Install Training Dependencies
# =============================================================================

Write-Log "Installing training dependencies..." -Level Information

# Install base requirements if they exist
$baseRequirements = Join-Path (Split-Path $VenvPath -Parent) "requirements.txt"
if (Test-Path $baseRequirements) {
    Write-Log "Installing base requirements from: $baseRequirements" -Level Information
    & $pipExe install -r $baseRequirements --quiet
}

# Install training-specific packages
Write-Log "Installing training packages (this may take a while)..." -Level Information

foreach ($pkg in $TrainingPackages) {
    $pkgName = ($pkg -split '>=|==|<')[0]
    Write-Log "  Installing: $pkgName" -Level Information
    & $pipExe install $pkg --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  Warning: Failed to install $pkgName (may be optional)" -Level Warning
    }
}

# =============================================================================
# Step 5: Install Frontend Dependencies (Optional)
# =============================================================================

if ($IncludeFrontend -and (Test-Path $TrainerFrontendPath)) {
    Write-Log "Installing frontend dependencies..." -Level Information
    
    Push-Location $TrainerFrontendPath
    try {
        if (Test-Path "package.json") {
            & npm install --silent 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Frontend dependencies installed successfully" -Level Success
            } else {
                Write-Log "Frontend dependency installation failed" -Level Warning
            }
        }
    } finally {
        Pop-Location
    }
}

# =============================================================================
# Step 6: Validate Installation
# =============================================================================

Write-Log "Validating installation..." -Level Information

$validationResults = @{
    VenvExists = Test-Path $pythonExe
    PipWorks = $false
    TorchInstalled = $false
    TransformersInstalled = $false
    TrainerExists = Test-Path (Join-Path $AitherNodePath "AitherTrainer.py")
}

# Test pip
try {
    $pipList = & $pipExe list --format=freeze 2>&1
    $validationResults.PipWorks = $true
    
    # Check key packages
    $validationResults.TorchInstalled = $pipList -match "^torch=="
    $validationResults.TransformersInstalled = $pipList -match "^transformers=="
} catch {
    Write-Log "Pip validation failed: $_" -Level Warning
}

# Summary
Write-Log "" -Level Information
Write-Log "=== Setup Summary ===" -Level Information
Write-Log "Virtual Environment: $(if ($validationResults.VenvExists) { '✅' } else { '❌' })" -Level Information
Write-Log "Pip Working: $(if ($validationResults.PipWorks) { '✅' } else { '❌' })" -Level Information
Write-Log "PyTorch: $(if ($validationResults.TorchInstalled) { '✅' } else { '⚠️ (GPU training may not work)' })" -Level Information
Write-Log "Transformers: $(if ($validationResults.TransformersInstalled) { '✅' } else { '❌' })" -Level Information
Write-Log "AitherTrainer.py: $(if ($validationResults.TrainerExists) { '✅' } else { '❌' })" -Level Information

if ($IncludeFrontend) {
    $frontendReady = Test-Path (Join-Path $TrainerFrontendPath "node_modules")
    Write-Log "Frontend (node_modules): $(if ($frontendReady) { '✅' } else { '❌' })" -Level Information
}

Write-Log "" -Level Information

# Exit status
$allGood = $validationResults.VenvExists -and $validationResults.PipWorks -and $validationResults.TrainerExists

if ($allGood) {
    Write-Log "AitherTrainer setup complete!" -Level Success
    Write-Log "" -Level Information
    Write-Log "Next steps:" -Level Information
    Write-Log "  1. Start the trainer: ./0779_Start-AitherTrainer.ps1 -ShowOutput" -Level Information
    Write-Log "  2. Access via AitherVeil: http://localhost:3000 (Training widget)" -Level Information
    Write-Log "  3. API docs: http://localhost:8107/docs" -Level Information
    
    # Output JSON for automation
    @{
        Success = $true
        VenvPath = $VenvPath
        PythonPath = $pythonExe
        TrainingDataPath = $TrainingDataPath
        TrainerPort = 8107
    } | ConvertTo-Json -Compress
    
    exit 0
} else {
    Write-Log "Setup completed with warnings. Some features may not work." -Level Warning
    exit 1
}
