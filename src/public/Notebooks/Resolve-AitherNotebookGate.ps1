#Requires -Version 7.0

<#
.SYNOPSIS
    Resolves a checkpoint/gate cell in a paused notebook run.

.DESCRIPTION
    When a notebook execution encounters a checkpoint cell, the run pauses
    and waits for human/agent approval. This cmdlet resolves that gate,
    either approving or rejecting the continuation.

.PARAMETER RunId
    The paused run ID.

.PARAMETER CellId
    The checkpoint cell ID to resolve.

.PARAMETER Action
    The gate resolution action: approve or reject.

.PARAMETER InputData
    Optional hashtable of data to pass to the gate resolution.

.EXAMPLE
    Resolve-AitherNotebookGate -RunId "run_abc" -CellId "cell_005" -Action "approve"

.EXAMPLE
    Resolve-AitherNotebookGate -RunId "run_abc" -CellId "cell_005" -Action "reject" -InputData @{reason="Budget exceeded"}

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Resolve-AitherNotebookGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$RunId,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$CellId,

        [ValidateSet("approve", "reject")]
        [string]$Action = "approve",

        [hashtable]$InputData = @{}
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{
        action     = $Action
        input_data = $InputData
    }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/runs/$RunId/gate/$CellId" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 15 `
            -ErrorAction Stop

        $color = if ($Action -eq "approve") { "Green" } else { "Red" }
        Write-Host "  Gate resolved: $CellId [$Action]" -ForegroundColor $color

        return $result
    }
    catch {
        Write-Warning "Failed to resolve gate $CellId in run $RunId`: $_"
    }
}
