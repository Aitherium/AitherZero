#Requires -Version 7.0

<#
.SYNOPSIS
    Get current scaling metrics for services.
.DESCRIPTION
    Collects CPU, memory, GPU, latency, and pain metrics from the AutoScale agent,
    Pulse, Watch, and Docker. Returns a structured view of resource utilization.
.PARAMETER Target
    Specific service to get metrics for. If omitted, returns ecosystem-wide metrics.
.PARAMETER Metric
    Filter by specific metric name (cpu_percent, memory_percent, gpu_util, etc.).
.PARAMETER Summary
    Show a compact summary instead of detailed data.
.PARAMETER Raw
    Return raw data objects instead of formatted output.
.EXAMPLE
    Get-AitherScaleMetric
    # Ecosystem-wide metrics overview
.EXAMPLE
    Get-AitherScaleMetric -Target "MicroScheduler" -Metric "cpu_percent"
.EXAMPLE
    Get-AitherScaleMetric -Summary
.NOTES
    Part of AitherZero AutoScale module.
    Copyright © 2025 Aitherium Corporation.
#>
function Get-AitherScaleMetric {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Position = 0)]
        [string]$Target,

        [Parameter()]
        [ValidateSet('cpu_percent', 'memory_percent', 'gpu_util',
                     'request_latency_ms', 'queue_depth', 'error_rate', 'pain_level')]
        [string]$Metric,

        [switch]$Summary,
        [switch]$Raw
    )

    begin {
        $AutoScaleUrl = $env:AITHER_AUTOSCALE_URL
        if (-not $AutoScaleUrl) { $AutoScaleUrl = "http://localhost:8797" }
    }

    process {
        try {
            $uri = "$AutoScaleUrl/metrics"
            if ($Target) { $uri += "/$Target" }

            $response = Invoke-RestMethod -Uri $uri -TimeoutSec 10 -ErrorAction Stop
            $data = if ($response.data) { $response.data } else { $response }

            if ($Raw) { return $data }

            if ($Summary) {
                Write-Host "`n📊 AutoScale Metrics Summary" -ForegroundColor Cyan
                Write-Host "─────────────────────────────" -ForegroundColor DarkGray

                $sources = $data.sources
                if ($sources.pulse) {
                    $p = $sources.pulse
                    Write-Host " 💓 Pulse: Status=$($p.status), Pain=$($p.pain_level)" -ForegroundColor $(
                        if ($p.pain_level -gt 5) { 'Red' } elseif ($p.pain_level -gt 3) { 'Yellow' } else { 'Green' }
                    )
                }
                if ($sources.watch) {
                    $w = $sources.watch
                    Write-Host " 👁️ Watch: Healthy=$($w.services_healthy), Unhealthy=$($w.services_unhealthy)"
                }
                if ($sources.docker) {
                    $d = $sources.docker
                    if ($d.cpu_percent) {
                        $cpuColor = if ($d.cpu_percent -gt 80) { 'Red' } elseif ($d.cpu_percent -gt 50) { 'Yellow' } else { 'Green' }
                        Write-Host " 🐳 Docker: CPU=$($d.cpu_percent)%, Mem=$($d.memory_percent)%" -ForegroundColor $cpuColor
                    }
                }

                return
            }

            # Detailed output
            $results = @()
            if ($data.sources) {
                foreach ($sourceName in $data.sources.PSObject.Properties.Name) {
                    $source = $data.sources.$sourceName
                    foreach ($prop in $source.PSObject.Properties) {
                        if ($Metric -and $prop.Name -ne $Metric) { continue }
                        if ($prop.Value -is [string] -and $prop.Name -eq 'status') { continue }

                        $results += [PSCustomObject]@{
                            Source = $sourceName
                            Metric = $prop.Name
                            Value  = $prop.Value
                            Target = if ($Target) { $Target } else { 'ecosystem' }
                        }
                    }
                }
            }

            if ($results.Count -gt 0) {
                $results | Format-Table Source, Target, Metric, Value -AutoSize
            }

            return $results

        } catch {
            Write-Warning "Could not collect metrics: $_"

            # Fallback: raw Docker stats
            if ($Target) {
                Write-Host "Falling back to Docker stats..." -ForegroundColor DarkGray
                $containerName = "aitheros-$($Target.ToLower())-1"
                try {
                    $stats = docker stats $containerName --no-stream --format "CPU={{.CPUPerc}} MEM={{.MemPerc}}" 2>$null
                    if ($stats) { Write-Host " $stats" }
                } catch {
                    Write-Warning "Docker stats also unavailable"
                }
            }
        }
    }
}
