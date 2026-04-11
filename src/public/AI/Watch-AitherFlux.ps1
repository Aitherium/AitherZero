#Requires -Version 7.0

<#
.SYNOPSIS
    Subscribes to AitherOS Flux event bus for real-time system events.

.DESCRIPTION
    Connects to AitherPulse (port 8081) SSE endpoint and streams system events
    in real-time. Replaces polling-based status checks with event-driven updates.

    Supports filtering by event type and optional scriptblock callbacks for
    event-driven automation.

.PARAMETER EventTypes
    Array of event types to filter. If empty, all events are received.
    Common types: SERVICE_HEALTH, SERVICE_START, SERVICE_STOP, AGENT_COMPLETE,
    SHUTDOWN, BOOT_PHASE, FLUX_EVENT, CONV_EXCHANGE

.PARAMETER Duration
    How long to listen (in seconds). 0 = indefinite. Defaults to 0.

.PARAMETER OnEvent
    ScriptBlock to execute for each received event. Receives the event object
    as $args[0]. If not specified, events are written to the console.

.PARAMETER PulseUrl
    URL of AitherPulse. Defaults to http://localhost:8081.

.PARAMETER Quiet
    Suppress console output (useful when using -OnEvent callback only).

.EXAMPLE
    Watch-AitherFlux -EventTypes SERVICE_HEALTH -Duration 60
    # Watch service health events for 1 minute

.EXAMPLE
    Watch-AitherFlux -OnEvent { param($evt) if ($evt.type -eq 'SERVICE_STOP') { Write-Warning "Service stopped: $($evt.service)" } }
    # Custom callback for service stop events

.EXAMPLE
    Watch-AitherFlux -EventTypes AGENT_COMPLETE, CONV_EXCHANGE -Duration 300 -Quiet
    # Silently capture agent completions for 5 minutes

.NOTES
    Category: AI
    Dependencies: AitherPulse (port 8081)
    Platform: Windows, Linux, macOS
    Exit Codes:
        0 - Completed successfully
        1 - Connection error
#>
function Watch-AitherFlux {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string[]]$EventTypes = @(),

        [Parameter()]
        [int]$Duration = 0,

        [Parameter()]
        [scriptblock]$OnEvent,

        [Parameter()]
        [string]$PulseUrl,

        [Parameter()]
        [switch]$Quiet
    )

    if (-not $PulseUrl) {
        $ctx = Get-AitherLiveContext
        $PulseUrl = if ($ctx.EventBusURL) { $ctx.EventBusURL } else { "http://localhost:8081" }
    }

    # Build SSE endpoint URL
    $sseUrl = "$PulseUrl/events/stream"
    if ($EventTypes.Count -gt 0) {
        $filter = ($EventTypes -join ',')
        $sseUrl += "?types=$filter"
    }

    if (-not $Quiet) {
        Write-Host "`n  Connecting to Flux event bus at $PulseUrl" -ForegroundColor Cyan
        if ($EventTypes.Count -gt 0) {
            Write-Host "  Filtering: $($EventTypes -join ', ')" -ForegroundColor DarkGray
        }
        if ($Duration -gt 0) {
            Write-Host "  Duration: ${Duration}s" -ForegroundColor DarkGray
        }
        Write-Host "  Press Ctrl+C to stop`n" -ForegroundColor DarkGray
    }

    $startTime = [DateTime]::UtcNow
    $eventCount = 0

    try {
        # Use HttpClient for SSE streaming
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromMilliseconds(-1) # Infinite for SSE

        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Get, $sseUrl
        )
        $request.Headers.Add("Accept", "text/event-stream")

        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        $response.EnsureSuccessStatusCode()

        $stream = $response.Content.ReadAsStreamAsync().Result
        $reader = [System.IO.StreamReader]::new($stream)

        $eventBuffer = ""

        while (-not $reader.EndOfStream) {
            # Check duration limit
            if ($Duration -gt 0) {
                $elapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds
                if ($elapsed -ge $Duration) { break }
            }

            $line = $reader.ReadLine()

            if ($null -eq $line) { continue }

            if ($line.StartsWith("data: ")) {
                $eventBuffer = $line.Substring(6)
            }
            elseif ($line -eq "" -and $eventBuffer) {
                # End of SSE event — process it
                try {
                    $evt = $eventBuffer | ConvertFrom-Json
                    $eventCount++

                    if ($OnEvent) {
                        & $OnEvent $evt
                    }

                    if (-not $Quiet) {
                        $ts = if ($evt.timestamp) { $evt.timestamp } else { (Get-Date -Format "HH:mm:ss") }
                        $evtType = if ($evt.type) { $evt.type } else { "EVENT" }
                        $color = switch -Wildcard ($evtType) {
                            '*ERROR*'   { 'Red' }
                            '*STOP*'    { 'Yellow' }
                            '*START*'   { 'Green' }
                            '*HEALTH*'  { 'Cyan' }
                            '*AGENT*'   { 'Magenta' }
                            default     { 'White' }
                        }
                        Write-Host "  [$ts] " -NoNewline -ForegroundColor DarkGray
                        Write-Host "$evtType " -NoNewline -ForegroundColor $color
                        # Show key fields
                        $detail = ($evt.PSObject.Properties | Where-Object { $_.Name -notin @('type', 'timestamp') } |
                            ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
                        if ($detail) {
                            Write-Host $detail -ForegroundColor Gray
                        }
                        else {
                            Write-Host ""
                        }
                    }
                }
                catch {
                    Write-Verbose "Failed to parse SSE event: $_"
                }
                $eventBuffer = ""
            }
        }
    }
    catch [System.AggregateException] {
        if ($_.InnerException -is [System.Threading.Tasks.TaskCanceledException]) {
            # Normal timeout/cancellation
        }
        else {
            Write-Warning "Flux connection failed: $($_.InnerException.Message)"
            Write-Warning "Is AitherPulse running at $PulseUrl?"
        }
    }
    catch {
        Write-Warning "Flux connection failed: $_"
        Write-Warning "Is AitherPulse running at $PulseUrl?"
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Dispose() }

        if (-not $Quiet) {
            Write-Host "`n  Received $eventCount events" -ForegroundColor Cyan
        }
    }
}
