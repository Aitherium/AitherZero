#Requires -Version 7.0

<#
.SYNOPSIS
    Posts structured telemetry events to AitherOS Strata ingestion service.

.DESCRIPTION
    Sends structured JSON telemetry to the Strata ingestion endpoint (port 8136).
    This bridges AitherZero automation events into the central AitherOS observability
    pipeline for audit trails, ML training loops, and dashboard visibility.

    Events are fire-and-forget by default (non-blocking). Use -Wait to block until
    the event is acknowledged.

.PARAMETER EventType
    The type of event being reported. Common types:
    - script-execution: Automation script completed
    - playbook-run: Playbook orchestration completed
    - deployment: Deployment operation
    - health-check: Service health probe result
    - agent-invocation: Agent dispatch from CLI

.PARAMETER Data
    Hashtable of structured event data. Will be serialized to JSON.

.PARAMETER Source
    Source identifier (e.g., script name, function name). Defaults to caller name.

.PARAMETER StrataUrl
    URL of the Strata service. Defaults to http://localhost:8136.

.PARAMETER Wait
    Block until the event is acknowledged by Strata.

.PARAMETER Timeout
    Timeout in seconds for the HTTP request. Defaults to 5.

.EXAMPLE
    Send-AitherStrata -EventType 'script-execution' -Data @{
        script = '0000_Bootstrap-AitherOS.ps1'
        duration_ms = 45000
        outcome = 'success'
        exit_code = 0
    }

.EXAMPLE
    Send-AitherStrata -EventType 'agent-invocation' -Data @{
        agent = 'demiurge'
        prompt = 'Refactor auth module'
        effort = 5
        duration_ms = 12000
    } -Wait

.NOTES
    Category: Telemetry
    Dependencies: AitherOS Strata service (port 8136)
    Platform: Windows, Linux, macOS
#>
function Send-AitherStrata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$EventType,

        [Parameter(Mandatory, Position = 1)]
        [hashtable]$Data,

        [Parameter()]
        [string]$Source,

        [Parameter()]
        [string]$StrataUrl,

        [Parameter()]
        [switch]$Wait,

        [Parameter()]
        [int]$Timeout = 5
    )

    if (-not $Source) {
        $Source = (Get-PSCallStack)[1].Command
        if (-not $Source -or $Source -eq '<ScriptBlock>') { $Source = 'AitherZero' }
    }

    if (-not $StrataUrl) {
        $ctx = Get-AitherLiveContext
        $StrataUrl = if ($ctx.TelemetryURL) { $ctx.TelemetryURL } else { "http://localhost:8136" }
    }

    $payload = @{
        event_type = $EventType
        source     = "aitherzero/$Source"
        timestamp  = (Get-Date).ToUniversalTime().ToString("o")
        hostname   = $env:COMPUTERNAME
        data       = $Data
    }

    $json = $payload | ConvertTo-Json -Depth 10 -Compress
    $uri = "$StrataUrl/api/v1/ingest/automation-event"

    $sendBlock = {
        param($uri, $json, $Timeout)
        try {
            $null = Invoke-RestMethod -Uri $uri -Method POST -Body $json `
                -ContentType 'application/json' -TimeoutSec $Timeout -ErrorAction Stop
        }
        catch {
            # Fire-and-forget: log but don't fail the caller
            Write-Verbose "Strata ingestion failed: $_"
        }
    }

    if ($Wait) {
        & $sendBlock $uri $json $Timeout
    }
    else {
        # Non-blocking: run in a background job
        $null = Start-ThreadJob -ScriptBlock $sendBlock -ArgumentList $uri, $json, $Timeout -ErrorAction SilentlyContinue
        if (-not $?) {
            # ThreadJob not available, fall back to synchronous
            & $sendBlock $uri $json $Timeout
        }
    }
}
