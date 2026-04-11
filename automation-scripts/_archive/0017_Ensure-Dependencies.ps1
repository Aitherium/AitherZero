#Requires -Version 7.0
<#
.SYNOPSIS
    Ensure required Python dependencies are installed.

.DESCRIPTION
    Auto-installs missing Python packages in the AitherOS virtual environment.
    Run this before scripts that need specific packages (like vastai for GPU provisioning).
    
    This is designed to be called from other scripts to ensure deps are available:
        . $PSScriptRoot/0017_Ensure-Dependencies.ps1
        Ensure-Dependency -Package "vastai" -Feature "GPU Provisioning"

.PARAMETER Package
    Single package to ensure is installed.

.PARAMETER Packages
    Array of packages to ensure are installed.

.PARAMETER Feature
    Feature name for logging purposes.

.PARAMETER Quiet
    Suppress output unless errors occur.

.EXAMPLE
    .\0017_Ensure-Dependencies.ps1 -Package vastai
    # Ensures vastai is installed

.EXAMPLE
    .\0017_Ensure-Dependencies.ps1 -Packages @("vastai", "paramiko", "cloudflare")
    # Ensures multiple packages are installed

.NOTES
    Author: Aitherium
    Category: 0000-0099 Environment Setup
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Package,
    [string[]]$Packages = @(),
    [string]$Feature = "AitherOS",
    [switch]$Quiet
)

# Load common utilities
. $PSScriptRoot/../_init.ps1

# ============================================================================
# CONFIGURATION
# ============================================================================

$AITHEROS_ROOT = Join-Path $REPO_ROOT "AitherOS"
$VENV_PATH = Join-Path $AITHEROS_ROOT ".venv"
$LEGACY_VENV = Join-Path $AITHEROS_ROOT "agents/NarrativeAgent/.venv"

# Known package mappings (pip name -> import name if different)
$PACKAGE_IMPORT_MAP = @{
    "vastai" = "vastai"
    "google-adk" = "google.adk"
    "google-genai" = "google.genai"
    "pillow" = "PIL"
    "pyyaml" = "yaml"
    "python-dotenv" = "dotenv"
    "chromadb" = "chromadb"
    "qdrant-client" = "qdrant_client"
}

# ============================================================================
# FUNCTIONS
# ============================================================================

function Get-AitherPython {
    <#
    .SYNOPSIS
        Get the path to the AitherOS Python executable.
    #>
    
    # Prefer new location
    $newVenv = if ($IsWindows -or $env:OS -match "Windows") {
        Join-Path $VENV_PATH "Scripts/python.exe"
    } else {
        Join-Path $VENV_PATH "bin/python"
    }
    
    if (Test-Path $newVenv) {
        return $newVenv
    }
    
    # Fall back to legacy location
    $legacyVenv = if ($IsWindows -or $env:OS -match "Windows") {
        Join-Path $LEGACY_VENV "Scripts/python.exe"
    } else {
        Join-Path $LEGACY_VENV "bin/python"
    }
    
    if (Test-Path $legacyVenv) {
        if (-not $Quiet) {
            Write-AitherLog "Using legacy venv - consider running 0016_Initialize-PythonEnvironment.ps1" -Level Warn
        }
        return $legacyVenv
    }
    
    # Fall back to system Python
    $systemPython = Get-Command python -ErrorAction SilentlyContinue
    if ($systemPython) {
        if (-not $Quiet) {
            Write-AitherLog "Using system Python - venv not found" -Level Warn
        }
        return $systemPython.Source
    }
    
    throw "No Python installation found. Run 0016_Initialize-PythonEnvironment.ps1 first."
}

function Test-PackageInstalled {
    <#
    .SYNOPSIS
        Check if a Python package is installed.
    #>
    param(
        [string]$PythonPath,
        [string]$PackageName
    )
    
    # Get import name
    $importName = $PackageName -replace "-", "_"
    if ($PACKAGE_IMPORT_MAP.ContainsKey($PackageName)) {
        $importName = $PACKAGE_IMPORT_MAP[$PackageName]
    }
    
    # Try importing the package
    $result = & $PythonPath -c "import $importName" 2>&1
    return $LASTEXITCODE -eq 0
}

function Install-Package {
    <#
    .SYNOPSIS
        Install a Python package using pip.
    #>
    param(
        [string]$PythonPath,
        [string]$PackageName,
        [string]$Feature = "AitherOS"
    )
    
    if (-not $Quiet) {
        Write-Host "📦 Installing $PackageName for $Feature..." -ForegroundColor Cyan
    }
    
    $output = & $PythonPath -m pip install $PackageName 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-AitherLog "Failed to install $PackageName: $output" -Level Error
        return $false
    }
    
    if (-not $Quiet) {
        Write-Host "✅ $PackageName installed successfully" -ForegroundColor Green
    }
    
    return $true
}

function Ensure-Dependency {
    <#
    .SYNOPSIS
        Ensure a single dependency is installed.
    .DESCRIPTION
        This function can be called from other scripts to ensure packages are available.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Package,
        [string]$Feature = "AitherOS"
    )
    
    $pythonPath = Get-AitherPython
    
    # Check if already installed
    if (Test-PackageInstalled -PythonPath $pythonPath -PackageName $Package) {
        if (-not $Quiet) {
            Write-Host "✓ $Package already installed" -ForegroundColor DarkGray
        }
        return $true
    }
    
    # Install it
    return Install-Package -PythonPath $pythonPath -PackageName $Package -Feature $Feature
}

function Ensure-Dependencies {
    <#
    .SYNOPSIS
        Ensure multiple dependencies are installed.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Packages,
        [string]$Feature = "AitherOS"
    )
    
    $pythonPath = Get-AitherPython
    $success = $true
    $installed = @()
    $failed = @()
    
    foreach ($pkg in $Packages) {
        if (Test-PackageInstalled -PythonPath $pythonPath -PackageName $pkg) {
            continue
        }
        
        if (Install-Package -PythonPath $pythonPath -PackageName $pkg -Feature $Feature) {
            $installed += $pkg
        }
        else {
            $failed += $pkg
            $success = $false
        }
    }
    
    if ($installed.Count -gt 0 -and -not $Quiet) {
        Write-Host "📦 Installed: $($installed -join ', ')" -ForegroundColor Green
    }
    
    if ($failed.Count -gt 0) {
        Write-AitherLog "Failed to install: $($failed -join ', ')" -Level Error
    }
    
    return $success
}

# ============================================================================
# MAIN
# ============================================================================

# If called directly with parameters
if ($Package -or $Packages.Count -gt 0) {
    $allPackages = @()
    
    if ($Package) {
        $allPackages += $Package
    }
    $allPackages += $Packages
    
    if ($allPackages.Count -eq 1) {
        $result = Ensure-Dependency -Package $allPackages[0] -Feature $Feature
    }
    else {
        $result = Ensure-Dependencies -Packages $allPackages -Feature $Feature
    }
    
    exit $(if ($result) { 0 } else { 1 })
}

# Export functions for dot-sourcing
Export-ModuleMember -Function @(
    "Get-AitherPython",
    "Test-PackageInstalled",
    "Install-Package",
    "Ensure-Dependency",
    "Ensure-Dependencies"
) -ErrorAction SilentlyContinue
