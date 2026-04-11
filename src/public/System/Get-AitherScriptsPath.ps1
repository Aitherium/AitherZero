function Get-AitherScriptsPath {
    <#
    .SYNOPSIS
        Robustly locates the automation-scripts directory.
    .DESCRIPTION
        Uses multiple strategies to find the 'library/automation-scripts' directory:
        1. Environment variable AITHERZERO_SCRIPTS_PATH
        2. Searches from current location upward for the marker file
        3. Searches from module location upward for the marker file
    #>
    [CmdletBinding()]
    param()

    # Use _init.ps1 as marker - it exists in the root automation-scripts directory
    $marker = "_init.ps1"

    # 1. Check Environment Variable
    if ($env:AITHERZERO_SCRIPTS_PATH -and (Test-Path $env:AITHERZERO_SCRIPTS_PATH)) {
        if (Test-Path (Join-Path $env:AITHERZERO_SCRIPTS_PATH $marker)) {
            Write-Verbose "Found scripts path via env var: $env:AITHERZERO_SCRIPTS_PATH"
            return $env:AITHERZERO_SCRIPTS_PATH
        }
    }

    # 2. Search from current working directory upward
    $current = $PWD.Path
    $iterations = 0
    $maxIterations = 10

    while ($current -and $iterations -lt $maxIterations) {
        $iterations++

        # Look for automation-scripts directory directly
        $automationScriptsDir = Join-Path $current "AitherZero\library\automation-scripts"
        if (Test-Path $automationScriptsDir) {
            $markerPath = Join-Path $automationScriptsDir $marker
            if (Test-Path $markerPath) {
                Write-Verbose "Found scripts path via PWD search: $automationScriptsDir"
                return $automationScriptsDir
            }
        }

        # Also check for library/automation-scripts pattern
        $libraryDir = Join-Path $current "library\automation-scripts"
        if (Test-Path $libraryDir) {
            $markerPath = Join-Path $libraryDir $marker
            if (Test-Path $markerPath) {
                Write-Verbose "Found scripts path via library search: $libraryDir"
                return $libraryDir
            }
        }

        $parent = Split-Path $current -Parent
        if ($parent -eq $current -or [string]::IsNullOrEmpty($parent)) { break }
        $current = $parent
    }

    # 3. Search from module location upward
    try {
        $moduleRoot = Get-AitherModuleRoot
        $current = $moduleRoot
        $iterations = 0

        while ($current -and $iterations -lt $maxIterations) {
            $iterations++

            # Look for automation-scripts directory directly
            $automationScriptsDir = Join-Path $current "library\automation-scripts"
            if (Test-Path $automationScriptsDir) {
                $markerPath = Join-Path $automationScriptsDir $marker
                if (Test-Path $markerPath) {
                    Write-Verbose "Found scripts path via module root search: $automationScriptsDir"
                    return $automationScriptsDir
                }
            }

            $parent = Split-Path $current -Parent
            if ($parent -eq $current -or [string]::IsNullOrEmpty($parent)) { break }
            $current = $parent
        }
    } catch {
        Write-Verbose "Could not use Get-AitherModuleRoot: $_"
    }

    # 4. Final deep search from PWD, excluding _archive
    Write-Verbose "Performing final deep search for automation scripts from PWD..."
    $found = Get-ChildItem -Path $PWD.Path -Filter $marker -Recurse -ErrorAction SilentlyContinue -Depth 5 |
        Where-Object { $_.DirectoryName -notmatch '_archive' -and $_.DirectoryName -notlike '*\_archive\*' } |
        Select-Object -First 1

    if ($found) {
        $scriptsDir = $found.DirectoryName
        # Ensure we're not returning _archive or any subdirectory of it
        if ($scriptsDir -notmatch '_archive') {
            Write-Verbose "Found scripts path via deep search: $scriptsDir"
            return $scriptsDir
        }
    }

    throw "Could not locate 'automation-scripts' directory. Searched for marker file '$marker' but could not find it. Please ensure you are running from within the AitherZero repository or set `$env:AITHERZERO_SCRIPTS_PATH to the full path of the automation-scripts directory."
}
