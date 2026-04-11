#Requires -Version 7.0

<#
.SYNOPSIS
    Requests changes to an Agent Notebook under review.

.DESCRIPTION
    Returns the notebook to the author with specific change requests.
    Each change request describes a modification to apply to cells,
    context, or configuration.

.PARAMETER Id
    The notebook ID to request changes for.

.PARAMETER Reviewer
    Reviewer identifier (agent ID or user ID).

.PARAMETER Comments
    Review comments explaining the requested changes.

.PARAMETER ChangeRequests
    Array of change request hashtables. Each should have:
    - type: MODIFY_CONTEXT, MODIFY_CONFIG, ADD_CELL, REMOVE_CELL, REORDER
    - cell_id: target cell (for MODIFY/REMOVE)
    - description: human-readable description
    - patch: the actual change data

.EXAMPLE
    Request-AitherNotebookChanges -Id "nb_abc" -Reviewer "atlas" -Comments @("Need error handling") -ChangeRequests @(
        @{ type="MODIFY_CONFIG"; cell_id="cell_002"; description="Add retry logic"; patch=@{retries=3} }
    )

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Request-AitherNotebookChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Reviewer,

        [string[]]$Comments = @(),

        [hashtable[]]$ChangeRequests = @()
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{
        reviewer        = $Reviewer
        comments        = $Comments
        change_requests = $ChangeRequests
    }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$Id/review/changes" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 10 `
            -ErrorAction Stop

        Write-Host "  Changes requested for notebook: $Id" -ForegroundColor Yellow
        Write-Host "  Reviewer: $Reviewer" -ForegroundColor DarkGray
        if ($ChangeRequests.Count -gt 0) {
            Write-Host "  $($ChangeRequests.Count) change request(s) filed" -ForegroundColor DarkGray
        }

        return $result
    }
    catch {
        Write-Warning "Failed to request changes for notebook $Id`: $_"
    }
}
