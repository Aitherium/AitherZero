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
        $found = Get-ChildItem -Path $ScriptsPath -Filter $strictPattern -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -notmatch '_archive' } |
            Select-Object -First 1
        if ($found) {
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


