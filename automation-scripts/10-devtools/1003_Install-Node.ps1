#Requires -Version 7.0
# Stage: Development
# Dependencies: AitherZero
# Description: Install Node.js runtime using Install-AitherPackage.

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [hashtable]$Configuration
)

. "$PSScriptRoot/_init.ps1"

if (-not $Configuration) {
    $Configuration = Get-AitherConfigs -ErrorAction SilentlyContinue
}

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0201_Install-Node'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting Node.js installation..."

try {
    # 1. Check Configuration
    Ensure-FeatureEnabled -Section "Features" -Key "Development.Node" -Name "Node.js"

    # Reload config to ensure we have the latest state
    $Configuration = Get-AitherConfigs
    $nodeConfig = $Configuration.Features.Development.Node

    # 2. Install Node.js
    if ($PSCmdlet.ShouldProcess("System", "Install Node.js")) {
        # Setup Linux Repositories if needed (simplified)
        if ($IsLinux) {
            if (Get-Command apt-get -ErrorAction SilentlyContinue) {
                # Optional: Add NodeSource logic here if strict versioning required,
                # but for now we rely on standard package manager or user pre-configuration.
                # To match previous script behavior exactly is hard without bloating this script again.
                # We assume Install-AitherPackage does the job.
            }
        }

        # Core Install
        Install-AitherPackage -Name "nodejs" -WingetId "OpenJS.NodeJS" -BrewName "node" -AptName "nodejs" -YumName "nodejs"
    }

    # 3. Verify Installation
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $v = node --version
        Write-ScriptLog "Node.js installed: $v" -Level Success
    }
    else {
        throw "Node.js command 'node' not found after installation."
    }

    # 4. Install Global Packages
    if ($nodeConfig -and $nodeConfig.GlobalPackages) {
        foreach ($pkg in $nodeConfig.GlobalPackages) {
            Write-ScriptLog "Installing global package: $pkg"
            if ($PSCmdlet.ShouldProcess("npm", "install -g $pkg")) {
                npm install -g $pkg
            }
        }
    }

}
catch {
    Write-ScriptLog "Node.js installation failed: $_" -Level Error
    exit 1
}
