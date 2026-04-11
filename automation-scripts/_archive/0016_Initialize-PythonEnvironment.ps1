#Requires -Version 7.0
<#
.SYNOPSIS
    Initialize the AitherOS Python virtual environment.

.DESCRIPTION
    Creates and configures the shared Python virtual environment at AitherOS/.venv.
    This is THE SINGLE venv for all AitherOS services (not per-agent venvs).
    
    Historical Note: The codebase previously used AitherOS/agents/NarrativeAgent/.venv 
    as a shared venv which was confusing and wrong. This script migrates to the proper
    location at AitherOS/.venv.

.PARAMETER Force
    Force recreation of venv even if it exists.

.PARAMETER SkipMigration
    Skip migrating from legacy NarrativeAgent/.venv location.

.PARAMETER PythonVersion
    Minimum Python version required (default: 3.11).

.EXAMPLE
    .\0016_Initialize-PythonEnvironment.ps1
    # Creates AitherOS/.venv if not exists, installs all dependencies

.EXAMPLE
    .\0016_Initialize-PythonEnvironment.ps1 -Force
    # Recreates venv from scratch

.NOTES
    Author: Aitherium
    Category: 0000-0099 Environment Setup
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$SkipMigration,
    [string]$PythonVersion = "3.11"
)

# Load common utilities
. $PSScriptRoot/_init.ps1

# ============================================================================
# CONFIGURATION
# ============================================================================

$AITHEROS_ROOT = Join-Path $projectRoot "AitherOS"
$VENV_PATH = Join-Path $AITHEROS_ROOT ".venv"
$LEGACY_VENV = Join-Path $AITHEROS_ROOT "agents/NarrativeAgent/.venv"
$REQUIREMENTS_FILE = Join-Path $AITHEROS_ROOT "requirements.txt"
$AITHERNODE_DIR = Join-Path $AITHEROS_ROOT "AitherNode"

# Core dependencies that MUST be installed for AitherOS to function
$CORE_DEPENDENCIES = @(
    "fastapi>=0.115.0",
    "uvicorn[standard]>=0.32.0",
    "httpx>=0.27.0",
    "pydantic>=2.9.0",
    "pydantic-settings>=2.6.0",
    "python-multipart>=0.0.12",
    "aiofiles>=24.1.0",
    "websockets>=14.0",
    "requests>=2.32.0",
    "pyyaml>=6.0.2",
    "python-dotenv>=1.0.1",
    "cryptography>=44.0.0",
    "paramiko>=3.5.0"
)

# Optional dependencies for specific features
$OPTIONAL_DEPENDENCIES = @{
    "gpu-provisioning" = @("vastai>=0.5.0")
    "google-adk" = @("google-adk>=1.0.0", "google-genai>=1.0.0")
    "ollama" = @("ollama>=0.4.0")
    "vision" = @("pillow>=10.0.0", "transformers>=4.40.0")
    "vector-db" = @("chromadb>=0.5.0", "qdrant-client>=1.12.0")
}

# ============================================================================
# FUNCTIONS
# ============================================================================

function Find-Python {
    <#
    .SYNOPSIS
        Find a suitable Python installation.
    #>
    param([string]$MinVersion = "3.11")
    
    $pythonCandidates = @(
        "python3",
        "python",
        "py -3",
        "C:\Python313\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
    )
    
    foreach ($candidate in $pythonCandidates) {
        try {
            $version = & $candidate --version 2>&1
            if ($version -match "Python (\d+\.\d+)") {
                $foundVersion = [version]$Matches[1]
                $requiredVersion = [version]$MinVersion
                if ($foundVersion -ge $requiredVersion) {
                    Write-AitherLog "Found Python $foundVersion at: $candidate" -Level Information
                    return $candidate
                }
            }
        }
        catch {
            Write-Host "Failed to check $candidate : $_"
            continue
        }
    }
    
    throw "No suitable Python >= $MinVersion found. Please install Python."
}

function New-VirtualEnvironment {
    <#
    .SYNOPSIS
        Create a new Python virtual environment.
    #>
    param(
        [string]$PythonPath,
        [string]$VenvPath
    )
    
    Write-AitherLog "Creating virtual environment at: $VenvPath" -Level Information
    
    # Remove existing if Force
    if ($Force -and (Test-Path $VenvPath)) {
        Write-AitherLog "Removing existing venv (Force mode)..." -Level Warning
        Remove-Item -Path $VenvPath -Recurse -Force
    }
    
    # Create venv
    & $PythonPath -m venv $VenvPath
    
    if (-not (Test-Path "$VenvPath/Scripts/python.exe")) {
        throw "Failed to create virtual environment"
    }
    
    Write-AitherLog "✅ Virtual environment created successfully" -Level Information
}

function Get-VenvPython {
    <#
    .SYNOPSIS
        Get the path to the venv Python executable.
    #>
    param([string]$VenvPath)
    
    if ($IsWindows -or $env:OS -match "Windows") {
        return Join-Path $VenvPath "Scripts/python.exe"
    }
    else {
        return Join-Path $VenvPath "bin/python"
    }
}

