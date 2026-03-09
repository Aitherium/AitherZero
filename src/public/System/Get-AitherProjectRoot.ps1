#Requires -Version 7.0

<#
.SYNOPSIS
    Get the AitherZero project root path

.DESCRIPTION
    Returns the root directory of the AitherZero project. Checks multiple
    sources: environment variable, module location, or current directory.

.EXAMPLE
    $root = Get-AitherProjectRoot
    $configPath = Join-Path $root "config.psd1"

    Get project root and construct config path

.OUTPUTS
    System.String - The project root directory path

.NOTES
    Checks AITHERZERO_ROOT environment variable first, then derives from module location.

.LINK
    Get-AitherConfigs
#>
function Get-AitherProjectRoot {
[CmdletBinding()]
param()

process { try {
        # 1. Check environment variable first
        if ($env:AITHERZERO_ROOT -and (Test-Path $env:AITHERZERO_ROOT)) {
            # Validate it looks like a project root (has config.psd1 or AitherZero folder)
            if ((Test-Path (Join-Path $env:AITHERZERO_ROOT "AitherZero/config/config.psd1")) -or
                (Test-Path (Join-Path $env:AITHERZERO_ROOT "AitherZero/AitherZero.psd1"))) {
                return $env:AITHERZERO_ROOT
            }
        }

        # 2. Try to find from module location
        # If this function is running from the module, we can derive root
        # Module is usually at <Root>/AitherZero/AitherZero.psm1 or <Root>/AitherZero/bin/AitherZero.psm1
        if ($PSScriptRoot) {
            $testPath = $PSScriptRoot
            for ($i = 0; $i -lt 4; $i++) {
                if (Test-Path (Join-Path $testPath "AitherZero/config/config.psd1")) {
                    return $testPath
                }
                $testPath = Split-Path $testPath -Parent
                if (-not $testPath) { break }
            }
        }

        # 3. Try current directory and walk up
        $currentPath = Get-Location
        $testPath = $currentPath.Path
        while ($testPath) {
            if (Test-Path (Join-Path $testPath "AitherZero/config/config.psd1")) {
                return $testPath
            }
            $parent = Split-Path $testPath -Parent
            if ($parent -eq $testPath) { break } # Root reached
            $testPath = $parent
        }

        # 4. Fallback to current directory if nothing else found
        # This is likely wrong but better than crashing
        Write-AitherLog -Level Warning -Message "Could not determine AitherZero project root. Using current directory." -Source 'Get-AitherProjectRoot'
        return $currentPath.Path
    }
    catch {
        Write-AitherLog -Message "Error determining project root: $($_.Exception.Message)" -Level Warning -Source 'Get-AitherProjectRoot' -Exception $_
        return Get-Location
    }
}

}

