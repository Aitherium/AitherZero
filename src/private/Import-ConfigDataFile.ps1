#Requires -Version 7.0

<#
.SYNOPSIS
    Import PowerShell configuration data file (internal)
.DESCRIPTION
    Safely imports .psd1 configuration files with expression evaluation.
    Internal use only - public interface through Get-AitherConfigs.
#>

function Import-ConfigDataFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    try {
        # Read file content
        $configContent = Get-Content -Path $Path -Raw -ErrorAction Stop

        # Create scriptblock and evaluate
        $scriptBlock = [scriptblock]::Create($configContent)
        $config = & $scriptBlock

        if (-not $config -or $config -isnot [hashtable]) {
            throw "Configuration file did not return a valid hashtable"
        }

        return $config
    }
    catch {
        throw "Failed to load configuration from '$Path': $($_.Exception.Message)"
    }
}

