#Requires -Version 7.0

<#
.SYNOPSIS
    Lists or creates notebook templates.

.DESCRIPTION
    Without parameters, lists all available notebook templates.
    With -Create, creates a new template from an existing notebook.

.PARAMETER Create
    Switch to create a new template instead of listing.

.PARAMETER Name
    Template name (required with -Create).

.PARAMETER Description
    Template description.

.PARAMETER NotebookId
    Source notebook ID to base the template on (with -Create).

.PARAMETER Tags
    Template tags for categorization.

.PARAMETER Tag
    Filter templates by tag (when listing).

.EXAMPLE
    Get-AitherNotebookTemplate

.EXAMPLE
    Get-AitherNotebookTemplate -Create -Name "Deploy Template" -NotebookId "nb_abc123" -Tags @("deployment")

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Get-AitherNotebookTemplate {
    [CmdletBinding()]
    param(
        [switch]$Create,

        [string]$Name = "",

        [string]$Description = "",

        [string]$NotebookId = "",

        [string[]]$Tags = @(),

        [string]$Tag = ""
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    try {
        if ($Create) {
            if (-not $Name) {
                Write-Warning "Template -Name is required when using -Create"
                return
            }
            $body = @{
                name        = $Name
                description = $Description
                notebook_id = $NotebookId
                tags        = $Tags
            }
            $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/templates" `
                -Method POST `
                -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
                -ContentType 'application/json' `
                -TimeoutSec 10 `
                -ErrorAction Stop

            Write-Host "  Template created: $($result.template.id)" -ForegroundColor Green
            return $result
        }

        $qs = if ($Tag) { "?tag=$Tag" } else { "" }
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/templates$qs" `
            -Method GET -TimeoutSec 10 -ErrorAction Stop

        Write-Host "  Found $($result.total) template(s)" -ForegroundColor DarkGray
        $result.templates | ForEach-Object {
            Write-Host "  $($_.id) " -NoNewline -ForegroundColor DarkGray
            Write-Host "$($_.name)" -ForegroundColor White
        }

        return $result
    }
    catch {
        Write-Warning "Failed to manage notebook templates: $_"
    }
}
