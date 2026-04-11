#Requires -Version 7.0

<#
.SYNOPSIS
    Adds a cell to an existing Agent Notebook.

.DESCRIPTION
    Appends or inserts a new cell into a notebook definition.
    Cells represent individual steps in the notebook workflow.

.PARAMETER NotebookId
    The notebook ID to add the cell to.

.PARAMETER CellType
    The type of cell to add.

.PARAMETER Name
    Display name for the cell.

.PARAMETER Config
    Cell configuration hashtable (type-specific).

.PARAMETER DependsOn
    Array of cell IDs this cell depends on.

.PARAMETER Position
    Optional 0-based position to insert at. Appends if omitted.

.EXAMPLE
    Add-AitherNotebookCell -NotebookId "nb_abc" -CellType "prompt" -Name "Generate plan" -Config @{prompt="Create a deployment plan"}

.EXAMPLE
    Add-AitherNotebookCell -NotebookId "nb_abc" -CellType "checkpoint" -Name "Human review" -Config @{gate_message="Review the plan above"}

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Add-AitherNotebookCell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$NotebookId,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet(
            "context", "plan", "note", "result",
            "tool_call", "prompt", "agent_delegate", "service_call",
            "transform", "parallel_block", "loop", "condition",
            "script", "mcts_branch", "checkpoint"
        )]
        [string]$CellType,

        [Parameter(Position = 2)]
        [string]$Name = "",

        [hashtable]$Config = @{},

        [string[]]$DependsOn = @(),

        [int]$Position = -1
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{
        cell_type  = $CellType
        name       = $Name
        config     = $Config
        depends_on = $DependsOn
    }
    if ($Position -ge 0) {
        $body.position = $Position
    }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$NotebookId/cells" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 10 `
            -ErrorAction Stop

        $cellId = $result.cell.id
        Write-Host "  Cell added: $cellId [$CellType] $Name" -ForegroundColor Green
        return $result
    }
    catch {
        Write-Warning "Failed to add cell to notebook $NotebookId`: $_"
    }
}
