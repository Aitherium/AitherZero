#Requires -Version 7.0

<#
.SYNOPSIS
    Execute unit tests for AitherZero
.DESCRIPTION
    Runs all unit tests using the module's built-in test runner.
.NOTES
    Stage: Testing
    Order: 0402
#>

[CmdletBinding()]
param(
    [string]$ResultsPath = "AitherZero/library/tests/results",
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Initialize AitherZero
. "$PSScriptRoot/../_init.ps1"

if (-not $projectRoot) {
    Write-Error "AitherZero project root not found"
    exit 1
}

# Initialize Dashboard Session (for metrics)
# Set base path to reports directory for metrics storage
Initialize-AitherDashboard -ProjectPath $projectRoot -OutputPath "AitherZero/library/reports"

# Run Tests using the module function
$testResults = Invoke-AitherTests -OutputPath (Join-Path $projectRoot "$ResultsPath/UnitTests-$(Get-Date -Format 'yyyyMMdd-HHmmss').xml") -PassThru

# Process Results for Dashboard
$aggregatedResults = Get-AitherTestResults -TestResultsPath (Join-Path $projectRoot $ResultsPath)
Register-AitherMetrics -Category 'Tests' -Metrics $aggregatedResults

# Export Metrics for Dashboard Generation
# This will be saved to library/reports/metrics/test-metrics.json
Export-AitherMetrics -OutputFile "metrics/test-metrics.json" -ShowOutput

# Return results if requested
if ($PassThru) {
    return $testResults
}
