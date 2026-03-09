#Requires -Version 7.0

<#
.SYNOPSIS
    Add AitherZero integration to shell profiles (Unix)

.DESCRIPTION
    Adds AitherZero initialization code to shell config files (.bashrc, .zshrc, or fish config).
    Detects the current shell and adds appropriate integration code.

.PARAMETER DryRun
    Preview changes without applying

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    Add-AitherShellIntegration

    Add AitherZero integration to the current shell's config file

.EXAMPLE
    Add-AitherShellIntegration -DryRun

    Preview the integration code that would be added

.OUTPUTS
    Boolean - True if integration was added or would be added, False otherwise

.NOTES
    This function is Linux/macOS only.
    Supports bash, zsh, and fish shells.
    Checks if integration already exists before adding.

.LINK
    Set-AitherEnvironmentConfig
    Get-AitherEnvironmentConfig
#>
function Add-AitherShellIntegration {
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [switch]$Force,

        [Parameter(HelpMessage = "Show command output in console.")]
        [switch]$ShowOutput
    )

    begin {
        # Manage logging targets for this execution
        $originalLogTargets = $script:AitherLogTargets
        if ($ShowOutput) {
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
        else {
            # Ensure Console is NOT in targets if ShowOutput is not specified
            $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
        }
    }

    process {
        try {
            # Use fallback if Write-AitherLog not available yet
            $logCmd = if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                { param($msg, $level, $src) Write-AitherLog -Message $msg -Level $level -Source $src }
            }
            else {
                { param($msg, $level, $src) Write-Warning "$src`: $msg" }
            }
            if (-not ($IsLinux -or $IsMacOS)) {
                & $logCmd "Shell integration is only applicable to Linux/macOS" "Warning" 'Add-AitherShellIntegration'
                return $false
            }

            $shellConfig = $null
            $shell = $env:SHELL

            # Determine shell config file
            if ($shell -like '*bash*') {
                $shellConfig = Join-Path $env:HOME '.bashrc'
            }
            elseif ($shell -like '*zsh*') {
                $shellConfig = Join-Path $env:HOME '.zshrc'
            }
            elseif ($shell -like '*fish*') {
                $shellConfig = Join-Path $env:HOME '.config' 'fish' 'config.fish'
            }
            else {
                & $logCmd "Unsupported shell: $shell" "Warning" 'Add-AitherShellIntegration'
                return $false
            }
            if (-not (Test-Path $shellConfig)) {
                & $logCmd "Shell config file not found: $shellConfig" "Warning" 'Add-AitherShellIntegration'
                return $false
            }

            # Check if already integrated
            $content = Get-Content $shellConfig -Raw
            if ($content -match 'AITHERZERO_ROOT') {
                & $logCmd "AitherZero already integrated in $shellConfig" "Information" 'Add-AitherShellIntegration'
                return $false
            }

            $moduleRoot = Get-AitherModuleRoot
            $aitherZeroRoot = if ($env:AITHERZERO_ROOT) { $env:AITHERZERO_ROOT }
            else { $moduleRoot }

            $integrationCode = @"

# AitherZero Integration
export AITHERZERO_ROOT="$aitherZeroRoot"
export PATH="`$PATH:`$AITHERZERO_ROOT/library/automation-scripts"
"@

            if ($DryRun) {
                & $logCmd "[DRY RUN] Would add to $shellConfig : $integrationCode" "Information" 'Add-AitherShellIntegration'
                return $true
            }

            # Skip prompt in CI or when Force is specified
            $isCI = $env:CI -eq 'true' -or $env:AITHERZERO_CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true'

            if (-not $Force -and -not $isCI) {
                $confirmation = Read-Host "Add AitherZero integration to $shellConfig? (y/N)"
                if ($confirmation -ne 'y') {
                    & $logCmd "Operation cancelled" "Information" 'Add-AitherShellIntegration'
                    return $false
                }
            }

            try {
                Add-Content -Path $shellConfig -Value $integrationCode
                & $logCmd "Added AitherZero integration to $shellConfig" "Information" 'Add-AitherShellIntegration'
                return $true
            }
            catch {
                & $logCmd "Error adding shell integration: $($_.Exception.Message)" "Error" 'Add-AitherShellIntegration'
                throw
            }
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }

}

