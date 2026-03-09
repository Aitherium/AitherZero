#Requires -Version 7.0

<#
.SYNOPSIS
    Load metrics from JSON file

.DESCRIPTION
    Imports metrics from a JSON file and registers them for dashboard inclusion.
    Useful for aggregating metrics from multiple sources.

.PARAMETER FilePath
    Path to the JSON metrics file

.PARAMETER Category
    Category name to assign to the imported metrics

.EXAMPLE
    Import-AitherMetrics -FilePath './metrics.json' -Category 'Build'
    
    Import metrics from file and register as Build category

.OUTPUTS
    Hashtable - Imported metrics data

.NOTES
    Must call Initialize-AitherDashboard before importing metrics.
    Returns empty hashtable if file not found or invalid.

.LINK
    Initialize-AitherDashboard
    Register-AitherMetrics
    Export-AitherMetrics
#>
function Import-AitherMetrics {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$FilePath,
    
    [Parameter(Mandatory=$false)]
    [string]$Category
)

begin {
    if (-not $script:CollectedMetrics) {
        $script:CollectedMetrics = @{}
    }
}

process {
    try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return @{}
        }
        
        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue
        
        if (-not (Test-Path $FilePath)) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "Metrics file not found: $FilePath" -Level Warning -Source 'Import-AitherMetrics'
            } else {
                Write-AitherLog -Level Warning -Message "Metrics file not found: $FilePath" -Source 'Import-AitherMetrics'
            }
            return @{}
        }
        
        $metrics = Get-Content -Path $FilePath -Raw | ConvertFrom-Json -AsHashtable
        
        if (Get-Command Register-AitherMetrics -ErrorAction SilentlyContinue) {
            Register-AitherMetrics -Category $Category -Metrics $metrics
        }
        else {
            $script:CollectedMetrics[$Category] = $metrics
        }
        
        return $metrics
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Failed to import metrics from $FilePath : $($_.Exception.Message)" -Level Error -Source 'Import-AitherMetrics' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Failed to import metrics from $FilePath : $($_.Exception.Message)" -Source 'Import-AitherMetrics' -Exception $_
        }
        return @{}
    }
}

}

