#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves Agent Notebook definitions from AitherOS.

.DESCRIPTION
    Gets one or more notebook definitions from Genesis. Without parameters,
    lists all notebooks. With -Id, retrieves a specific notebook's full
    definition including cells.

.PARAMETER Id
    Optional notebook ID to retrieve a specific notebook.

.PARAMETER Status
    Filter notebooks by status (draft, submitted, approved, active, completed, failed).

.PARAMETER Tag
    Filter notebooks by tag.

.PARAMETER CreatedBy
    Filter notebooks by creator agent/user ID.

.PARAMETER Limit
    Maximum number of results (default 100).

.EXAMPLE
    Get-AitherNotebook

.EXAMPLE
    Get-AitherNotebook -Id "nb_abc123"

.EXAMPLE
    Get-AitherNotebook -Status "approved" -Tag "deployment"

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Get-AitherNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Id = "",

        [ValidateSet("draft", "submitted", "approved", "active", "completed", "failed", "paused", "")]
        [string]$Status = "",

        [string]$Tag = "",

        [string]$CreatedBy = "",

        [int]$Limit = 100
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    try {
        if ($Id) {
            $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$Id" `
                -Method GET -TimeoutSec 10 -ErrorAction Stop
            return $result
        }

        $query = @()
        if ($Status) { $query += "status=$Status" }
        if ($Tag) { $query += "tag=$Tag" }
        if ($CreatedBy) { $query += "created_by=$CreatedBy" }
        if ($Limit -ne 100) { $query += "limit=$Limit" }
        $qs = if ($query.Count -gt 0) { "?" + ($query -join "&") } else { "" }

        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks$qs" `
            -Method GET -TimeoutSec 10 -ErrorAction Stop

        $notebooks = $result.notebooks
        Write-Host "  Found $($result.total) notebook(s)" -ForegroundColor DarkGray

        if ($notebooks.Count -gt 0) {
            $notebooks | ForEach-Object {
                $st = $_.status
                $color = switch ($st) {
                    "approved" { "Green" }
                    "active"   { "Cyan" }
                    "failed"   { "Red" }
                    "paused"   { "Yellow" }
                    default    { "White" }
                }
                Write-Host "  $($_.id) " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($_.name) " -NoNewline -ForegroundColor White
                Write-Host "[$st]" -ForegroundColor $color
            }
        }

        return $result
    }
    catch {
        Write-Warning "Failed to retrieve notebooks: $_"
        Write-Host "  Is Genesis running? Check with: Get-AitherStatus" -ForegroundColor Yellow
    }
}
