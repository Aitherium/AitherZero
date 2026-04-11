#Requires -Version 7.0
# Stage: Development
# Dependencies: AitherZero
# Description: Install Git version control system using Install-AitherPackage.

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
        Write-AitherLog -Message $Message -Level $Level -Source '0207_Install-Git'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting Git installation..."

try {
    # 1. Check Configuration
    Ensure-FeatureEnabled -Section "Features" -Key "Core.Git" -Name "Git"

    # Reload config
    $Configuration = Get-AitherConfigs

    # 2. Install Git
    # Install-AitherPackage handles OS detection and package manager selection
    if ($PSCmdlet.ShouldProcess("System", "Install Git")) {
        Install-AitherPackage -Name "git" -WingetId "Git.Git"
    }

    # 3. Verify Installation
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $gitVersion = git --version
        Write-ScriptLog "Git is installed: $gitVersion" -Level Success
    }
    else {
        throw "Git command not found after installation attempt."
    }

}
catch {
    Write-ScriptLog "Git installation failed: $_" -Level Error
    exit 1
}