function Install-CoreDependencies {
    <#
    .SYNOPSIS
        Install core AitherOS dependencies.
    #>
    param([string]$PythonPath)
    
    Write-AitherLog "Installing core dependencies..." -Level Information
    
    # Upgrade pip first
    & $PythonPath -m pip install --upgrade pip setuptools wheel --quiet
    
    # Install from requirements.txt if exists
    if (Test-Path $REQUIREMENTS_FILE) {
        Write-AitherLog "Installing from requirements.txt..." -Level Information
        Push-Location $AITHEROS_ROOT
        try {
            & $PythonPath -m pip install -r $REQUIREMENTS_FILE --quiet
        }
        finally {
            Pop-Location
        }
    }
    
    # Ensure core deps are installed
    foreach ($dep in $CORE_DEPENDENCIES) {
        Write-Host "  📦 $dep" -ForegroundColor DarkGray
        & $PythonPath -m pip install $dep --quiet 2>&1 | Out-Null
    }
    
    # Install AitherNode as editable package
    if ((Test-Path (Join-Path $AITHERNODE_DIR "setup.py")) -or (Test-Path (Join-Path $AITHERNODE_DIR "pyproject.toml"))) {
        Write-AitherLog "Installing AitherNode as editable package..." -Level Information
        & $PythonPath -m pip install -e $AITHERNODE_DIR --quiet 2>&1 | Out-Null
    }
    
    Write-AitherLog "✅ Core dependencies installed" -Level Information
}

function Install-OptionalDependencies {
    <#
    .SYNOPSIS
        Install optional feature dependencies.
    #>
    param(
        [string]$PythonPath,
        [string[]]$Features = @()
    )
    
    if ($Features.Count -eq 0) {
        # Install all optional by default
        $Features = $OPTIONAL_DEPENDENCIES.Keys
    }
    
    foreach ($feature in $Features) {
        if ($OPTIONAL_DEPENDENCIES.ContainsKey($feature)) {
            Write-Host "  🔧 Installing $feature dependencies..." -ForegroundColor Cyan
            foreach ($dep in $OPTIONAL_DEPENDENCIES[$feature]) {
                & $PythonPath -m pip install $dep --quiet 2>&1 | Out-Null
            }
        }
    }
}

function Migrate-LegacyVenv {
    <#
    .SYNOPSIS
        Migrate from legacy NarrativeAgent/.venv to AitherOS/.venv.
    #>
    
    if (-not (Test-Path $LEGACY_VENV)) {
        Write-AitherLog "No legacy venv found, skipping migration" -Level Debug
        return
    }
    
    if (Test-Path $VENV_PATH) {
        Write-AitherLog "Target venv already exists, skipping migration" -Level Debug
        return
    }
    
    Write-AitherLog "Migrating from legacy NarrativeAgent/.venv..." -Level Warning
    
    # Export installed packages from legacy
    $legacyPython = Get-VenvPython -VenvPath $LEGACY_VENV
    if (Test-Path $legacyPython) {
        $packages = & $legacyPython -m pip freeze 2>&1
        $migrationFile = Join-Path $AITHEROS_ROOT "migration-requirements.txt"
        $packages | Out-File $migrationFile -Encoding UTF8
        
        Write-AitherLog "Exported $(($packages | Measure-Object).Count) packages from legacy venv" -Level Information
    }
}

function Update-References {
    <#
    .SYNOPSIS
        Output instructions for updating legacy path references.
    #>
    
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║                   PATH MIGRATION REQUIRED                         ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "The following files reference the legacy NarrativeAgent/.venv path:" -ForegroundColor Cyan
    Write-Host ""
    
    $filesToUpdate = @(
        ".vscode/tasks.json",
        "start_aither.ps1",
        "bootstrap.ps1 -Mode New -Playbook genesis-bootstrap",
        "AitherZero/library/automation-scripts/0825_Deploy-GpuNode.ps1",
        "AitherOS/Library/Data/service_registry.json"
    )
    
    foreach ($file in $filesToUpdate) {
        $fullPath = Join-Path $REPO_ROOT $file
        if (Test-Path $fullPath) {
            Write-Host "  📝 $file" -ForegroundColor DarkGray
        }
    }
    
    Write-Host ""
    Write-Host "Run the following to update all references:" -ForegroundColor Green
    Write-Host "  .\AitherZero\library\automation-scripts\0018_Update-PythonPaths.ps1" -ForegroundColor White
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║           🐍 AITHEROS PYTHON ENVIRONMENT SETUP                   ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

try {
    # Step 1: Find Python
    $systemPython = Find-Python -MinVersion $PythonVersion
    
    # Step 2: Handle legacy migration
    if (-not $SkipMigration) {
        Migrate-LegacyVenv
    }
    
    # Step 3: Create venv if needed
    if (-not (Test-Path $VENV_PATH) -or $Force) {
        if ($PSCmdlet.ShouldProcess($VENV_PATH, "Create virtual environment")) {
            New-VirtualEnvironment -PythonPath $systemPython -VenvPath $VENV_PATH
        }
    }
    else {
        Write-AitherLog "Virtual environment already exists at: $VENV_PATH" -Level Information
    }
    
    # Step 4: Install dependencies
    $venvPython = Get-VenvPython -VenvPath $VENV_PATH
    
    if ($PSCmdlet.ShouldProcess("Core dependencies", "Install")) {
        Install-CoreDependencies -PythonPath $venvPython
    }
    
    if ($PSCmdlet.ShouldProcess("Optional dependencies", "Install")) {
        Install-OptionalDependencies -PythonPath $venvPython
    }
    
    # Step 5: Show migration instructions
    if (Test-Path $LEGACY_VENV) {
        Update-References
    }
    
    Write-Host ""
    Write-Host "✅ AitherOS Python environment ready!" -ForegroundColor Green
    Write-Host "   Location: $VENV_PATH" -ForegroundColor DarkGray
    Write-Host "   Python: $venvPython" -ForegroundColor DarkGray
    Write-Host ""
    
    # Return path for programmatic use
    return @{
        VenvPath = $VENV_PATH
        PythonPath = $venvPython
        Success = $true
    }
}
catch {
    Write-AitherLog "Failed to initialize Python environment: $_" -Level Error
    throw
}
