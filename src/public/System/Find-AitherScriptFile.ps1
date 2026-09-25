#Requires -Version 7.0

<#
.SYNOPSIS
    Find automation script file by ID

.DESCRIPTION
    Searches for automation script files by script ID (number or name pattern).
    This is a private helper function to eliminate duplication between
    Get-AitherScript and Invoke-AitherScript.

.PARAMETER ScriptId
    Script identifier - can be a number (e.g., '0501') or script name pattern

.PARAMETER ScriptsPath
    Path to the automation-scripts directory

.PARAMETER ThrowOnNotFound
    Throw an error if script is not found (default: return $null)

.NOTES
    This is a private helper function.
#>
function Find-AitherScriptFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ScriptId,

        [Parameter(Mandatory)]
        [string]$ScriptsPath,

        [switch]$ThrowOnNotFound
    )

    if ([string]::IsNullOrWhiteSpace($ScriptId)) {
        if ($ThrowOnNotFound) {
            throw "Script ID cannot be empty"
        }
        return $null
    }

    # Normalize path separators
    $ScriptId = $ScriptId -replace '\\', '/'

    # 1. Handle subdirectory/script format (e.g., "00-bootstrap/0001_Validate-Prerequisites")
    if ($ScriptId -match '/') {
        $parts = $ScriptId -split '/'
        $subDir = $parts[0..($parts.Length - 2)] -join '/'
        $scriptName = $parts[-1]
        $subDirPath = Join-Path $ScriptsPath $subDir
        
        Write-Verbose "Looking for script '$scriptName' in subdirectory '$subDirPath'"
        
        if (Test-Path $subDirPath) {
            # Try exact match with .ps1 extension
            $exactPath = Join-Path $subDirPath "$scriptName.ps1"
            if (Test-Path $exactPath) {
                Write-Verbose "Found exact match: $exactPath"
                return Get-Item $exactPath
            }
            
            # Try pattern match in subdirectory
            $pattern = "*${scriptName}*.ps1"
            $found = Get-ChildItem -Path $subDirPath -Filter $pattern -ErrorAction SilentlyContinue |
                Where-Object { $_.DirectoryName -notmatch '_archive' } |
                Select-Object -First 1
            
            if ($found) {
                Write-Verbose "Found pattern match: $($found.FullName)"
                return $found
            }
        }
    }

    # 2. Try exact filename match in ScriptsPath
    $exactPath = Join-Path $ScriptsPath $ScriptId
    Write-Verbose "Checking exact path: $exactPath"
    if (Test-Path $exactPath) {
        Write-Verbose "Found exact match: $exactPath"
        return Get-Item $exactPath
    }

    # 3. Try exact number match first (Strict Convention: 0000_Name.ps1)
    if ($ScriptId -match '^\d{4}$') {
        $strictPattern = "${ScriptId}_*.ps1"
        Write-Verbose "Trying strict pattern: $strictPattern"
        # Search recursively but exclude _archive
        $strictMatches = @(Get-ChildItem -Path $ScriptsPath -Filter $strictPattern -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -notmatch '_archive' } |
            Sort-Object FullName)
        # A number used by more than one live script is AMBIGUOUS. Picking the first
        # match ran whichever script enumeration order happened to surface -- asking for
        # 3050 meaning the regulated deploy silently ran the GHCR deploy. Refuse and name
        # the candidates so the caller disambiguates with '<category>/<file name>'.
        if ($strictMatches.Count -gt 1) {
            $candidates = $strictMatches | ForEach-Object {
                "$($_.Directory.Name)/$($_.BaseName)"
            }
            throw ("Ambiguous script number '$ScriptId': $($strictMatches.Count) scripts share it " +
                "($($candidates -join ', ')). Pass '<category>/<script name>' instead.")
        }
        if ($strictMatches.Count -eq 1) {
            $found = $strictMatches[0]
            Write-Verbose "Found strict match: $($found.FullName)"
            return $found
        }
    }

    # 4. Try relaxed pattern match - search recursively
    $pattern = if ($ScriptId -match '\.ps1$') {
        # If it ends in .ps1, assume it's a filename or partial filename
        "*$ScriptId"
    }
    else {
        "*${ScriptId}*.ps1"
    }

    # Search recursively, excluding _archive
    $found = Get-ChildItem -Path $ScriptsPath -Filter $pattern -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -notmatch '_archive' } |
        Select-Object -First 1

    # Fallback: Try listing all and filtering in memory (slower but more robust)
    if (-not $found) {
        Write-Verbose "Pattern match failed, trying memory filter recursively..."
        $found = Get-ChildItem -Path $ScriptsPath -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -notmatch '_archive' -and $_.Name -like $pattern } |
            Select-Object -First 1
    }

    # 5. Check Current Working Directory (PWD) explicitly
    if (-not $found) {
        Write-Verbose "Not found in ScriptsPath. Checking PWD: $PWD"

        # Try exact path in PWD
        $pwdExact = Join-Path $PWD $ScriptId
        if (Test-Path $pwdExact) {
            return Get-Item $pwdExact
        }

        # Try pattern in PWD
        $found = Get-ChildItem -Path $PWD -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            Write-Verbose "Found in PWD: $($found.FullName)"
            return $found
        }
    }

    # 6. Plugin script paths fallback. Registered plugins contribute their leaf
    #    category dirs (e.g. plugins/<p>/scripts/30-deploy) to
    #    [AitherPluginState]::ScriptPaths. A ScriptId like '30-deploy/3068_Name'
    #    resolves against the single library root via its subdir; for plugin leaf
    #    dirs we match on the final script-name segment instead.
    if (-not $found) {
        try { $pluginScriptPaths = [AitherPluginState]::ScriptPaths } catch { $pluginScriptPaths = $null }
        if ($pluginScriptPaths) {
            $leafName = ($ScriptId -split '/')[-1]
            $leafPattern = if ($leafName -match '\.ps1$') { "*$leafName" } else { "*${leafName}*.ps1" }
            foreach ($pp in $pluginScriptPaths) {
                if (-not $pp -or -not (Test-Path $pp)) { continue }
                $ppExact = Join-Path $pp "$leafName.ps1"
                if (Test-Path $ppExact) {
                    Write-Verbose "Found in plugin path (exact): $ppExact"
                    return Get-Item $ppExact
                }
                $ppHit = Get-ChildItem -Path $pp -Filter $leafPattern -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.DirectoryName -notmatch '_archive' } |
                    Select-Object -First 1
                if ($ppHit) {
                    Write-Verbose "Found in plugin path (pattern): $($ppHit.FullName)"
                    return $ppHit
                }
            }
        }
    }

    # 7. _archive fallback (plan spec 2.1). Every pass above excludes _archive so a
    #    live script always wins, but playbooks still sequence scripts that were
    #    retired into _archive (0214_Manage-WSL, 0011_Get-SystemInfo, ...). With no
    #    fallback those steps failed 'Script not found' although the file ships.
    #    Resolve them LAST, loudly: a deprecation warning names the archived file so
    #    the playbook gets repointed. A number shared by several archived scripts is
    #    refused exactly like a live collision.
    if (-not $found) {
        $archiveDirs = @(Get-ChildItem -Path $ScriptsPath -Directory -Recurse -Filter '_archive' -ErrorAction SilentlyContinue)
        $leafId = ($ScriptId -split '/')[-1]
        foreach ($archiveDir in $archiveDirs) {
            $archiveHit = $null
            $archiveExact = Join-Path $archiveDir.FullName $(if ($leafId -match '\.ps1$') { $leafId } else { "$leafId.ps1" })
            if (Test-Path $archiveExact) {
                $archiveHit = Get-Item $archiveExact
            }
            elseif ($leafId -match '^\d{4}$') {
                $archiveMatches = @(Get-ChildItem -Path $archiveDir.FullName -Filter "${leafId}_*.ps1" -ErrorAction SilentlyContinue |
                    Sort-Object FullName)
                if ($archiveMatches.Count -gt 1) {
                    throw ("Ambiguous script number '$ScriptId': $($archiveMatches.Count) archived scripts share it " +
                        "($(($archiveMatches | ForEach-Object BaseName) -join ', ')). Pass the full script name instead.")
                }
                if ($archiveMatches.Count -eq 1) { $archiveHit = $archiveMatches[0] }
            }
            else {
                $archivePattern = if ($leafId -match '\.ps1$') { "*$leafId" } else { "*${leafId}*.ps1" }
                $archiveHit = Get-ChildItem -Path $archiveDir.FullName -Filter $archivePattern -ErrorAction SilentlyContinue |
                    Sort-Object FullName | Select-Object -First 1
            }
            if ($archiveHit) {
                Write-Warning ("Script '$ScriptId' resolved from _archive ($($archiveHit.Name)); it is deprecated. " +
                    "Repoint the caller at a live script.")
                return $archiveHit
            }
        }
    }

    Write-Verbose "Find-AitherScriptFile: Searching for '$ScriptId' in '$ScriptsPath'"
    Write-Verbose "Pattern: $pattern"

    if ($found) {
        Write-Verbose "Found: $($found.FullName)"
        return $found
    }
    else {
        Write-Verbose "Not found."
    }

    if ($ThrowOnNotFound) {
        # Get a list of all scripts recursively, excluding _archive
        $allScripts = Get-ChildItem -Path $ScriptsPath -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -notmatch '_archive' } |
            Select-Object -ExpandProperty Name
        $similar = $allScripts | Where-Object { $_ -like "*$ScriptId*" }

        $msg = "Script not found: '$ScriptId'. Searched in '$ScriptsPath' with pattern '$pattern'."
        if ($similar) {
            $msg += " Did you mean: $($similar -join ', ')?"
        }
        else {
            # List the first few scripts to prove we are looking in the right place
            $firstFew = $allScripts | Select-Object -First 10
            $msg += " Directory contains $($allScripts.Count) scripts. First few: $($firstFew -join ', ')"
        }
        throw $msg
    }

    return $null
}


