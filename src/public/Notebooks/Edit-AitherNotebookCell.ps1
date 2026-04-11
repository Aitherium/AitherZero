#Requires -Version 7.0

<#
.SYNOPSIS
    Updates a cell within an Agent Notebook.

.DESCRIPTION
    Modifies the name, config, or dependencies of an existing cell
    within a notebook definition.

.PARAMETER NotebookId
    The notebook ID containing the cell.

.PARAMETER CellId
    The cell ID to update.

.PARAMETER Name
    New display name for the cell.

.PARAMETER Config
    Replacement configuration hashtable.

.PARAMETER DependsOn
    Replacement dependency array.

.EXAMPLE
    Edit-AitherNotebookCell -NotebookId "nb_abc" -CellId "cell_001" -Config @{prompt="Updated prompt"}

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Edit-AitherNotebookCell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$NotebookId,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$CellId,

        [string]$Name,

        [hashtable]$Config,

        [string[]]$DependsOn
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{}
    if ($PSBoundParameters.ContainsKey('Name'))      { $body.name       = $Name }
    if ($PSBoundParameters.ContainsKey('Config'))     { $body.config     = $Config }
    if ($PSBoundParameters.ContainsKey('DependsOn'))  { $body.depends_on = $DependsOn }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$NotebookId/cells/$CellId" `
            -Method PUT `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 10 `
            -ErrorAction Stop

        Write-Host "  Cell updated: $CellId" -ForegroundColor Green
        return $result
    }
    catch {
        Write-Warning "Failed to update cell $CellId in notebook $NotebookId`: $_"
    }
}
