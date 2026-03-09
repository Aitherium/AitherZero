#Requires -Version 7.0

<#
.SYNOPSIS
    Finalize dashboard generation session

.DESCRIPTION
    Completes dashboard generation and creates index/summary files.
    Calculates session duration and provides summary statistics.

.PARAMETER GenerateIndex
    Generate a session summary JSON file

.EXAMPLE
    Complete-AitherDashboard -GenerateIndex

    Complete dashboard session and generate summary

.OUTPUTS
    Hashtable - Session summary with start time, end time, duration, and metrics count

.NOTES
    Must call Initialize-AitherDashboard before completing.
    Session summary includes duration and metrics collected count.

.LINK
    Initialize-AitherDashboard
    Register-AitherMetrics
    Export-AitherMetrics
#>
function Complete-AitherDashboard {
[CmdletBinding()]
param(
    [switch]$GenerateIndex,

    [Parameter(HelpMessage = "Show command output in console.")]
    [switch]$ShowOutput
)

begin {
    # Manage logging targets for this execution
    $originalLogTargets = $script:AitherLogTargets
    if ($ShowOutput) {
        if ($script:AitherLogTargets -notcontains 'Console') {
            $script:AitherLogTargets += 'Console'
        }
    }
    else {
        # Ensure Console is NOT in targets if ShowOutput is not specified
        $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
    }

    # During module validation, skip check
    if ($PSCmdlet.MyInvocation.InvocationName -ne '.') {
        if (-not $script:DashboardConfig) {
            throw "Dashboard session not initialized. Call Initialize-AitherDashboard first."
        }
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return @{}
        }

        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

        $sessionEnd = Get-Date
        $duration = $sessionEnd - $script:DashboardConfig.SessionStart

        $summary = @{
            SessionStart = $script:DashboardConfig.SessionStart
            SessionEnd = $sessionEnd
            Duration = $duration.TotalSeconds
            MetricsCollected = if ($script:CollectedMetrics) { $script:CollectedMetrics.Keys.Count }
    else { 0 }
            OutputPath = $script:DashboardConfig.OutputPath
        }
        if ($GenerateIndex) {
            if (Get-Command Export-AitherMetrics -ErrorAction SilentlyContinue) {
                Export-AitherMetrics -OutputFile "dashboard-session.json" -Data $summary
            }
        }

        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Dashboard session completed in $($duration.TotalSeconds) seconds" -Level Information -Source 'Complete-AitherDashboard'
        }

        return $summary
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error completing dashboard session: $($_.Exception.Message)" -Level Error -Source 'Complete-AitherDashboard' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Error completing dashboard session: $($_.Exception.Message)" -Source 'Complete-AitherDashboard' -Exception $_
        }
        throw
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

