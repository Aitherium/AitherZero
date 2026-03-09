#Requires -Version 7.0

<#
.SYNOPSIS
    Extract metadata from a script's comment block

.DESCRIPTION
    Parses the header comment block of a script to extract metadata
    like Stage, Dependencies, Description, Category, Tags.

.PARAMETER Path
    Path to the script file

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
        if (-not (Test-Path $Path)) {
            return $metadata
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

