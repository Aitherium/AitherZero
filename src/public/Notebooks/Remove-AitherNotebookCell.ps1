#Requires -Version 7.0

<#
.SYNOPSIS
    Removes a cell from an Agent Notebook.

.DESCRIPTION
    Deletes a cell from a notebook definition by cell ID.
    Dependent cells will have their dependency references cleaned up.

.PARAMETER NotebookId
    The notebook ID containing the cell.

.PARAMETER CellId
    The cell ID to remove.

.EXAMPLE
    Remove-AitherNotebookCell -NotebookId "nb_abc" -CellId "cell_003"

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Remove-AitherNotebookCell {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$NotebookId,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$CellId
    )

    if (-not $PSCmdlet.ShouldProcess("$CellId in $NotebookId", "Remove cell")) {
        return
    }

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$NotebookId/cells/$CellId" `
            -Method DELETE `
            -TimeoutSec 10 `
            -ErrorAction Stop

        Write-Host "  Cell removed: $CellId" -ForegroundColor Green
        return $result
    }
    catch {
        Write-Warning "Failed to remove cell $CellId from notebook $NotebookId`: $_"
    }
}
