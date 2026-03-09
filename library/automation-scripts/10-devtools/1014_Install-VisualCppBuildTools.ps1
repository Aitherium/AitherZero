<#
.SYNOPSIS
    Installs Microsoft Visual C++ Build Tools for compiling Python C extensions.

.DESCRIPTION
    Downloads and silently installs Visual Studio Build Tools with the C++ workload.
    Required for packages like insightface, torch_scatter, and other packages with
    Cython/C++ extensions on Python 3.13+.

.PARAMETER ShowOutput
    Show detailed output during installation.

.PARAMETER Force
    Force reinstallation even if already installed.

.PARAMETER Minimal
    Install only the minimal C++ build tools (faster, smaller).

.EXAMPLE
    .\0224_Install-VisualCppBuildTools.ps1 -ShowOutput
    
.NOTES
    Script Number: 0224
    Category: Dev Tools (0200-0299)
    Requires: Administrator privileges
#>

[CmdletBinding()]
param(
    [switch]$ShowOutput,
    [switch]$Force,
    [switch]$Minimal
)

. "$PSScriptRoot/_init.ps1"

#region Constants
$InstallerUrl = "https://aka.ms/vs/17/release/vs_buildtools.exe"
$InstallerPath = Join-Path $env:TEMP "vs_buildtools.exe"
$LogPath = Join-Path $env:TEMP "vs_buildtools_install.log"

# Workload IDs for C++ Build Tools
$MinimalWorkloads = @(
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "--add", "Microsoft.VisualStudio.Component.Windows11SDK.22621"
)

$FullWorkloads = @(
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
    "--add", "Microsoft.VisualStudio.Component.VC.ATL",
    "--add", "Microsoft.VisualStudio.Component.VC.ATLMFC",
    "--add", "Microsoft.VisualStudio.Component.Windows11SDK.22621",
    "--add", "Microsoft.VisualStudio.Component.VC.Llvm.Clang",
    "--add", "Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset"
)
#endregion

#region Functions
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-VCToolsInstalled {
    # Check for vswhere.exe
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vsWhere)) {
        return $false
    }
    
    # Check if VC tools are installed
    $result = & $vsWhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    return -not [string]::IsNullOrWhiteSpace($result)
}

function Test-ClCompiler {
    # Quick check if cl.exe is accessible
    $vcVars = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    )
    
    foreach ($vcVar in $vcVars) {
        if (Test-Path $vcVar) {
            return $true
        }
    }
    return $false
}

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    
    if (-not $ShowOutput) { return }
    
    switch ($Type) {
        "Success" { Write-Host "✅ $Message" -ForegroundColor Green }
        "Warning" { Write-Host "⚠️ $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "❌ $Message" -ForegroundColor Red }
        "Info"    { Write-Host "ℹ️ $Message" -ForegroundColor Cyan }
        default   { Write-Host "  $Message" }
    }
}
#endregion

#region Main
Write-Status "Visual C++ Build Tools Installer" "Info"
Write-Status "=================================" "Info"

# Check if already installed
if ((Test-VCToolsInstalled -or Test-ClCompiler) -and -not $Force) {
    Write-Status "Visual C++ Build Tools are already installed." "Success"
    Write-Status "Use -Force to reinstall." "Info"
    exit 0
}

# Check for admin rights
if (-not (Test-Administrator)) {
    Write-Status "Administrator privileges required. Attempting elevation..." "Warning"
    
    # Re-run as admin
    $scriptPath = $MyInvocation.MyCommand.Path
    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath)
    if ($ShowOutput) { $args += "-ShowOutput" }
    if ($Force) { $args += "-Force" }
    if ($Minimal) { $args += "-Minimal" }
    
    try {
        Start-Process -FilePath "pwsh.exe" -ArgumentList $args -Verb RunAs -Wait
        exit $LASTEXITCODE
    }
    catch {
        Write-Status "Failed to elevate privileges: $_" "Error"
        exit 1
    }
}

# Download installer
Write-Status "Downloading Visual Studio Build Tools installer..." "Info"
try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing
    Write-Status "Downloaded to: $InstallerPath" "Success"
}
catch {
    Write-Status "Failed to download installer: $_" "Error"
    exit 1
}

# Build installation arguments
$workloads = if ($Minimal) { $MinimalWorkloads } else { $FullWorkloads }
$installArgs = @(
    "--quiet",
    "--wait",
    "--norestart",
    "--nocache",
    "--installPath", "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools",
    "--log", $LogPath
) + $workloads

Write-Status "Installing Visual C++ Build Tools (this may take 5-15 minutes)..." "Info"
if ($Minimal) {
    Write-Status "Installing minimal workload for Python extension building" "Info"
} else {
    Write-Status "Installing full C++ development workload" "Info"
}

# Run installer
try {
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru
    $exitCode = $process.ExitCode
    
    # VS installer exit codes:
    # 0 = Success
    # 3010 = Success, reboot required
    # 5007 = Operation was blocked
    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        Write-Status "Visual C++ Build Tools installed successfully!" "Success"
        
        if ($exitCode -eq 3010) {
            Write-Status "A system restart is recommended to complete the installation." "Warning"
        }
        
        # Verify installation
        Start-Sleep -Seconds 2
        if (Test-VCToolsInstalled) {
            Write-Status "Installation verified - cl.exe compiler is available." "Success"
        }
        
        # Clean up
        Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue
        
        Write-Status "" "Info"
        Write-Status "You can now install packages requiring C++ compilation:" "Info"
        Write-Status "  pip install insightface" "Info"
        Write-Status "  pip install torch_scatter" "Info"
        
        exit 0
    }
    else {
        Write-Status "Installation failed with exit code: $exitCode" "Error"
        Write-Status "Check log file: $LogPath" "Error"
        exit $exitCode
    }
}
catch {
    Write-Status "Installation error: $_" "Error"
    exit 1
}
finally {
    # Cleanup installer if it exists
    if (Test-Path $InstallerPath) {
        Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue
    }
}
#endregion
