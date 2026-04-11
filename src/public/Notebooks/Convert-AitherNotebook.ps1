#Requires -Version 7.0

<#
.SYNOPSIS
    Converts an Expedition, Playbook, or Workflow into an Agent Notebook.

.DESCRIPTION
    Calls the Genesis POST /notebooks/migrate endpoint to convert legacy
    orchestration formats into the unified Agent Notebook (.anb) format.

    Supports three source types:
    - Expedition: Provide -Id with an expedition ID
    - Playbook:   Provide -Id with a playbook name
    - Workflow:    Provide -Id with a workflow ID

    Alternatively, pass inline data via -SourceData (hashtable).

.PARAMETER From
    Source type to convert from: Expedition, Playbook, or Workflow.

.PARAMETER Id
    ID (or name, for playbooks) of the source object to look up and convert.

.PARAMETER SourceData
    Inline source data as a hashtable (alternative to -Id).

.EXAMPLE
    Convert-AitherNotebook -From Expedition -Id "exp_001"

.EXAMPLE
    Convert-AitherNotebook -From Playbook -Id "deploy-service"

.EXAMPLE
    Convert-AitherNotebook -From Workflow -Id "wf_abc123"

.EXAMPLE
    Convert-AitherNotebook -From Playbook -SourceData @{
        name = "Quick Deploy"
        steps = @(
            @{ action = "shell_command"; command = "docker build ." }
            @{ action = "log"; message = "Done" }
        )
    }

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Convert-AitherNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet("Expedition", "Playbook", "Workflow")]
        [string]$From,

        [Parameter(Position = 1)]
        [string]$Id = "",

        [hashtable]$SourceData = @{}
    )

    if (-not $Id -and $SourceData.Count -eq 0) {
        Write-Warning "Provide either -Id or -SourceData"
        return
    }

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{
        source_type = $From.ToLower()
    }
    if ($Id) {
        $body.source_id = $Id
    }
    if ($SourceData.Count -gt 0) {
        $body.source_data = $SourceData
    }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/migrate" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 30 `
            -ErrorAction Stop

        $nbId = $result.notebook.id
        $nbName = $result.notebook.name
        Write-Host "  Converted $From → Notebook" -ForegroundColor Green
        Write-Host "  ID:   $nbId" -ForegroundColor Cyan
        Write-Host "  Name: $nbName" -ForegroundColor White

        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'notebook-migrated' -Data @{
                source_type = $From.ToLower()
                source_id   = $Id
                notebook_id = $nbId
            }
        }

        return $result
    }
    catch {
        Write-Error "Migration failed: $($_.Exception.Message)"
    }
}
