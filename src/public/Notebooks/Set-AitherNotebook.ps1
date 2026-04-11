#Requires -Version 7.0

<#
.SYNOPSIS
    Updates an existing Agent Notebook definition.

.DESCRIPTION
    Performs a partial update on a notebook definition via PUT to Genesis.
    Only provided parameters are merged; omitted fields are left unchanged.

.PARAMETER Id
    The notebook ID to update.

.PARAMETER Name
    New name for the notebook.

.PARAMETER Description
    New description.

.PARAMETER Tags
    Replacement tag array.

.PARAMETER Spec
    Updated spec hashtable.

.PARAMETER Metadata
    Updated metadata hashtable.

.EXAMPLE
    Set-AitherNotebook -Id "nb_abc123" -Name "Deploy v2.2" -Tags @("release","hotfix")

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Set-AitherNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Id,

        [string]$Name,

        [string]$Description,

        [string[]]$Tags,

        [hashtable]$Spec,

        [hashtable]$Metadata
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{}
    if ($PSBoundParameters.ContainsKey('Name'))        { $body.name        = $Name }
    if ($PSBoundParameters.ContainsKey('Description'))  { $body.description = $Description }
    if ($PSBoundParameters.ContainsKey('Tags'))         { $body.tags        = $Tags }
    if ($PSBoundParameters.ContainsKey('Spec'))         { $body.spec        = $Spec }
    if ($PSBoundParameters.ContainsKey('Metadata'))     { $body.metadata    = $Metadata }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$Id" `
            -Method PUT `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 15 `
            -ErrorAction Stop

        Write-Host "  Notebook updated: $Id" -ForegroundColor Green
        return $result
    }
    catch {
        Write-Warning "Failed to update notebook $Id`: $_"
        Write-Host "  Is Genesis running? Check with: Get-AitherStatus" -ForegroundColor Yellow
    }
}
