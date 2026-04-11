#Requires -Version 7.0

<#
.SYNOPSIS
    Get current autoscaling status across all targets.
.DESCRIPTION
    Queries the AitherAutoScale agent (port 8797) for current scaling state including
    active policies, recent actions, provider health, and metric summaries.
    Falls back to direct Docker inspection when the agent is unavailable.
.PARAMETER Target
    Optional service or group name to filter status.
.PARAMETER Provider
    Filter by provider type: docker, hyperv, aws, azure, gcp.
.PARAMETER IncludeMetrics
    Include current metric snapshots in the output.
.PARAMETER Raw
    Return raw JSON instead of formatted objects.
.EXAMPLE
    Get-AitherScaleStatus
    # Shows all scaling status
.EXAMPLE
    Get-AitherScaleStatus -Target "MicroScheduler" -IncludeMetrics
    # Detailed status with metrics for MicroScheduler
.NOTES
    Part of AitherZero AutoScale module.
    Copyright © 2025 Aitherium Corporation.
#>
function Get-AitherScaleStatus {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Position = 0)]
        [string]$Target,

        [Parameter()]
        [ValidateSet('docker', 'hyperv', 'aws', 'azure', 'gcp')]
        [string]$Provider,

        [switch]$IncludeMetrics,
        [switch]$Raw
    )

    begin {
        $AutoScaleUrl = $env:AITHER_AUTOSCALE_URL
        if (-not $AutoScaleUrl) { $AutoScaleUrl = "http://localhost:8797" }
    }

    process {
        try {
            # Query AutoScale agent status
            $uri = "$AutoScaleUrl/status"
            $response = Invoke-RestMethod -Uri $uri -TimeoutSec 5 -ErrorAction Stop

            $data = if ($response.data) { $response.data } else { $response }

            # Build result objects
            $result = [PSCustomObject]@{
                Service          = 'AutoScale'
                Port             = 8797
                Running          = $data.running -eq $true
                Uptime           = if ($data.uptime_seconds) { [TimeSpan]::FromSeconds($data.uptime_seconds) } else { $null }
                PoliciesActive   = $data.policies_active
                TotalEvaluations = $data.total_evaluations
                TotalActions     = $data.total_scale_actions
                CloudProviders   = $data.cloud_providers -join ', '
                RecentActions    = $data.recent_actions
            }

            # Filter by target if specified
            $policies = @()
            if ($data.policies) {
                $policyHash = $data.policies
                foreach ($key in $policyHash.PSObject.Properties.Name) {
                    $p = $policyHash.$key
                    if ($Target -and $p.target -ne $Target) { continue }
                    if ($Provider -and $p.provider -ne $Provider) { continue }
                    $policies += [PSCustomObject]@{
                        PolicyId   = $p.id
                        Name       = $p.name
                        Target     = $p.target
                        Provider   = $p.provider
                        MinReplica = $p.min_replicas
                        MaxReplica = $p.max_replicas
                        Enabled    = $p.enabled
                        Cooldown   = $p.cooldown_seconds
                        Thresholds = ($p.thresholds | ForEach-Object {
                            "$($_.metric): ↑$($_.scale_up) ↓$($_.scale_down)"
                        }) -join '; '
                    }
                }
            }

            # Include metrics if requested
            $metrics = $null
            if ($IncludeMetrics) {
                try {
                    $metricsUri = "$AutoScaleUrl/metrics"
                    if ($Target) { $metricsUri += "/$Target" }
                    $metrics = Invoke-RestMethod -Uri $metricsUri -TimeoutSec 5 -ErrorAction Stop
                } catch {
                    Write-Warning "Could not fetch metrics: $_"
                }
            }

            if ($Raw) {
                return @{
                    Status   = $result
                    Policies = $policies
                    Metrics  = $metrics
                }
            }

            # Formatted output
            Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "║        ⚡ AitherAutoScale Status                        ║" -ForegroundColor Cyan
            Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

            $icon = if ($result.Running) { '🟢' } else { '🔴' }
            Write-Host " $icon Running: $($result.Running)  |  Uptime: $($result.Uptime)" -ForegroundColor White
            Write-Host " 📋 Policies: $($result.PoliciesActive) active  |  Evaluations: $($result.TotalEvaluations)  |  Actions: $($result.TotalActions)"
            Write-Host " ☁️  Providers: $($result.CloudProviders)"
            Write-Host ""

            if ($policies.Count -gt 0) {
                Write-Host " ── Active Policies ──" -ForegroundColor Yellow
                $policies | Format-Table PolicyId, Target, Provider, MinReplica, MaxReplica, Enabled, Thresholds -AutoSize
            }

            if ($result.RecentActions -and $result.RecentActions.Count -gt 0) {
                Write-Host " ── Recent Actions ──" -ForegroundColor Yellow
                $result.RecentActions | ForEach-Object {
                    $dir = if ($_.direction -eq 'up') { '⬆️' } else { '⬇️' }
                    Write-Host "   $dir $($_.target) → $($_.replicas) replicas ($($_.reason)) [$($_.timestamp)]"
                }
            }

            return $result

        } catch {
            # Fallback: inspect Docker directly
            Write-Warning "AutoScale agent not reachable. Falling back to Docker inspection."

            $ctx = Get-AitherLiveContext
            $containers = @()
            try {
                $raw = docker compose -f $ctx.ComposeFile ps --format json 2>$null
                if ($raw) {
                    $containers = $raw | ConvertFrom-Json
                }
            } catch {
                Write-Warning "Docker inspection also failed: $_"
            }

            if ($Target) {
                $containers = $containers | Where-Object { $_.Service -like "*$Target*" }
            }

            return [PSCustomObject]@{
                Service        = 'AutoScale'
                Running        = $false
                FallbackMode   = $true
                ContainerCount = $containers.Count
                Containers     = $containers
            }
        }
    }
}
