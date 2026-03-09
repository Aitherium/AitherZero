#Requires -Version 7.0

<#
.SYNOPSIS
    Compare two configuration files or sections

.DESCRIPTION
    Shows differences between two configurations, highlighting added, removed, and changed values.

.PARAMETER Config1
    First configuration file or section name

.PARAMETER Config2
    Second configuration file or section name

.PARAMETER Section
    Compare only specific section

.PARAMETER ShowEqual
    Show values that are the same

.PARAMETER Export
    Export diff to file

.EXAMPLE
    Compare-AitherConfig -Config1 'config.psd1' -Config2 'config.local.psd1'

.EXAMPLE
    Compare-AitherConfig -Config1 'config.psd1' -Config2 'config.production.psd1' -Section Automation

.NOTES
    Useful for comparing environments or tracking configuration changes.
#>
function Compare-AitherConfig {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$Config1,

    [Parameter(Mandatory=$false)]
    [string]$Config2,

    [Parameter()]
    [string]$Section,

    [Parameter()]
    [switch]$ShowEqual,

    [Parameter()]
    [string]$Export
)

begin {
    $moduleRoot = Get-AitherModuleRoot
    
    function Get-ConfigFromPath {
        param([string]$Path)
        
        if (Test-Path $Path) {
            $content = Get-Content -Path $Path -Raw
            $scriptBlock = [scriptblock]::Create($content)
            return & $scriptBlock
        }
    elseif ($Path -match '^config\.') {
            # Try as config file name
            $fullPath = Join-Path $moduleRoot $Path
            if (Test-Path $fullPath) {
                $content = Get-Content -Path $fullPath -Raw
                $scriptBlock = [scriptblock]::Create($content)
                return & $scriptBlock
            }
        }
    else {
            # Try as section name
            return Get-AitherConfigs -Section $Path
        }
        
        throw "Could not load configuration: $Path"
    }

    function Compare-Hashtables {
        param(
            [hashtable]$Left,
            [hashtable]$Right,
            [string]$Path = ''
        )

        $differences = @()

        # Get all keys
        $allKeys = ($Left.Keys + $Right.Keys) | Select-Object -Unique

        foreach ($key in $allKeys) {
            $currentPath = if ($Path) { "$Path.$key" }
    else { $key }
            $leftValue = $Left[$key]
            $rightValue = $Right[$key]

            # Key only in left
            if ($Left.ContainsKey($key) -and -not $Right.ContainsKey($key)) {
                $differences += [PSCustomObject]@{
                    Path = $currentPath
                    Type = 'Removed'
                    Left = $leftValue
                    Right = $null
                }
            }
            # Key only in right
            elseif (-not $Left.ContainsKey($key) -and $Right.ContainsKey($key)) {
                $differences += [PSCustomObject]@{
                    Path = $currentPath
                    Type = 'Added'
                    Left = $null
                    Right = $rightValue
                }
            }
            # Both have key - compare values
            else {
                if ($leftValue -is [hashtable] -and $rightValue -is [hashtable]) {
                    $differences += Compare-Hashtables -Left $leftValue -Right $rightValue -Path $currentPath
                }
    elseif ($leftValue -ne $rightValue) {
                    $differences += [PSCustomObject]@{
                        Path = $currentPath
                        Type = 'Changed'
                        Left = $leftValue
                        Right = $rightValue
                    }
                }
    elseif ($ShowEqual) {
                    $differences += [PSCustomObject]@{
                        Path = $currentPath
                        Type = 'Equal'
                        Left = $leftValue
                        Right = $rightValue
                    }
                }
            }
        }

        return $differences
    }
}

process {
    # Don't execute if parameters not provided (during module loading)
    if (-not $Config1 -or -not $Config2) {
        return
    }
    
    try {
        # Load configurations
        $config1Obj = Get-ConfigFromPath -Path $Config1
        $config2Obj = Get-ConfigFromPath -Path $Config2

        # Filter by section if specified
        if ($Section) {
            if ($config1Obj.ContainsKey($Section)) {
                $config1Obj = $config1Obj[$Section]
            }
    else {
                throw "Section '$Section' not found in Config1"
            }
        if ($config2Obj.ContainsKey($Section)) {
                $config2Obj = $config2Obj[$Section]
            }
    else {
                throw "Section '$Section' not found in Config2"
            }
        }

        # Compare
        $differences = Compare-Hashtables -Left $config1Obj -Right $config2Obj

        # Display results
        Write-AitherLog -Level Information -Message "=== Configuration Comparison ===" -Source 'Compare-AitherConfig'
        Write-AitherLog -Level Information -Message "Config1: $Config1" -Source 'Compare-AitherConfig'
        Write-AitherLog -Level Information -Message "Config2: $Config2" -Source 'Compare-AitherConfig'

        if ($differences.Count -eq 0) {
            Write-AitherLog -Level Information -Message "No differences found." -Source 'Compare-AitherConfig'
        }
    else {
            $added = ($differences | Where-Object { $_.Type -eq 'Added' }).Count
            $removed = ($differences | Where-Object { $_.Type -eq 'Removed' }).Count
            $changed = ($differences | Where-Object { $_.Type -eq 'Changed' }).Count

            Write-AitherLog -Level Information -Message "Summary:" -Source 'Compare-AitherConfig'
            Write-AitherLog -Level Information -Message "  Added: $added" -Source 'Compare-AitherConfig'
            Write-AitherLog -Level Information -Message "  Removed: $removed" -Source 'Compare-AitherConfig'
            Write-AitherLog -Level Information -Message "  Changed: $changed" -Source 'Compare-AitherConfig'

            # Show differences
            foreach ($diff in $differences) {
                $level = switch ($diff.Type) {
                    'Added' { 'Information' }
                    'Removed' { 'Warning' }
                    'Changed' { 'Warning' }
                    'Equal' { 'Information' }
                    default { 'Information' }
                }

                Write-AitherLog -Level $level -Message "[$($diff.Type)] $($diff.Path)" -Source 'Compare-AitherConfig'
                if ($diff.Type -eq 'Changed') {
                    Write-AitherLog -Level Warning -Message "  -: $($diff.Left)" -Source 'Compare-AitherConfig'
                    Write-AitherLog -Level Information -Message "  +: $($diff.Right)" -Source 'Compare-AitherConfig'
                }
    elseif ($diff.Type -eq 'Added') {
                    Write-AitherLog -Level Information -Message "  +: $($diff.Right)" -Source 'Compare-AitherConfig'
                }
    elseif ($diff.Type -eq 'Removed') {
                    Write-AitherLog -Level Warning -Message "  -: $($diff.Left)" -Source 'Compare-AitherConfig'
                }
            }
        }

        # Export if requested
        if ($Export) {
            $differences | ConvertTo-Json -Depth 10 | Set-Content -Path $Export
            Write-AitherLog -Level Information -Message "Differences exported to: $Export" -Source 'Compare-AitherConfig'
        }
        
        return $differences
    }
    catch {
        Write-AitherLog -Level Error -Message "Failed to compare configurations: $_" -Source 'Compare-AitherConfig' -Exception $_
        throw
    }
}


}

