#Requires -Version 7.0

<#
.SYNOPSIS
    Approves an Agent Notebook that is under review.

.DESCRIPTION
    Transitions a notebook from submitted to approved state, clearing it
    for execution. Optionally include review comments.

.PARAMETER Id
    The notebook ID to approve.

.PARAMETER Reviewer
    Reviewer identifier (agent ID or user ID).

.PARAMETER Comments
    Optional array of review comments.

.EXAMPLE
    Approve-AitherNotebook -Id "nb_abc123" -Reviewer "david"

.EXAMPLE
    Approve-AitherNotebook -Id "nb_abc123" -Reviewer "atlas" -Comments @("LGTM","Ready to deploy")

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Approve-AitherNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Id,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Reviewer,

        [string[]]$Comments = @()
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{
        reviewer = $Reviewer
        comments = $Comments
    }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$Id/review/approve" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 5 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 10 `
            -ErrorAction Stop

        Write-Host "  Notebook approved: $Id" -ForegroundColor Green
        Write-Host "  Approved by: $Reviewer" -ForegroundColor DarkGray

        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'notebook-approved' -Data @{
                notebook_id = $Id
                reviewer    = $Reviewer
            }
        }

        return $result
    }
    catch {
        Write-Warning "Failed to approve notebook $Id`: $_"
    }
}
