<#
.SYNOPSIS
    Lists all available agents via the backend service.

.DESCRIPTION
    Queries the orchestrator to list all available agents.

.EXAMPLE
    Get-AitherAgents
#>
function Get-AitherAgents {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$OrchestratorUrl
    )

    if (-not $OrchestratorUrl) {
        $agentCtx = Get-AitherLiveContext
        $OrchestratorUrl = if ($agentCtx.OrchestratorURL) { $agentCtx.OrchestratorURL } else { "http://localhost:8001" }
    }

    try {
        $response = Invoke-RestMethod -Uri "$OrchestratorUrl/agents" -Method GET -TimeoutSec 5
        return $response
    } catch {
        Write-Warning "Cannot connect to orchestrator at $OrchestratorUrl"
        Write-Warning "Error: $_"
        return @()
    }
}

# Export handled by build.ps1
