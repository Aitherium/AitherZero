#Requires -Version 7.0

<#
.SYNOPSIS
    Get logs from AitherOS Docker containers.

.DESCRIPTION
    Retrieves logs from one or more AitherOS containers. Supports tail, follow,
    timestamp display, since/until filtering, and grep-style text search.

.PARAMETER Name
    Service name(s) to get logs from. Required.

.PARAMETER Tail
    Number of lines from the end. Default: 50.

.PARAMETER Follow
    Stream logs in real-time (docker logs -f). Press Ctrl+C to stop.

.PARAMETER Since
    Show logs since a timestamp or relative time. E.g., '10m', '1h', '2025-01-01'.

.PARAMETER Until
    Show logs until a timestamp or relative time.

.PARAMETER Timestamps
    Include timestamps in output.

.PARAMETER Search
    Filter log lines containing this text (case-insensitive grep).

.PARAMETER Level
    Filter by log level: ERROR, WARNING, INFO, DEBUG.

.PARAMETER NoColor
    Disable colored output.

.EXAMPLE
    Get-AitherLog -Name moltbook
    # Shows last 50 lines of moltbook logs

.EXAMPLE
    Get-AitherLog -Name genesis -Follow
    # Streams genesis logs in real-time

.EXAMPLE
    Get-AitherLog -Name llm -Tail 200 -Search 'error'
    # Last 200 lines of LLM logs, filtered for 'error'

.EXAMPLE
    Get-AitherLog -Name moltbook -Since '30m'
    # Moltbook logs from the last 30 minutes

.EXAMPLE
    'genesis', 'pulse', 'chronicle' | Get-AitherLog -Tail 10
    # Last 10 lines from each of 3 services

.NOTES
    Part of the AitherZero Docker management module.
    Copyright © 2025 Aitherium Corporation
#>
function Get-AitherContainerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Service', 'ServiceName')]
        [string[]]$Name,

        [Parameter()]
        [int]$Tail = 50,

        [Parameter()]
        [switch]$Follow,

        [Parameter()]
        [string]$Since,

        [Parameter()]
        [string]$Until,

        [Parameter()]
        [switch]$Timestamps,

        [Parameter()]
        [string]$Search,

        [Parameter()]
        [ValidateSet('ERROR', 'WARNING', 'INFO', 'DEBUG', 'TRACE')]
        [string]$Level,

        [Parameter()]
        [switch]$NoColor
    )

    process {
        foreach ($svc in $Name) {
            $svcClean = $svc.ToLower() -replace '^aitheros-', '' -replace '^aither-', ''
            $containerName = "aitheros-$svcClean"

            # Verify container exists
            $exists = docker ps -a --format '{{.Names}}' --filter "name=$containerName" 2>$null
            if (-not $exists -or $exists -notcontains $containerName) {
                Write-Warning "Container '$containerName' not found. Use Get-AitherContainer to list available containers."
                continue
            }

            # Build docker logs command
            $dockerArgs = @('logs')
            if ($Follow) { $dockerArgs += '-f' }
            if ($Tail -and -not $Follow) { $dockerArgs += @('--tail', $Tail.ToString()) }
            if ($Follow) { $dockerArgs += @('--tail', $Tail.ToString()) }  # Show tail before streaming
            if ($Timestamps) { $dockerArgs += '--timestamps' }
            if ($Since) { $dockerArgs += @('--since', $Since) }
            if ($Until) { $dockerArgs += @('--until', $Until) }
            $dockerArgs += $containerName

            if ($Name.Count -gt 1 -and -not $Follow) {
                Write-Host "`n=== $containerName ===" -ForegroundColor Cyan
            }

            if ($Follow) {
                # Streaming mode — direct passthrough
                if ($Search -or $Level) {
                    $filterPattern = if ($Level) { $Level } else { $Search }
                    Write-Host "Streaming $containerName logs (filter: $filterPattern)..." -ForegroundColor DarkGray
                    & docker @dockerArgs 2>&1 | Where-Object { $_ -match $filterPattern }
                }
                else {
                    & docker @dockerArgs
                }
            }
            else {
                # Batch mode — capture, filter, colorize
                $logLines = & docker @dockerArgs 2>&1

                if ($Level) {
                    $logLines = $logLines | Where-Object { $_ -match "\b$Level\b" }
                }
                if ($Search) {
                    $logLines = $logLines | Where-Object { $_ -match [regex]::Escape($Search) }
                }

                if ($NoColor) {
                    $logLines
                }
                else {
                    foreach ($line in $logLines) {
                        $color = if ($line -match '\bERROR\b|CRITICAL') { 'Red' }
                                 elseif ($line -match '\bWARN') { 'Yellow' }
                                 elseif ($line -match '\bDEBUG\b') { 'DarkGray' }
                                 elseif ($line -match '\bTRACE\b') { 'DarkGray' }
                                 else { 'White' }
                        Write-Host $line -ForegroundColor $color
                    }
                }
            }
        }
    }
}
