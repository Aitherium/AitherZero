#Requires -Version 7.0

<#
.SYNOPSIS
    Submits an Agent Notebook for review.

.DESCRIPTION
    Transitions a notebook from draft to submitted state, creating a
    review record. The notebook can then be approved, rejected, or
    have changes requested before execution.

.PARAMETER Id
    The notebook ID to submit for review.

.PARAMETER Reviewer
    Optional reviewer identifier (agent ID or user ID).

.EXAMPLE
    Submit-AitherNotebookReview -Id "nb_abc123"

.EXAMPLE
    Submit-AitherNotebookReview -Id "nb_abc123" -Reviewer "atlas"

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Submit-AitherNotebookReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Id,

        [string]$Reviewer = ""
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{
        reviewer = $Reviewer
    }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$Id/review" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 5 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 10 `
            -ErrorAction Stop

        Write-Host "  Notebook submitted for review: $Id" -ForegroundColor Cyan
        if ($Reviewer) {
            Write-Host "  Reviewer: $Reviewer" -ForegroundColor DarkGray
        }

        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'notebook-review-submitted' -Data @{
                notebook_id = $Id
                reviewer    = $Reviewer
            }
        }

        return $result
    }
    catch {
        Write-Warning "Failed to submit notebook $Id for review: $_"
    }
}
