#Requires -Version 7.0

<#
.SYNOPSIS
    Export metrics to JSON file

.DESCRIPTION
    Generates dashboard JSON for API/programmatic access.
    Exports all collected metrics to a JSON file.

.PARAMETER OutputFile
    Output filename for the JSON file

.PARAMETER Data
    Optional hashtable of additional data to include

.EXAMPLE
    Export-AitherMetrics -OutputFile 'metrics.json'

    Export all metrics to JSON

.OUTPUTS
    Boolean - True if export was successful, False otherwise

.NOTES
    Must call Initialize-AitherDashboard before exporting metrics.
    JSON includes all registered metrics plus any additional data provided.

.LINK
    Initialize-AitherDashboard
    Register-AitherMetrics
    Import-AitherMetrics
#>
function Export-AitherMetrics {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [hashtable]$Data = @{},

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

    # During module validation, skip check
    if ($PSCmdlet.MyInvocation.InvocationName -ne '.') {
        if (-not $script:DashboardConfig) {
            throw "Dashboard session not initialized. Call Initialize-AitherDashboard first."
        }
    }
}

process {
    try {
        try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return $false
        }

        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

        # Merge collected metrics with additional data
        # Ensure $Data is a valid hashtable before cloning
        if (-not $Data) {
            $Data = @{}
        }
        $exportData = $Data.Clone()
        if ($script:CollectedMetrics) {
            foreach ($key in $script:CollectedMetrics.Keys) {
                $exportData[$key] = $script:CollectedMetrics[$key]
            }
        }

        $outputPath = Join-Path $script:DashboardConfig.OutputPath $OutputFile
        $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputPath -Encoding utf8 -Force

        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generated JSON: $outputPath" -Level Information -Source 'Export-AitherMetrics'
        }
        return $true
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Failed to generate JSON: $($_.Exception.Message)" -Level Error -Source 'Export-AitherMetrics' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Failed to generate JSON: $($_.Exception.Message)" -Source 'Export-AitherMetrics' -Exception $_
        }
        return $false
    }
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}


}

