#Requires -Version 7.0

<#
.SYNOPSIS
    Get platform information for the current system

.DESCRIPTION
    Returns detailed information about the current platform including:
    - Operating system name (Windows, Linux, macOS)
    - Architecture (x64, ARM64, etc.)
    - PowerShell version
    - Platform-specific details

.PARAMETER Detailed
    Return detailed platform information object

.PARAMETER NameOnly
    Return only the platform name string

.EXAMPLE
    Get-AitherPlatform

    Returns platform name: "Windows", "Linux", or "macOS"

.EXAMPLE
    Get-AitherPlatform -Detailed

    Returns detailed platform information object

.EXAMPLE
    Get-AitherPlatform -NameOnly

    Returns only the platform name string

.OUTPUTS
    [string] or [PSCustomObject]
    Returns platform name string by default, or detailed object with -Detailed

.NOTES
    Cross-platform function that works on Windows, Linux, and macOS.
    Uses PowerShell 7+ automatic variables ($IsWindows, $IsLinux, $IsMacOS).

.LINK
    Test-AitherAdmin
    Get-AitherVersion
#>
function Get-AitherPlatform {
[CmdletBinding(DefaultParameterSetName = 'Simple')]
param(
    [Parameter(ParameterSetName = 'Detailed')]
    [switch]$Detailed,

    [Parameter(ParameterSetName = 'Simple')]
    [switch]$NameOnly
)

begin {
    # Platform detection
    if ($IsWindows) {
        $platformName = 'Windows'
    }
    elseif ($IsLinux) {
        $platformName = 'Linux'
    }
    elseif ($IsMacOS) {
        $platformName = 'macOS'
    }
    else {
        $platformName = 'Unknown'
    }
}

process {
    if ($NameOnly) {
        return $platformName
    }
    
    if ($Detailed) {
        $osInfo = if ($IsWindows) {
            [System.Environment]::OSVersion
        }
        else {
            $null
        }
        
        return [PSCustomObject]@{
            Name = $platformName
            Architecture = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } else { 'Unknown' }
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            OSVersion = if ($osInfo) { $osInfo.VersionString } else { 'Unknown' }
            IsWindows = $IsWindows
            IsLinux = $IsLinux
            IsMacOS = $IsMacOS
            IsCoreCLR = $PSVersionTable.PSEdition -eq 'Core'
        }
    }

    # Default: return platform name
    return $platformName
}

}

