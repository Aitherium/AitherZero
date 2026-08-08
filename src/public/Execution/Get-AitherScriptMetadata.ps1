#Requires -Version 7.0

<#
.SYNOPSIS
    Extract metadata from a script's comment block

.DESCRIPTION
    Parses the header comment block of a script to extract metadata
    like Stage, Dependencies, Description, Category, Tags.

.PARAMETER Path
    Path to the script file. This is a PATH, not a script number — to look a script
    up by number use `Get-AitherScript -Script <number> -Metadata`. A path that does
    not resolve is an error, not an empty result.

.EXAMPLE
    Get-AitherScriptMetadata -Path "./library/automation-scripts/0402_Run-UnitTests.ps1"
    
    Extract metadata from a script file

.EXAMPLE
    Get-AitherScript | ForEach-Object { Get-AitherScriptMetadata -Path $_.Path }
    
    Extract metadata from all scripts

.OUTPUTS
    Hashtable - Metadata key-value pairs with Stage, Dependencies, Description, Category, Tags

.NOTES
    Parses comment-based metadata from script headers.
    Returns default values if metadata not found.

.LINK
    Get-AitherScript
#>
function Get-AitherScriptMetadata {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Path
)

process { try {
        $metadata = @{
            Stage = 'Unknown'
            Dependencies = @()
            Description = ''
            Category = ''
            Tags = @()
        }
        # A path that does not resolve is a CALLER BUG, not "a script with no
        # metadata" — and returning the empty default for both made them
        # indistinguishable. `Get-AitherScriptMetadata 1002` silently produced
        # {Stage='Unknown'; Description=''; Tags=@()} and looked like a script
        # that simply had no header, when in fact nothing was ever read.
        # Fail loudly instead; the defaults below still apply when the file EXISTS
        # but carries no metadata block, which is the documented behaviour.
        if (-not (Test-Path $Path)) {
            if ($Path -match '^\d{4}$') {
                # The single most likely mistake: passing a script NUMBER to a
                # cmdlet that takes a PATH. Point at the cmdlet that does that.
                Write-Error -Message (
                    "Get-AitherScriptMetadata takes a script PATH, not a number. " +
                    "For script $Path use: Get-AitherScript -Script $Path -Metadata"
                ) -Category InvalidArgument -TargetObject $Path
                return
            }
            Write-Error -Message "Script file not found: $Path" `
                -Category ObjectNotFound -TargetObject $Path
            return
        }
        
        $content = Get-Content -Path $Path -Raw
        
        # Extract Stage (metadata is inside comment blocks without # prefix on each line)
        if ($content -match '(?m)^\s*Stage:\s*(.+)$') {
            $metadata.Stage = $matches[1].Trim()
        }
        
        # Extract Dependencies
        if ($content -match '(?m)^\s*Dependencies?:\s*(.+)$') {
            $deps = $matches[1].Trim()
            if ($deps -ne 'None' -and $deps -ne '') {
                $metadata.Dependencies = $deps -split '[,;]' | ForEach-Object { $_.Trim() }
            }
        }
        
        # Extract Description
        if ($content -match '(?m)^\s*Description:\s*(.+)$') {
            $metadata.Description = $matches[1].Trim()
        }
        
        # Extract Category
        if ($content -match '(?m)^\s*Category:\s*(.+)$') {
            $metadata.Category = $matches[1].Trim()
        }
        
        # Extract Tags
        if ($content -match '(?m)^\s*Tags?:\s*(.+)$') {
            $tags = $matches[1].Trim()
            $metadata.Tags = $tags -split '[,;]' | ForEach-Object { $_.Trim() }
        }
        
        return $metadata
    }
    catch {
        # Use fallback logging if Write-AitherLog not available during module load
        if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
            Write-AitherLog -Message "Error extracting script metadata: $($_.Exception.Message)" -Level Warning -Source 'Get-AitherScriptMetadata' -Exception $_
        }
        return @{
            Stage = 'Unknown'
            Dependencies = @()
            Description = ''
            Category = ''
            Tags = @()
        }
    }
}


}

