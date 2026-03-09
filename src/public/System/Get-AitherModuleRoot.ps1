#Requires -Version 7.0

<#
.SYNOPSIS
    Get the AitherZero project root directory

.DESCRIPTION
    Returns the root directory of the AitherZero project (where config.psd1 is located).
    This is a private helper function that provides a consistent way to get the project
    root without duplicating the path calculation logic across all cmdlets.

    Uses the module-scoped $script:ProjectRoot variable if available (set during module
    initialization), otherwise calculates it from the current script location.

.NOTES
    This is a private helper function. Use Get-AitherProjectRoot for public access.
#>
function Get-AitherModuleRoot {
    # Use cached value if available (set during module initialization)
    if ($script:ProjectRoot) {
        return $script:ProjectRoot
    }

    # Fallback: use environment variable
    if ($env:AITHERZERO_ROOT) {
        return $env:AITHERZERO_ROOT
    }

    # Calculate from current script location (goes up from Public/Private to project root)
    $currentPath = $PSScriptRoot
    if (-not $currentPath) { $currentPath = $PWD.Path }

    # Walk up the directory tree to find the project root (identified by AitherZero/config/config.psd1)
    while ($currentPath) {
        if (Test-Path (Join-Path $currentPath "AitherZero/config/config.psd1")) {
            return $currentPath
        }

        $parentPath = Split-Path $currentPath -Parent
        if ($parentPath -eq $currentPath) { break } # Reached root of drive
        $currentPath = $parentPath
    }

    # Fallback: assume standard structure if config not found (e.g. during build)
    if ($PSScriptRoot) {
        # Try to find module root by looking for AitherZero.psd1
        $curr = $PSScriptRoot
        while ($curr -and -not (Test-Path (Join-Path $curr 'AitherZero.psd1'))) {
            $curr = Split-Path $curr -Parent
        }
        if ($curr) {
            # Found module root (AitherZero folder). Project root is parent.
            return Split-Path $curr -Parent
        }

        # Last resort fallback
        return Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }

    # Last resort: current location
    return Get-Location
}


