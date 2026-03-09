#Requires -Version 7.0

<#
.SYNOPSIS
    Get collected metrics by category

.DESCRIPTION
    Retrieves metrics that have been registered for dashboard generation.
    Can return all metrics or metrics for a specific category.

.PARAMETER Category
    Optional category name to retrieve specific metrics

.EXAMPLE
    Get-AitherMetrics
    
    Get all collected metrics

.EXAMPLE
    Get-AitherMetrics -Category 'Tests'
    
    Get metrics for the Tests category

.OUTPUTS
    Hashtable - Metrics data (all categories or specific category)

.NOTES
    Returns empty hashtable if no metrics have been registered or category doesn't exist.

.LINK
    Register-AitherMetrics
    Initialize-AitherDashboard
#>
function Get-AitherMetrics {
[CmdletBinding()]
param(
    [string]$Category
)

begin {
    if (-not $script:CollectedMetrics) {
        $script:CollectedMetrics = @{}
    }
}

process {
    try {
        if ($Category) {
            return $script:CollectedMetrics[$Category]
        }
        return $script:CollectedMetrics
    }
    catch {
        Write-AitherLog -Message "Error retrieving metrics: $($_.Exception.Message)" -Level Error -Source 'Get-AitherMetrics' -Exception $_
        return @{}
    }
}


}

