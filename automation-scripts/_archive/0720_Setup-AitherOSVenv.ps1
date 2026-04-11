#Requires -Version 7.0

<#
.SYNOPSIS
    Creates and configures the centralized AitherOS Python virtual environment.

.DESCRIPTION
    This script creates a centralized virtual environment at AitherOS/.venv
    and installs all dependencies from the unified requirements.txt.

    This venv is used by:
    - All AitherNode services (Chronicle, Spirit, Canvas, etc.)
    - AitherGenesis bootloader
    - All agents (NarrativeAgent, GenesisAgent, etc.)
    - Windows services installed via NSSM

    The script:
    1. Detects or installs Python 3.12+
    2. Creates AitherOS/.venv if it doesn't exist
    3. Upgrades pip/setuptools/wheel
    4. Installs requirements from AitherOS/requirements.txt
    5. Verifies critical packages are installed

.PARAMETER Force
    Force recreate the venv even if it exists.

.PARAMETER SkipPackages
    Skip installing packages (just create venv).

.PARAMETER PythonPath
    Path to specific Python executable to use.

.EXAMPLE
    .\0720_Setup-AitherOSVenv.ps1
    # Creates venv and installs all packages

.EXAMPLE
    .\0720_Setup-AitherOSVenv.ps1 -Force
    # Recreates venv from scratch

.NOTES
    Stage: Environment
    Order: 0720
    Tags: python, venv, environment, dependencies
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$SkipPackages,

    [Parameter()]
    [string]$PythonPath
)

# Initialize
. "$PSScriptRoot/_init.ps1"

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      AitherOS Centralized Virtual Environment Setup       ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
# 1. DETECT PATHS
# ═══════════════════════════════════════════════════════════════════════════════

$ScriptRoot = $PSScriptRoot
$LibraryDir = Split-Path -Parent $ScriptRoot
$AitherZeroDir = Split-Path -Parent $LibraryDir
$RepoRoot = Split-Path -Parent $AitherZeroDir
$AitherOSDir = Join-Path $RepoRoot "AitherOS"

# Venv paths
$VenvDir = Join-Path $AitherOSDir ".venv"
$VenvPython = Join-Path $VenvDir "Scripts/python.exe"
$VenvPip = Join-Path $VenvDir "Scripts/pip.exe"
$RequirementsFile = Join-Path $AitherOSDir "requirements.txt"

Write-ScriptLog "AitherOS Root: $AitherOSDir"
Write-ScriptLog "Venv Target: $VenvDir"

# ═══════════════════════════════════════════════════════════════════════════════
# 2. FIND PYTHON
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "🐍 Finding Python installation..." -ForegroundColor Cyan

$pythonCmd = $null

if ($PythonPath -and (Test-Path $PythonPath)) {
    $pythonCmd = $PythonPath
    Write-ScriptLog "Using specified Python: $pythonCmd"
}
else {
    # Search order: py launcher > python in PATH > common locations
    $searchLocations = @(
        "py"  # Python launcher
        "python"
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe"
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
        "C:\Python313\python.exe"
        "C:\Python312\python.exe"
        "C:\Python311\python.exe"
    )

    foreach ($location in $searchLocations) {
        try {
            $testCmd = Get-Command $location -ErrorAction SilentlyContinue
            if ($testCmd) {
                # Verify it's Python 3.10+
                $version = & $location --version 2>&1
                if ($version -match "Python 3\.(\d+)") {
                    $minorVer = [int]$matches[1]
                    if ($minorVer -ge 10) {
                        $pythonCmd = $testCmd.Source
                        Write-ScriptLog "Found Python: $pythonCmd ($version)"
                        break
                    }
                }
            }
        }
        catch {
            continue
        }
    }
}

if (-not $pythonCmd) {
    Write-Error "❌ Python 3.10+ not found. Please install Python first."
    exit 1
}

# Get actual path if using py launcher
if ($pythonCmd -eq "py") {
    $pythonCmd = (& py -c "import sys; print(sys.executable)" 2>$null)
}

$pythonVersion = & $pythonCmd --version 2>&1
Write-Host "   ✅ Using: $pythonCmd" -ForegroundColor Green
Write-Host "   📌 Version: $pythonVersion" -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
# 3. CREATE VIRTUAL ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "📦 Setting up virtual environment..." -ForegroundColor Cyan

$needsCreate = $false

if (Test-Path $VenvDir) {
    if ($Force) {
        Write-ScriptLog "Removing existing venv (Force mode)..."
        Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
        $needsCreate = $true
    }
    elseif (-not (Test-Path $VenvPython)) {
        Write-ScriptLog "Venv directory exists but Python missing, recreating..."
        Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
        $needsCreate = $true
    }
    else {
        Write-Host "   ✅ Venv already exists at $VenvDir" -ForegroundColor Green
    }
}
else {
    $needsCreate = $true
}

if ($needsCreate) {
    Write-ScriptLog "Creating virtual environment..."
    & $pythonCmd -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) {
        Write-Error "❌ Failed to create virtual environment"
        exit 1
    }
    Write-Host "   ✅ Virtual environment created" -ForegroundColor Green
}

