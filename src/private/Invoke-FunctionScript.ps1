#Requires -Version 7.0

<#
.SYNOPSIS
    Load a PowerShell function script file with automatic wrapping support

.DESCRIPTION
    Private helper function that loads a PowerShell function script file into the module session.
    If the script doesn't have a function wrapper, it will automatically wrap the content
    in a function declaration before loading.
    
    This eliminates code duplication in the module loader and ensures consistent
    function loading behavior across all tiers.
    
    IMPORTANT: This helper returns a scriptblock that must be dot-sourced by the caller
    to ensure functions are defined in the module scope, not the helper function's scope.

.PARAMETER Path
    Full path to the function script file (.ps1)

.OUTPUTS
    Returns a scriptblock that the caller must dot-source to define the function

.NOTES
    This is a private helper function used during module initialization.
    It should be loaded before public functions so it's available to the module loader.
    
.EXAMPLE
    $sb = Invoke-FunctionScript -Path $funcPath
    . $sb
#>
function Invoke-FunctionScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    try {
        # Read the file content
        $content = Get-Content -Path $Path -Raw
        
        # Check if it already has a function wrapper
        if ($content -notmatch '^\s*function\s+') {
            # No function wrapper - wrap it
            $functionName = (Get-Item $Path).BaseName
            $wrappedContent = "function $functionName {`n$content`n}"
            
            # Return a scriptblock for the caller to dot-source
            return [scriptblock]::Create($wrappedContent)
        }
        else {
            # Has function wrapper - return scriptblock that sources the file
            return [scriptblock]::Create(". '$Path'")
        }
    }
    catch {
        # Propagate the error for the caller to handle
        throw
    }
}

