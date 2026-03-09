#Requires -Version 7.0

<#
.SYNOPSIS
    Enable Windows Developer Mode

.DESCRIPTION
    Enables Windows Developer Mode for sideloading and development features by setting
    the registry key HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense to 1.

    This requires administrator privileges.

.PARAMETER DryRun
    Preview changes without applying them

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    Enable-AitherWindowsDeveloperMode

    Enable developer mode with confirmation

.EXAMPLE
    Enable-AitherWindowsDeveloperMode -Force

    Enable without confirmation prompt

.OUTPUTS
    Boolean - True if enabled or would be enabled, False otherwise

.NOTES
    This function is Windows-only and requires administrator privileges.

.LINK
    Get-AitherWindowsDeveloperMode
    Set-AitherEnvironmentConfig
#>
function Enable-AitherWindowsDeveloperMode {
    [CmdletBinding(SupportsShouldProcess)]
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
            # During module validation, skip execution
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
                return $false
            }

            if (-not ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT')) {
                if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                    Write-AitherLog -Message "Developer Mode is only applicable to Windows" -Level Warning -Source 'Enable-AitherWindowsDeveloperMode'
                }
                else {
                    Write-AitherLog -Level Warning -Message "Developer Mode is only applicable to Windows" -Source 'Enable-AitherWindowsDeveloperMode'
                }
                return $false
            }

            # Check if already enabled
            $status = if (Get-Command Get-AitherWindowsDeveloperMode -ErrorAction SilentlyContinue) {
                Get-AitherWindowsDeveloperMode
            }
            else {
                $null
            }
            if ($status -and $status.Enabled) {
                if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                    Write-AitherLog -Message "Windows Developer Mode is already enabled" -Level Information -Source 'Enable-AitherWindowsDeveloperMode'
                }
                return $false
            }

            # Check for admin rights
            $isAdmin = if (Get-Command Test-AitherAdmin -ErrorAction SilentlyContinue) {
                Test-AitherAdmin
            }
            else {
                $false
            }
            if (-not $isAdmin) {
                if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                    Write-AitherLog -Message "Administrator privileges required to enable Developer Mode" -Level Warning -Source 'Enable-AitherWindowsDeveloperMode'
                }
                else {
                    Write-AitherLog -Level Warning -Message "Administrator privileges required to enable Developer Mode" -Source 'Enable-AitherWindowsDeveloperMode'
                }
                return $false
            }
            if ($DryRun) {
                if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                    Write-AitherLog -Message "[DRY RUN] Would enable Windows Developer Mode" -Level Information -Source 'Enable-AitherWindowsDeveloperMode'
                }
                return $true
            }
            if (-not $Force) {
                $confirmation = Read-Host "Enable Windows Developer Mode? (y/N)"
                if ($confirmation -ne 'y') {
                    Write-AitherLog -Message "Operation cancelled by user" -Level Information -Source 'Enable-AitherWindowsDeveloperMode'
                    return $false
                }
            }

            try {
                $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
                if (-not (Test-Path $regPath)) {
                    New-Item -Path $regPath -Force | Out-Null
                }
                Set-ItemProperty -Path $regPath -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Type DWord
                Write-AitherLog -Message "Windows Developer Mode enabled successfully" -Level Information -Source 'Enable-AitherWindowsDeveloperMode'
                return $true
            }
            catch {
                Write-AitherLog -Message "Error enabling Developer Mode: $($_.Exception.Message)" -Level Error -Source 'Enable-AitherWindowsDeveloperMode' -Exception $_
                throw
            }
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }

}

