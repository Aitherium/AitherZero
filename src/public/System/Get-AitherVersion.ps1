#Requires -Version 7.0

<#
.SYNOPSIS
    Get AitherZero version and module information

.DESCRIPTION
    Returns comprehensive version information including AitherZero module version,
    PowerShell version, platform information, module root path, and build information.
    
    This cmdlet is useful for:
    - Verifying module version
    - Troubleshooting version-related issues
    - Reporting system information
    - Checking compatibility

.PARAMETER Simple
    Return only the version string (e.g., "2.0.0") instead of a detailed object.
    Useful for scripts that need just the version number.

.INPUTS
    None
    This cmdlet does not accept pipeline input.

.OUTPUTS
    PSCustomObject
    Returns version information object with properties:
    - Version: Version string
    - ModuleVersion: Module version from manifest
    - PowerShellVersion: PowerShell version
    - PowerShellEdition: PowerShell edition (Core, Desktop)
    - Platform: Platform name (Windows, Linux, macOS)
    - ModuleRoot: Path to module root
    - BuildDate: Build/commit date (if available)
    
    When -Simple is used, returns System.String (version string only).

.EXAMPLE
    Get-AitherVersion
    
    Returns detailed version information object with all properties.

.EXAMPLE
    Get-AitherVersion -Simple
    
    Returns only the version string: "2.0.0"

.EXAMPLE
    $version = Get-AitherVersion -Simple
    Write-Host "Running AitherZero version $version"
    
    Gets version string and uses it in a message.

.NOTES
    Version is read from:
    1. VERSION file in module root (if exists)
    2. Module manifest (AitherZero.psd1) ModuleVersion property
    3. Falls back to "Unknown" if neither is available
    
    Build date is determined from Git commit history if available.

.LINK
    Get-AitherPlatform
    Get-AitherStatus
#>
function Get-AitherVersion {
[OutputType([PSCustomObject], [System.String])]
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Simple
)

begin {
    $moduleRoot = Get-AitherModuleRoot
    
    # Try to read VERSION file
    $versionFile = Join-Path $moduleRoot 'VERSION'
    $version = 'Unknown'
    
    if (Test-Path $versionFile) {
        $version = (Get-Content $versionFile -Raw).Trim()
    }
    else {
        # Try to get from module manifest
        $manifestPath = Join-Path $moduleRoot 'AitherZero.psd1'
        if (Test-Path $manifestPath) {
            try {
                $manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction Stop
                $version = $manifest.ModuleVersion
            }
    catch {
                # Use default
            }
        }
    }
}

process {
    try {
        if ($Simple) {
            return $version
        }
        
        return [PSCustomObject]@{
            PSTypeName = 'AitherZero.VersionInfo'
            Version = $version
            ModuleVersion = '2.0.0'
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            PowerShellEdition = $PSVersionTable.PSEdition
            Platform = if (Get-Command Get-AitherPlatform -ErrorAction SilentlyContinue) { Get-AitherPlatform -NameOnly } else { 'Unknown' }
            ModuleRoot = $moduleRoot
            BuildDate = if (Test-Path (Join-Path $moduleRoot '.git')) {
                # Try to get last commit date
                try {
                    $gitLog = git -C $moduleRoot log -1 --format='%ci' 2>$null
                    if ($gitLog) {
                        [DateTime]::Parse($gitLog).ToString('yyyy-MM-dd')
                    }
                    else {
                        $null
                    }
                }
                catch {
                    $null
                }
            }
            else {
                $null
            }
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Getting version information" -Parameters $PSBoundParameters -ErrorAction Continue
        
        # Return fallback version info
        return [PSCustomObject]@{
            PSTypeName = 'AitherZero.VersionInfo'
            Version = 'Unknown'
            ModuleVersion = '2.0.0'
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            PowerShellEdition = $PSVersionTable.PSEdition
            Platform = 'Unknown'
            ModuleRoot = $moduleRoot
            BuildDate = $null
        }
    }
}


}

