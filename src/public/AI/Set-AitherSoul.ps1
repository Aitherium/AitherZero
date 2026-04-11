#Requires -Version 7.0

<#
.SYNOPSIS
    Activates a soul overlay on AitherOS agents.

.DESCRIPTION
    Loads a soul definition into the AitherOS soul system, changing the active
    personality overlay for agent interactions. Souls modify behavior between
    the IDENTITY and RULES layers of the context pipeline.

.PARAMETER Name
    Name of the soul to activate.

.PARAMETER GenesisUrl
    URL of the Genesis service. Defaults to http://localhost:8001.

.EXAMPLE
    Set-AitherSoul -Name "professional"
    # Switch to the professional soul

.EXAMPLE
    Set-AitherSoul -Name "creative"
    # Switch to the creative soul

.NOTES
    Category: AI
    Dependencies: AitherOS Genesis (port 8001)
    Platform: Windows, Linux, macOS
#>
function Set-AitherSoul {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter()]
        [string]$GenesisUrl
    )

    if (-not $GenesisUrl) {
        $ctx = Get-AitherLiveContext
        $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }
    }

    if (-not $PSCmdlet.ShouldProcess("AitherOS Soul System", "Activate soul '$Name'")) {
        return
    }

    try {
        $body = @{ name = $Name } | ConvertTo-Json -Compress
        $result = Invoke-RestMethod -Uri "$GenesisUrl/api/soul/load" `
            -Method POST -Body $body -ContentType 'application/json' `
            -TimeoutSec 10 -ErrorAction Stop

        Write-Host "`n  Soul '$Name' activated" -ForegroundColor Green
        if ($result.description) {
            Write-Host "  $($result.description)" -ForegroundColor DarkGray
        }

        # Report to Strata
        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'soul-change' -Data @{
                soul = $Name
                previous = $result.previous_soul
            }
        }

        return $result
    }
    catch {
        Write-Warning "Failed to activate soul '$Name': $_"
        Write-Warning "Is Genesis running at $GenesisUrl?"
        return $null
    }
}
