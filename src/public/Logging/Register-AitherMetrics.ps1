#Requires -Version 7.0

<#
.SYNOPSIS
    Register metrics data for dashboard inclusion

.DESCRIPTION
    Stores collected metrics for later processing and rendering in dashboard generation.
    Metrics are organized by category for flexible dashboard composition.

.PARAMETER Category
    Category name for the metrics (e.g., 'Tests', 'Build', 'Deployment')

.PARAMETER Metrics
    Hashtable containing the metrics data

.EXAMPLE
    Register-AitherMetrics -Category 'Tests' -Metrics @{ Passed = 10; Failed = 2 }
    
    Register test metrics

.EXAMPLE
    Register-AitherMetrics -Category 'Build' -Metrics @{ Duration = 120; Status = 'Success' }
    
    Register build metrics

.OUTPUTS
    None

.NOTES
    Must call Initialize-AitherDashboard before registering metrics.
    Multiple categories can be registered for a single dashboard session.

.LINK
    Initialize-AitherDashboard
    Get-AitherMetrics
    New-AitherDashboard
#>
function Register-AitherMetrics {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$Category,
    
    [Parameter(Mandatory=$false)]
    [hashtable]$Metrics
)

begin {
    if (-not $script:CollectedMetrics) {
        $script:CollectedMetrics = @{}
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return
        }
        
        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue
        
        $script:CollectedMetrics[$Category] = $Metrics
        
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Registered metrics for category: $Category" -Level Debug -Source 'Register-AitherMetrics'
        }
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error registering metrics: $($_.Exception.Message)" -Level Error -Source 'Register-AitherMetrics' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Error registering metrics: $($_.Exception.Message)" -Source 'Register-AitherMetrics' -Exception $_
        }
        throw
    }
}

}

