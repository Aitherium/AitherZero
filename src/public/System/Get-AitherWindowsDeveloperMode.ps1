#Requires -Version 7.0

<#
.SYNOPSIS
    Get Windows Developer Mode status

.DESCRIPTION
    Checks if Windows Developer Mode is enabled by reading the registry key
    HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense.

.EXAMPLE
    Get-AitherWindowsDeveloperMode
    
    Get the current Developer Mode status

.OUTPUTS
    Hashtable - Status object with Enabled, RegistryPath, RegistryKey, and CurrentValue properties, or null if not Windows

.NOTES
    This function is Windows-only. Returns null on non-Windows platforms.
    Requires read access to the registry.

.LINK
    Enable-AitherWindowsDeveloperMode
    Get-AitherEnvironmentConfig
#>
function Get-AitherWindowsDeveloperMode {
[CmdletBinding()]
param()

process {
    if (-not ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT')) {
        Write-AitherLog -Message "Developer Mode is only applicable to Windows" -Level Warning -Source 'Get-AitherWindowsDeveloperMode'
        return $null
    }
    
    try {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
        $regKey = 'AllowDevelopmentWithoutDevLicense'
        
        if (Test-Path $regPath) {
            $value = Get-ItemProperty -Path $regPath -Name $regKey -ErrorAction SilentlyContinue
            return @{
                Enabled = ($value.$regKey -eq 1)
                RegistryPath = $regPath
                RegistryKey = $regKey
                CurrentValue = $value.$regKey
            }
        }
        else {
            return @{
                Enabled = $false
                RegistryPath = $regPath
                RegistryKey = $regKey
                CurrentValue = $null
            }
        }
    }
    catch {
        Write-AitherLog -Message "Error checking developer mode status: $($_.Exception.Message)" -Level Error -Source 'Get-AitherWindowsDeveloperMode' -Exception $_
        return $null
    }
}

}

