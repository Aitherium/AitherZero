#Requires -Version 7.0

<#
.SYNOPSIS
    Aggregate test results from multiple sources

.DESCRIPTION
    Aggregates test results from multiple test result files (NUnit XML, etc.)
    and provides summary statistics for dashboard inclusion.

.PARAMETER TestResultsPath
    Path to directory containing test result files

.EXAMPLE
    Get-AitherTestResults -TestResultsPath ./test-results

    Aggregate test results from test-results directory

.OUTPUTS
    Hashtable - Aggregated test results with TotalTests, PassedTests, FailedTests, etc.

.NOTES
    Currently supports basic file discovery. Full XML parsing can be added as needed.
    Returns summary statistics for dashboard display.

.LINK
    Register-AitherMetrics
    Initialize-AitherDashboard
#>
function Get-AitherTestResults {
[CmdletBinding()]
param(
    [string]$TestResultsPath,

    [switch]$ShowOutput
)

begin {
    # Save original log targets
    $originalLogTargets = $script:AitherLogTargets

    # Set log targets based on ShowOutput parameter
    if ($ShowOutput) {
        # Ensure Console is in the log targets
        if ($script:AitherLogTargets -notcontains 'Console') {
            $script:AitherLogTargets += 'Console'
        }
    }
    else {
        # Remove Console from log targets if present (default behavior)
        if ($script:AitherLogTargets -contains 'Console') {
            $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
        }
    }
}

process { try {
        $aggregated = @{
            TotalTests = 0
            PassedTests = 0
            FailedTests = 0
            SkippedTests = 0
            Duration = 0
            Coverage = 0
            ResultFiles = @()
        }

        if ($TestResultsPath -and (Test-Path $TestResultsPath)) {
            $resultFiles = Get-ChildItem -Path $TestResultsPath -Filter "*.xml" -Recurse -ErrorAction SilentlyContinue

            foreach ($file in $resultFiles) {
                try {
                    [xml]$xml = Get-Content $file.FullName

                    # Handle NUnit XML format (Pester default)
                    if ($xml.'test-results') {
                        $total = [int]$xml.'test-results'.total
                        $failures = [int]$xml.'test-results'.failures
                        $notRun = [int]$xml.'test-results'.'not-run'

                        $aggregated.TotalTests += $total
                        $aggregated.PassedTests += ($total - $failures - $notRun)
                        $aggregated.FailedTests += $failures
                        $aggregated.SkippedTests += $notRun
                    }
                }
                catch {
                    Write-AitherLog -Message "Failed to parse test result file: $($file.Name)" -Level Warning
                }

                $aggregated.ResultFiles += $file.FullName
            }
        }

        return $aggregated
    }
    catch {
        Write-AitherLog -Message "Error aggregating test results: $($_.Exception.Message)" -Level Error -Source 'Get-AitherTestResults' -Exception $_
        return @{
            TotalTests = 0
            PassedTests = 0
            FailedTests = 0
            SkippedTests = 0
            Duration = 0
            Coverage = 0
            ResultFiles = @()
        }
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

