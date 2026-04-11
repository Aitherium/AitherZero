#Requires -Version 7.0

<#
.SYNOPSIS
    Deletes an Agent Notebook definition from AitherOS.

.DESCRIPTION
    Permanently deletes a notebook and all its associated runs and reviews.
    This operation cannot be undone.

.PARAMETER Id
    The notebook ID to delete.

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    Remove-AitherNotebook -Id "nb_abc123"

.EXAMPLE
    Remove-AitherNotebook -Id "nb_abc123" -Force

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Remove-AitherNotebook {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Id,

        [switch]$Force
    )

    if (-not $Force -and -not $PSCmdlet.ShouldProcess($Id, "Delete notebook")) {
        return
    }

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$Id" `
            -Method DELETE `
            -TimeoutSec 10 `
            -ErrorAction Stop

        Write-Host "  Notebook deleted: $Id" -ForegroundColor Green
        return $result
    }
    catch {
        Write-Warning "Failed to delete notebook $Id`: $_"
    }
}
