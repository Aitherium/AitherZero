#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves agent soul definitions from AitherOS.

.DESCRIPTION
    Queries the AitherOS soul system to list available souls or get the active
    soul for an agent. Souls define personality overlays that shape agent behavior.

.PARAMETER Name
    Name of a specific soul to retrieve. If omitted, lists all available souls.

.PARAMETER Active
    Show only the currently active soul.

.PARAMETER GenesisUrl
    URL of the Genesis service. Defaults to http://localhost:8001.

.EXAMPLE
    Get-AitherSoul
    # List all available souls

.EXAMPLE
    Get-AitherSoul -Active
    # Show the currently active soul

.EXAMPLE
    Get-AitherSoul -Name "professional"
    # Get details of a specific soul

.NOTES
    Category: AI
    Dependencies: AitherOS Genesis (port 8001)
    Platform: Windows, Linux, macOS
#>
function Get-AitherSoul {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [Parameter()]
        [switch]$Active,

        [Parameter()]
        [string]$GenesisUrl
    )

    if (-not $GenesisUrl) {
        $ctx = Get-AitherLiveContext
        $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }
    }

    try {
        if ($Active) {
            $result = Invoke-RestMethod -Uri "$GenesisUrl/api/soul/active" `
                -Method GET -TimeoutSec 10 -ErrorAction Stop

            Write-Host "`n  Active Soul: $($result.name)" -ForegroundColor Cyan
            if ($result.description) {
                Write-Host "  $($result.description)" -ForegroundColor DarkGray
            }
            return $result
        }
        elseif ($Name) {
            $result = Invoke-RestMethod -Uri "$GenesisUrl/api/soul/$Name" `
                -Method GET -TimeoutSec 10 -ErrorAction Stop
            return $result
        }
        else {
            $result = Invoke-RestMethod -Uri "$GenesisUrl/api/soul/list" `
                -Method GET -TimeoutSec 10 -ErrorAction Stop

            $souls = if ($result.souls) { $result.souls } else { $result }

            Write-Host "`n  Available Souls ($($souls.Count))" -ForegroundColor Cyan
            Write-Host "  $('─' * 40)" -ForegroundColor DarkGray

            foreach ($soul in $souls) {
                $activeMarker = if ($soul.active) { " (active)" } else { "" }
                $nameStr = if ($soul.name) { $soul.name } else { $soul }
                Write-Host "  $nameStr$activeMarker" -ForegroundColor $(if ($soul.active) { 'Green' } else { 'White' })
                if ($soul.description) {
                    Write-Host "    $($soul.description)" -ForegroundColor DarkGray
                }
            }

            return $souls
        }
    }
    catch {
        Write-Warning "Soul query failed: $_"
        Write-Warning "Is Genesis running at $GenesisUrl?"
        return $null
    }
}
