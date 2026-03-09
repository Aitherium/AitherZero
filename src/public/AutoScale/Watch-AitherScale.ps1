#Requires -Version 7.0

<#
.SYNOPSIS
    Continuously watch and auto-scale services based on policies.
.DESCRIPTION
    Runs a foreground monitoring loop that collects metrics, evaluates policies,
    and triggers scaling actions. Integrates with the AutoScale agent when available,
    or runs standalone with direct Docker/metrics access.
.PARAMETER Interval
    Evaluation interval in seconds (default: 30).
.PARAMETER Duration
    Maximum duration in minutes before stopping (default: unlimited).
.PARAMETER Quiet
    Suppress per-tick output, only show scale actions.
.EXAMPLE
    Watch-AitherScale
    # Start watching with defaults
.EXAMPLE
    Watch-AitherScale -Interval 15 -Duration 60
    # Watch every 15s for 1 hour
.NOTES
    Part of AitherZero AutoScale module.
    Copyright © 2025 Aitherium Corporation.
    Press Ctrl+C to stop.
#>
function Watch-AitherScale {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$Interval = 30,

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int]$Duration,

        [switch]$Quiet
    )

    begin {
        $AutoScaleUrl = $env:AITHER_AUTOSCALE_URL
        if (-not $AutoScaleUrl) { $AutoScaleUrl = "http://localhost:8797" }

        $startTime = Get-Date
        $endTime = if ($Duration) { $startTime.AddMinutes($Duration) } else { $null }
        $tick = 0
    }

    process {
        Write-Host "`n⚡ AitherAutoScale Watch Mode" -ForegroundColor Cyan
        Write-Host "  Interval: ${Interval}s | Duration: $(if ($Duration) { "${Duration}m" } else { 'unlimited' })" -ForegroundColor DarkGray
        Write-Host "  Press Ctrl+C to stop`n" -ForegroundColor DarkGray

        try {
            while ($true) {
                $tick++
                $now = Get-Date

                # Check duration limit
                if ($endTime -and $now -ge $endTime) {
                    Write-Host "`n⏱️ Duration limit reached. Stopping watch." -ForegroundColor Yellow
                    break
                }

                if (-not $Quiet) {
                    Write-Host "[$($now.ToString('HH:mm:ss'))] Tick #$tick" -ForegroundColor DarkGray -NoNewline
                }

                try {
                    # Query agent status
                    $status = Invoke-RestMethod -Uri "$AutoScaleUrl/status" -TimeoutSec 5 -ErrorAction Stop
                    $data = if ($status.data) { $status.data } else { $status }

                    if (-not $Quiet) {
                        $active = $data.policies_active
                        $evals = $data.total_evaluations
                        $actions = $data.total_scale_actions
                        Write-Host " | Policies: $active | Evals: $evals | Actions: $actions" -ForegroundColor DarkGray
                    }

                    # Check for new scale actions since last tick
                    $recentActions = $data.recent_actions
                    if ($recentActions -and $recentActions.Count -gt 0) {
                        $latest = $recentActions[-1]
                        $latestTime = [datetime]::Parse($latest.timestamp)
                        if ($latestTime -gt $startTime.AddSeconds(-$Interval)) {
                            $dir = if ($latest.direction -eq 'up') { '⬆️' } else { '⬇️' }
                            Write-Host "  $dir SCALE $($latest.direction.ToUpper()): $($latest.target) → $($latest.replicas) replicas" -ForegroundColor $(
                                if ($latest.direction -eq 'up') { 'Yellow' } else { 'Cyan' }
                            )
                            Write-Host "     Reason: $($latest.reason)" -ForegroundColor DarkGray
                        }
                    }

                } catch {
                    if (-not $Quiet) {
                        Write-Host " | ⚠️ Agent unavailable" -ForegroundColor DarkYellow
                    }
                }

                Start-Sleep -Seconds $Interval
            }
        } catch {
            # Ctrl+C or other interrupt
            Write-Host "`n⏹️ Watch stopped after $tick ticks ($([math]::Round(((Get-Date) - $startTime).TotalMinutes, 1))m)" -ForegroundColor Yellow
        }
    }
}
