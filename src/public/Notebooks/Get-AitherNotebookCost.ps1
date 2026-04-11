#Requires -Version 7.0

<#
.SYNOPSIS
    Gets the estimated token/cost budget for a notebook's cells.

.DESCRIPTION
    Calls the Genesis estimate-cost endpoint with a set of cell definitions
    and returns per-cell and total cost projections.

.PARAMETER Id
    The notebook ID to estimate costs for. Mutually exclusive with -Cells.

.PARAMETER Cells
    Array of cell hashtables to estimate (for ad-hoc estimation without a saved notebook).

.EXAMPLE
    Get-AitherNotebookCost -Id "nb_abc123"

.EXAMPLE
    Get-AitherNotebookCost -Cells @(@{cell_type="prompt"; config=@{effort=8}}, @{cell_type="agent_delegate"; config=@{agent_id="demiurge"}})

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Get-AitherNotebookCost {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Id = "",

        [hashtable[]]$Cells = @()
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    try {
        if ($Id -and -not $Cells) {
            # Fetch notebook cells first
            $nb = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$Id" `
                -Method GET -TimeoutSec 10 -ErrorAction Stop
            $Cells = $nb.cells
        }

        $body = @{ cells = $Cells }
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/estimate-cost" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 10 `
            -ErrorAction Stop

        Write-Host "  Estimated tokens: $($result.total_tokens)" -ForegroundColor Cyan
        Write-Host "  Estimated cost:   `$$($result.total_cost_usd)" -ForegroundColor Cyan

        return $result
    }
    catch {
        Write-Warning "Failed to estimate notebook cost: $_"
    }
}
