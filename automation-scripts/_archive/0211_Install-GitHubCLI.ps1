#Requires -Version 7.0

<#
.SYNOPSIS
    Install GitHub CLI (gh)
.DESCRIPTION
    Installs the GitHub CLI tool for command-line interaction with GitHub.
    Supports Windows, Linux, and macOS.
.PARAMETER Force
    Force reinstallation even if already installed
.PARAMETER Configure
    Configure gh after installation (authentication)
.EXAMPLE
    ./0211_Install-GitHubCLI.ps1
.EXAMPLE
    ./0211_Install-GitHubCLI.ps1 -Force -Configure
.NOTES
    Stage: Development Tools
    Dependencies: None
    Tags: github, cli, development, git
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Configure
)

. "$PSScriptRoot/_init.ps1"
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0211_Install-GitHubCLI'
    } else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting GitHub CLI installation..."

try {
    # Check if already installed and not forced
    if (-not $Force -and (Get-Command gh -ErrorAction SilentlyContinue)) {
         Write-ScriptLog "GitHub CLI is already installed."
         exit 0
    }

    # Install GitHub CLI
    if ($PSCmdlet.ShouldProcess("System", "Install GitHub CLI")) {
        Install-AitherPackage -Name "gh" -WingetId "GitHub.cli" -ChocoId "gh" -BrewName "gh" -AptName "gh" -YumName "gh"
    }

    # Verify
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $v = (gh --version | Select-Object -First 1)
        Write-ScriptLog "GitHub CLI installed: $v" -Level Success

        # Configure if requested
        if ($Configure) {
             Write-ScriptLog "Configuring GitHub CLI..."
             if ($PSCmdlet.ShouldProcess("GH", "Auth Login")) {
                 gh auth login
             }
        }
    } else {
        throw "GitHub CLI command not found after installation."
    }

} catch {
    Write-ScriptLog "GitHub CLI installation failed: $_" -Level Error
    exit 1
}