# Verify venv Python exists
if (-not (Test-Path $VenvPython)) {
    Write-Error "❌ Venv Python not found at: $VenvPython"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# 4. UPGRADE PIP & INSTALL PACKAGES
# ═══════════════════════════════════════════════════════════════════════════════

if (-not $SkipPackages) {
    Write-Host ""
    Write-Host "📥 Installing packages..." -ForegroundColor Cyan

    # Ensure pip resolves relative paths in requirements.txt relative to AitherOS/
    # This is required for editable installs like: -e ./aither_adk
    Push-Location $AitherOSDir
    try {
    # Upgrade pip/setuptools/wheel first
    Write-ScriptLog "Upgrading pip, setuptools, wheel..."
    & $VenvPython -m pip install --upgrade pip setuptools wheel --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "⚠️ pip upgrade had issues, continuing anyway..."
    }

    # Check for requirements file
    if (-not (Test-Path $RequirementsFile)) {
        Write-Error "❌ Requirements file not found: $RequirementsFile"
        exit 1
    }

    # Check for constraints file (prevents PyTorch CUDA downgrade)
    $ConstraintsFile = Join-Path $AitherOSDir "constraints.txt"
    $useConstraints = Test-Path $ConstraintsFile

    # Install requirements (with constraints if available)
    Write-ScriptLog "Installing from $RequirementsFile..."
    if ($useConstraints) {
        Write-Host "   📌 Using constraints.txt to protect PyTorch CUDA versions" -ForegroundColor DarkCyan
    }
    Write-Host "   (This may take several minutes...)" -ForegroundColor DarkGray
    
    if ($useConstraints) {
        & $VenvPython -m pip install -r $RequirementsFile -c $ConstraintsFile --quiet 2>&1 | ForEach-Object {
            if ($_ -match "ERROR|error|Error") {
                Write-Host "   ⚠️ $_" -ForegroundColor Yellow
            }
        }
    } else {
        & $VenvPython -m pip install -r $RequirementsFile --quiet 2>&1 | ForEach-Object {
            if ($_ -match "ERROR|error|Error") {
                Write-Host "   ⚠️ $_" -ForegroundColor Yellow
            }
        }
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "⚠️ Some packages may have failed to install. Continuing..."
    }
    else {
        Write-Host "   ✅ All packages installed" -ForegroundColor Green
    }
    } finally {
        Pop-Location
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 5. VERIFY CRITICAL PACKAGES
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "🔍 Verifying critical packages..." -ForegroundColor Cyan

$criticalPackages = @(
    "fastapi",
    "uvicorn",
    "mcp",
    "aiofiles",
    "aiohttp",
    "httpx",
    "websockets",
    "moshi",
    # Module names (not pip package names):
    "google.adk",
    "yaml",
    "psutil"
)

# Verify PyTorch CUDA specifically
Write-Host ""
Write-Host "🔥 Verifying PyTorch CUDA..." -ForegroundColor Cyan
$torchCheck = & $VenvPython -c "import torch; print(f'torch={torch.__version__} cuda={torch.cuda.is_available()}')" 2>$null
if ($torchCheck -match "cuda=True") {
    Write-Host "   ✅ $torchCheck" -ForegroundColor Green
} elseif ($torchCheck -match "cuda=False") {
    Write-Host "   ⚠️ $torchCheck - CUDA NOT AVAILABLE!" -ForegroundColor Yellow
    Write-Host "   Run: pip install torch==2.10.0+cu128 --index-url https://download.pytorch.org/whl/cu128" -ForegroundColor DarkYellow
} else {
    Write-Host "   ❌ PyTorch not installed!" -ForegroundColor Red
}

Write-Host ""

$allGood = $true
foreach ($pkg in $criticalPackages) {
    $check = & $VenvPython -c "import importlib.util; print('OK' if importlib.util.find_spec('$($pkg.Replace('-','_').Split('[')[0])') else 'MISSING')" 2>$null
    if ($check -eq "OK") {
        Write-Host "   ✅ $pkg" -ForegroundColor Green
    }
    else {
        Write-Host "   ❌ $pkg - MISSING" -ForegroundColor Red
        $allGood = $false
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 6. SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              Virtual Environment Ready!                   ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  📍 Location: $VenvDir" -ForegroundColor White
Write-Host "  🐍 Python:   $VenvPython" -ForegroundColor White
Write-Host "  📦 Pip:      $VenvPip" -ForegroundColor White
Write-Host ""
Write-Host "  To activate manually:" -ForegroundColor Cyan
Write-Host "     & `"$VenvDir\Scripts\Activate.ps1`"" -ForegroundColor White
Write-Host ""

# Export for other scripts
$env:AITHEROS_VENV = $VenvDir
$env:AITHEROS_PYTHON = $VenvPython

Write-AitherLog -Message "AitherOS venv setup complete: $VenvDir" -Level Information -Source '0720_Setup-AitherOSVenv'

if ($allGood) {
    exit 0
}
else {
    Write-Warning "⚠️ Some packages may be missing. Run with -Force to recreate venv."
    exit 0  # Don't fail the bootstrap, just warn
}
