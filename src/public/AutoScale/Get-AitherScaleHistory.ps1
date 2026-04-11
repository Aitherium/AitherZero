#Requires -Version 7.0

<#
.SYNOPSIS
    Get scaling action history.
.DESCRIPTION
    Retrieves the history of scaling actions from the AutoScale agent, including
    timestamps, targets, directions, providers, reasons, and blast radius data.
.PARAMETER Target
    Filter history to a specific service or group.
.PARAMETER Direction
    Filter by 'Up' or 'Down' actions.
.PARAMETER Limit
    Maximum number of history entries to return (default: 50).
.PARAMETER Since
    Only show actions after this datetime.
.PARAMETER Raw
    Return raw data instead of formatted output.
.EXAMPLE
    Get-AitherScaleHistory
.EXAMPLE
    Get-AitherScaleHistory -Target "MicroScheduler" -Direction Up -Limit 10
.EXAMPLE
    Get-AitherScaleHistory -Since (Get-Date).AddHours(-1)
.NOTES
    Part of AitherZero AutoScale module.
    Copyright © 2025 Aitherium Corporation.
#>
function Get-AitherScaleHistory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Position = 0)]
        [string]$Target,

        [Parameter()]
        [ValidateSet('Up', 'Down')]
        [string]$Direction,

        [Parameter()]
        [ValidateRange(1, 500)]
        [int]$Limit = 50,

        [Parameter()]
        [datetime]$Since,

        [switch]$Raw
    )

    begin {
        $AutoScaleUrl = $env:AITHER_AUTOSCALE_URL
        if (-not $AutoScaleUrl) { $AutoScaleUrl = "http://localhost:8797" }
    }

    process {
        try {
            $queryParams = @("limit=$Limit")
            if ($Target) { $queryParams += "target=$Target" }
            if ($Direction) { $queryParams += "direction=$($Direction.ToLower())" }

            $uri = "$AutoScaleUrl/history?$($queryParams -join '&')"
            $response = Invoke-RestMethod -Uri $uri -TimeoutSec 10 -ErrorAction Stop
            $data = if ($response.data) { $response.data } else { $response }

            if ($Raw) { return $data }

            # Filter by Since if specified
            if ($Since) {
                $data = $data | Where-Object {
                    [datetime]::Parse($_.timestamp) -ge $Since
                }
            }

            if ($data.Count -eq 0) {
                Write-Host "📋 No scaling history found." -ForegroundColor DarkGray
                return @()
            }

            Write-Host "`n📋 AutoScale History ($($data.Count) entries)" -ForegroundColor Cyan
            Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray

            $results = @()
            foreach ($entry in $data) {
                $dir = if ($entry.direction -eq 'up') { '⬆️' } else { '⬇️' }
                $results += [PSCustomObject]@{
                    Timestamp = $entry.timestamp
                    Direction = "$dir $($entry.direction)"
                    Target    = $entry.target
                    Replicas  = $entry.replicas
                    Provider  = $entry.provider
                    Reason    = $entry.reason
                }
            }

            $results | Format-Table Timestamp, Direction, Target, Replicas, Provider, Reason -AutoSize

            return $results

        } catch {
            Write-Warning "Could not retrieve scale history: $_"
            return @()
        }
    }
}
