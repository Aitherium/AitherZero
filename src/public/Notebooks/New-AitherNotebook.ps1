#Requires -Version 7.0

<#
.SYNOPSIS
    Creates a new Agent Notebook definition in AitherOS.

.DESCRIPTION
    Creates a new Agent Notebook (.anb) definition via the Genesis /notebooks API.
    Notebooks are structured task plans containing cells that agents can execute,
    review, and iterate on. This is the primary entry point for CLI-driven
    notebook creation.

.PARAMETER Name
    Name of the notebook.

.PARAMETER Description
    Optional description of the notebook purpose.

.PARAMETER Tags
    Optional tags for categorization.

.PARAMETER Cells
    Optional array of cell hashtables to seed the notebook with.
    Each cell should have: cell_type, name, config.

.PARAMETER Spec
    Optional spec hashtable with execution_mode, effort_budget, etc.

.PARAMETER Metadata
    Optional metadata hashtable for custom key-value pairs.

.PARAMETER Template
    Optional template ID to create the notebook from.

.EXAMPLE
    New-AitherNotebook -Name "Deploy v2.1" -Description "Production deployment plan"

.EXAMPLE
    New-AitherNotebook -Name "Code Review" -Tags @("review","sprint-14") -Spec @{execution_mode="sequential"}

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function New-AitherNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string]$Description = "",

        [string[]]$Tags = @(),

        [hashtable[]]$Cells = @(),

        [hashtable]$Spec = @{},

        [hashtable]$Metadata = @{},

        [string]$Template = ""
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{
        name        = $Name
        description = $Description
        tags        = $Tags
        cells       = $Cells
        spec        = $Spec
        metadata    = $Metadata
    }

    if ($Template) {
        $body.template_id = $Template
    }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 15 `
            -ErrorAction Stop

        $nbId = $result.notebook.id
        Write-Host "  Notebook created: " -NoNewline -ForegroundColor DarkGray
        Write-Host "$nbId" -ForegroundColor Green
        Write-Host "  Name: $Name" -ForegroundColor Cyan

        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'notebook-created' -Data @{
                notebook_id = $nbId
                name        = $Name
                tags        = $Tags
            }
        }

        return $result
    }
    catch {
        Write-Warning "Failed to create notebook: $_"
        Write-Host "  Is Genesis running? Check with: Get-AitherStatus" -ForegroundColor Yellow
    }
}
