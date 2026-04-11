#Requires -Version 7.0

<#
.SYNOPSIS
    Gets the status and output of a notebook run.

.DESCRIPTION
    Retrieves run details including per-cell status, outputs, cost/token
    totals, and timing information. Optionally retrieves output for a
    specific cell within the run.

.PARAMETER RunId
    The run ID to query.

.PARAMETER CellId
    Optional cell ID to retrieve output for a specific cell.

.EXAMPLE
    Get-AitherNotebookRun -RunId "run_abc123"

.EXAMPLE
    Get-AitherNotebookRun -RunId "run_abc123" -CellId "cell_001"

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Get-AitherNotebookRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$RunId,

        [string]$CellId = ""
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    try {
        if ($CellId) {
            $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/runs/$RunId/cells/$CellId/output" `
                -Method GET -TimeoutSec 10 -ErrorAction Stop
        }
        else {
            $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/runs/$RunId" `
                -Method GET -TimeoutSec 10 -ErrorAction Stop
        }

        $status = $result.status
        $color = switch ($status) {
            "completed" { "Green" }
            "failed"    { "Red" }
            "running"   { "Cyan" }
            "paused"    { "Yellow" }
            default     { "White" }
        }

        if (-not $CellId) {
            Write-Host "  Run: $RunId" -ForegroundColor DarkGray
            Write-Host "  Status: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$status" -ForegroundColor $color
            if ($result.total_cost) {
                Write-Host "  Cost: `$$($result.total_cost) | Tokens: $($result.total_tokens)" -ForegroundColor DarkGray
            }
        }

        return $result
    }
    catch {
        Write-Warning "Failed to get run $RunId`: $_"
    }
}
