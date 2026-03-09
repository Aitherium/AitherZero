#Requires -Version 7.0

<#
.SYNOPSIS
    Enable Windows long path support

.DESCRIPTION
    Enables NTFS long path support (> 260 characters) by setting the registry key
    HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled to 1.

    This requires administrator privileges and may require a system restart to take effect.

.PARAMETER DryRun
    Preview changes without applying them

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    Enable-AitherWindowsLongPath

    Enable long path support with confirmation

.EXAMPLE
    Enable-AitherWindowsLongPath -Force

    Enable without confirmation prompt

.OUTPUTS
    Boolean - True if enabled or would be enabled, False otherwise

.NOTES
    This function is Windows-only and requires administrator privileges.
    A system restart may be required for changes to take effect.

.LINK
    Get-AitherWindowsLongPath
    Set-AitherEnvironmentConfig
#>
function Enable-AitherWindowsLongPath {
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
                    Write-AitherLog -Message "Long path support is only applicable to Windows" -Level Warning -Source 'Enable-AitherWindowsLongPath'
                }
                else {
                    Write-AitherLog -Level Warning -Message "Long path support is only applicable to Windows" -Source 'Enable-AitherWindowsLongPath'
                }
                return $false
            }

            # Check if already enabled
            $status = if (Get-Command Get-AitherWindowsLongPath -ErrorAction SilentlyContinue) {
                Get-AitherWindowsLongPath
            }
            else {
                $null
            }
            if ($status -and $status.Enabled) {
                if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                    Write-AitherLog -Message "Windows long path support is already enabled" -Level Information -Source 'Enable-AitherWindowsLongPath'
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
                    Write-AitherLog -Message "Administrator privileges required to enable long path support" -Level Warning -Source 'Enable-AitherWindowsLongPath'
                }
                else {
                    Write-AitherLog -Level Warning -Message "Administrator privileges required to enable long path support" -Source 'Enable-AitherWindowsLongPath'
                }
                return $false
            }
            if ($DryRun) {
                if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                    Write-AitherLog -Message "[DRY RUN] Would enable Windows long path support" -Level Information -Source 'Enable-AitherWindowsLongPath'
                }
                return $true
            }
            if (-not $Force) {
                $confirmation = Read-Host "Enable Windows long path support? (y/N)"
                if ($confirmation -ne 'y') {
                    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                        Write-AitherLog -Message "Operation cancelled by user" -Level Information -Source 'Enable-AitherWindowsLongPath'
                    }
                    return $false
                }
            }

            try {
                $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
                Set-ItemProperty -Path $regPath -Name 'LongPathsEnabled' -Value 1 -Type DWord
                if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                    Write-AitherLog -Message "Windows long path support enabled successfully" -Level Information -Source 'Enable-AitherWindowsLongPath'
                }
                return $true
            }
            catch {
                if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                    Write-AitherLog -Message "Error enabling long path support: $($_.Exception.Message)" -Level Error -Source 'Enable-AitherWindowsLongPath' -Exception $_
                }
                else {
                    Write-AitherLog -Level Error -Message "Error enabling long path support: $($_.Exception.Message)" -Source 'Enable-AitherWindowsLongPath' -Exception $_
                }
                throw
            }
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }

}

