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
        # Both supported layouts must validate here — monorepo
        # (<root>/.PRODUCTS/.AITHERZERO/...) and standalone (<root>/AitherZero.psd1),
        # the latter being what the public Aitherium/AitherZero repo ships.
        # Accepting only the monorepo marker silently rejected a correct
        # AITHERZERO_ROOT on a public checkout and fell through to "current
        # directory", so resolution depended on where the user happened to cd.
        $isProjectRoot = {
            param($p)
            $p -and (
                (Test-Path (Join-Path $p ".PRODUCTS/.AITHERZERO/config/config.psd1")) -or
                (Test-Path (Join-Path $p ".PRODUCTS/.AITHERZERO/AitherZero.psd1")) -or
                # Standalone, excluding the monorepo's own .PRODUCTS/.AITHERZERO
                # directory, which carries the identical marker pair.
                ((Test-Path (Join-Path $p "config/config.psd1")) -and
                 (Test-Path (Join-Path $p "AitherZero.psd1")) -and
                 (Split-Path (Split-Path $p -Parent) -Leaf) -ne '.PRODUCTS')
            )
        }

        # 1. Check environment variable first
        if ($env:AITHERZERO_ROOT -and (Test-Path $env:AITHERZERO_ROOT)) {
            if (& $isProjectRoot $env:AITHERZERO_ROOT) {
                return $env:AITHERZERO_ROOT
            }
        }

        # 2. Try to find from module location
        # If this function is running from the module, we can derive root
        # Module is now at <Root>/.PRODUCTS/.AITHERZERO/AitherZero.psm1 or <Root>/.PRODUCTS/.AITHERZERO/bin/AitherZero.psm1
        if ($PSScriptRoot) {
            $testPath = $PSScriptRoot
            for ($i = 0; $i -lt 5; $i++) {
                if (& $isProjectRoot $testPath) {
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
            if (& $isProjectRoot $testPath) {
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

