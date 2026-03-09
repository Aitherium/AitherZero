#Requires -Version 7.0

<#
.SYNOPSIS
    Get Windows long path support status

.DESCRIPTION
    Checks if Windows long path support (> 260 characters) is enabled by reading
    the registry key HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled.

.EXAMPLE
    Get-AitherWindowsLongPath
    
    Get the current long path support status

.OUTPUTS
    Hashtable - Status object with Enabled, RegistryPath, RegistryKey, and CurrentValue properties, or null if not Windows

.NOTES
    This function is Windows-only. Returns null on non-Windows platforms.
    Requires read access to the registry.

.LINK
    Enable-AitherWindowsLongPath
    Get-AitherEnvironmentConfig
#>
function Get-AitherWindowsLongPath {
[CmdletBinding()]
param()

process {
    if (-not ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT')) {
        Write-AitherLog -Message "Long path support is only applicable to Windows" -Level Warning -Source 'Get-AitherWindowsLongPath'
        return $null
    }
    
    try {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        $regKey = 'LongPathsEnabled'
        
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
        Write-AitherLog -Message "Error checking long path status: $($_.Exception.Message)" -Level Error -Source 'Get-AitherWindowsLongPath' -Exception $_
        return $null
    }
}

}

