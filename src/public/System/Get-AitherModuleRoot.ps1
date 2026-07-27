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
    # SELF-HEAL: never trust a value that points into a transient git worktree
    # (…\.claude\worktrees\*) — a parallel workflow's shadow copy loaded off
    # PSModulePath can poison the cache/env, which sends playbook + script lookups
    # to the wrong checkout. Such values are ignored so we fall through to the
    # canonical walk-up below.
    $_isWorktree = { param($p) $p -and ($p -match '[\\/]\.claude[\\/]worktrees[\\/]') }

    # HARD FIX (worktree shadow): if THIS module is running from inside a transient
    # workflow worktree (…/.claude/worktrees/<id>/…), map straight back to the MAIN
    # repo root — the directory that CONTAINS .claude/worktrees. Otherwise the
    # walk-up below re-finds the worktree's OWN .PRODUCTS/.AITHERZERO/config.psd1 and
    # pins every playbook/script lookup to a STALE checkout (the "Playbook not found"
    # bug: a new playbook committed to the main repo is invisible to the worktree copy).
    # D-882: read $script:ProjectRoot DEFENSIVELY. The module runs under
    # StrictMode, where reading a variable that was never set THROWS instead of
    # yielding $null - and $script: does not resolve to the module's scope on
    # every path this function can be reached by (0803's health check hit
    # exactly this and reported its whole Module Status section as failed).
    # A missing root must degrade to the fallbacks below, not detonate.
    $cachedRoot = if (Get-Variable -Name 'ProjectRoot' -Scope Script -ErrorAction SilentlyContinue) { $script:ProjectRoot } else { $null }

    foreach ($p in @($PSScriptRoot, $cachedRoot, $PWD.Path)) {
        if ($p -and ($p -match '^(.*?)[\\/]\.claude[\\/]worktrees[\\/]')) {
            $mainRoot = $matches[1]
            if (Test-Path (Join-Path $mainRoot '.PRODUCTS/.AITHERZERO/config/config.psd1')) {
                return $mainRoot
            }
        }
    }

    # Use cached value if available (set during module initialization)
    if ($cachedRoot -and -not (& $_isWorktree $cachedRoot)) {
        return $cachedRoot
    }

    # Fallback: use environment variable
    if ($env:AITHERZERO_ROOT -and -not (& $_isWorktree $env:AITHERZERO_ROOT)) {
        return $env:AITHERZERO_ROOT
    }

    # Calculate from current script location (goes up from Public/Private to project root)
    $currentPath = $PSScriptRoot
    if (-not $currentPath) { $currentPath = $PWD.Path }

    # Walk up the directory tree looking for EITHER supported layout.
    #
    # TWO LAYOUTS EXIST and both must resolve (2026-07-25):
    #   monorepo   <root>/.PRODUCTS/.AITHERZERO/config/config.psd1   (project root = <root>)
    #   standalone <root>/config/config.psd1                          (project root = <root>)
    # The standalone case is what the PUBLIC Aitherium/AitherZero repo ships —
    # there is no .PRODUCTS/ there at all. Testing only the monorepo marker made
    # every walk-up fall through to the depth-2 fallback below, which returned a
    # directory OUTSIDE the repo. Get-AitherConfigs then reported
    # "Base configuration file not found: <parent>/AitherZero/config/config.psd1"
    # and Invoke-AitherScript could not run a single script for a public user.
    # Monorepo is checked FIRST so a nested checkout still resolves to the outer
    # root exactly as before.
    while ($currentPath) {
        if (Test-Path (Join-Path $currentPath ".PRODUCTS/.AITHERZERO/config/config.psd1")) {
            return $currentPath
        }
        # Standalone marker, but NOT when this directory is itself the monorepo's
        # <root>/.PRODUCTS/.AITHERZERO — that directory carries the same two files,
        # so without this guard the walk-up stops there and reports the module dir
        # as the project root instead of the outer repo.
        if ((Test-Path (Join-Path $currentPath "config/config.psd1")) -and
            (Test-Path (Join-Path $currentPath "AitherZero.psd1")) -and
            (Split-Path (Split-Path $currentPath -Parent) -Leaf) -ne '.PRODUCTS') {
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
            # $curr is the directory HOLDING the manifest. In the standalone
            # layout that IS the project root — do not climb out of the repo.
            if (Test-Path (Join-Path $curr 'config/config.psd1')) {
                return $curr
            }
            # Monorepo: manifest sits at <root>/.PRODUCTS/.AITHERZERO, so the
            # project root is two levels up.
            return Split-Path (Split-Path $curr -Parent) -Parent
        }

        # Last resort fallback (module is now at .PRODUCTS/.AITHERZERO/, so go up 2 levels)
        return Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    }

    # Last resort: current location
    return Get-Location
}


