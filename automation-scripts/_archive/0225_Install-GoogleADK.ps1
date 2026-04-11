#Requires -Version 7.0
# Stage: Development
# Dependencies: Python
# Description: Install Google Agent Development Kit (ADK)
# Tags: development, ai, google, adk

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [hashtable]$Configuration
)

. "$PSScriptRoot/_init.ps1"
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0225_Install-GoogleADK'
    } else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting Google ADK installation..."

try {
    # 1. Verify Python/Pip
    if (-not (Get-Command pip -ErrorAction SilentlyContinue) -and -not (Get-Command pip3 -ErrorAction SilentlyContinue)) {
        throw "Pip is not available. Please run 0206_Install-Python.ps1 first."
    }

    # 2. Install google-adk
    $pkg = "google-adk"
    Write-ScriptLog "Installing Python package: $pkg"

    if ($PSCmdlet.ShouldProcess("Pip", "Install $pkg")) {
        try {
            if ($IsWindows) { pip install $pkg } else { pip3 install $pkg }
            Write-ScriptLog "Successfully installed $pkg" -Level Success
        } catch {
            throw "Failed to install package ${pkg}: $_"
        }
    }

    # 3. Verify Installation
    # Assuming the binary is 'adk' or checking import
    try {
        if ($IsWindows) { python -c "import google_adk" } else { python3 -c "import google_adk" }
        Write-ScriptLog "Verified google-adk import." -Level Success
    } catch {
        Write-ScriptLog "Warning: Could not verify google-adk import. Installation might have issues." -Level Warning
    }

} catch {
    Write-ScriptLog "Google ADK installation failed: $_" -Level Error
    exit 1
}
