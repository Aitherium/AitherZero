#Requires -Version 7.0

<#
.SYNOPSIS
    Display comprehensive project dashboard with logs, tests, and metrics
.DESCRIPTION
    Wrapper script for Show-AitherDashboard cmdlet.
    Shows an interactive dashboard with project metrics, test results,
    recent logs, module status, and recent activity.
.NOTES
    Stage: Reporting
    Order: 0511
    Tags: reporting, dashboard, monitoring, metrics
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$ShowLogs,
    [switch]$ShowTests,
    [switch]$ShowMetrics,
    [switch]$ShowAll,
    [int]$LogTailLines = 50,
    [switch]$Follow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import AitherZero Module
. "$PSScriptRoot/_init.ps1"

if (-not $projectRoot) {
    Write-Error "AitherZero project root not found"
    exit 1
}

# Call the cmdlet
try {
    $params = @{
        LogTailLines = $LogTailLines
    }

    if ($ShowLogs) { $params.Add('ShowLogs', $true) }
    if ($ShowTests) { $params.Add('ShowTests', $true) }
    if ($ShowMetrics) { $params.Add('ShowMetrics', $true) }
    if ($ShowAll) { $params.Add('ShowAll', $true) }
    if ($Follow) { $params.Add('Follow', $true) }

    Show-AitherDashboard @params
}
catch {
    Write-Error "Failed to show dashboard: $_"
    exit 1
}
