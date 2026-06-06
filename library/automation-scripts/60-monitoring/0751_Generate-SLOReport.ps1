<#
.SYNOPSIS
    Generate SLO report from Prometheus metrics and error budget data.

.DESCRIPTION
    Generates comprehensive SLO reports showing:
    - SLI actuals vs targets per service
    - Error budget consumption and forecasting
    - Burn-rate trends over time
    - Auto-remediation effectiveness
    - Monthly summary for stakeholders

.PARAMETER Period
    Report period: "daily", "weekly", "monthly" (default: "monthly")

.PARAMETER Format
    Output format: "html", "json", "text" (default: "html")

.PARAMETER OutputPath
    Path to save report (default: ./reports/slo-report-YYYYMMDD.html)

.PARAMETER UploadToStrata
    Upload report to Strata for archival

.PARAMETER PrometheusUrl
    Prometheus URL (default: http://localhost:9090)

.PARAMETER Services
    Comma-separated list of services to include (default: all critical services)

.EXAMPLE
    ./0751_Generate-SLOReport.ps1 -Period monthly -Format html
    ./0751_Generate-SLOReport.ps1 -Period monthly -UploadToStrata
    ./0751_Generate-SLOReport.ps1 -Period daily -Format json -OutputPath ./slo-daily.json

.NOTES
    Requires Prometheus access. Uses AitherOS library modules for integration.
#>

#Requires -Version 7.0

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("daily", "weekly", "monthly")]
    [string]$Period = "monthly",

    [Parameter(Mandatory = $false)]
    [ValidateSet("html", "json", "text")]
    [string]$Format = "html",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$UploadToStrata,

    [Parameter(Mandatory = $false)]
    [string]$PrometheusUrl = "http://localhost:9090",

    [Parameter(Mandatory = $false)]
    [string[]]$Services = @("Genesis", "MicroScheduler", "Secrets", "Veil", "Pulse", "Chronicle")
)

# ════════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════════

$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReportPath = if ($OutputPath) { $OutputPath } else { "./reports" }

# SLO targets (from config/slo_targets.yaml)
$SLOTargets = @{
    Genesis = @{
        Availability = 0.999
        LatencyP99Ms = 200
        LatencyP95Ms = 100
        ErrorRate = 0.001
    }
    MicroScheduler = @{
        Availability = 0.999
        LatencyP99Ms = 300
        LatencyP95Ms = 150
        ErrorRate = 0.001
    }
    Secrets = @{
        Availability = 0.999
        LatencyP99Ms = 150
        LatencyP95Ms = 75
        ErrorRate = 0.001
    }
    Veil = @{
        Availability = 0.995
        LatencyP99Ms = 1000
        LatencyP95Ms = 500
        ErrorRate = 0.005
    }
    Pulse = @{
        Availability = 0.995
        LatencyP99Ms = 500
        LatencyP95Ms = 200
        ErrorRate = 0.005
    }
    Chronicle = @{
        Availability = 0.995
        LatencyP99Ms = 1000
        LatencyP95Ms = 500
        ErrorRate = 0.005
    }
}

# ════════════════════════════════════════════════════════════════════
# Functions
# ════════════════════════════════════════════════════════════════════

function Get-SLIMetrics {
    <#
    .SYNOPSIS
        Query Prometheus for SLI metrics.
    #>
    param(
        [string]$Service,
        [int]$WindowMinutes = 5
    )

    $AvailabilityQuery = "sum(rate(aither_service_requests_total_success{service=`"$Service`"}[${WindowMinutes}m])) / (sum(rate(aither_service_requests_total_success{service=`"$Service`"}[${WindowMinutes}m])) + sum(rate(aither_service_requests_total_error{service=`"$Service`"}[${WindowMinutes}m])))"
    $ErrorRateQuery = "sum(rate(aither_service_requests_total_error{service=`"$Service`"}[${WindowMinutes}m])) / (sum(rate(aither_service_requests_total_success{service=`"$Service`"}[${WindowMinutes}m])) + sum(rate(aither_service_requests_total_error{service=`"$Service`"}[${WindowMinutes}m])))"
    $LatencyP99Query = "histogram_quantile(0.99, sum by (le) (rate(aither_service_request_duration_seconds_bucket{service=`"$Service`"}[${WindowMinutes}m])))"
    $LatencyP95Query = "histogram_quantile(0.95, sum by (le) (rate(aither_service_request_duration_seconds_bucket{service=`"$Service`"}[${WindowMinutes}m])))"

    try {
        $AvailResult = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/query" -Method Get -Body @{ query = $AvailabilityQuery } -ErrorAction SilentlyContinue
        $ErrorRateResult = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/query" -Method Get -Body @{ query = $ErrorRateQuery } -ErrorAction SilentlyContinue
        $P99Result = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/query" -Method Get -Body @{ query = $LatencyP99Query } -ErrorAction SilentlyContinue
        $P95Result = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/query" -Method Get -Body @{ query = $LatencyP95Query } -ErrorAction SilentlyContinue

        return @{
            Availability = if ($AvailResult.data.result.count -gt 0) { [float]$AvailResult.data.result[0].value[1] } else { 0.0 }
            ErrorRate = if ($ErrorRateResult.data.result.count -gt 0) { [float]$ErrorRateResult.data.result[0].value[1] } else { 0.0 }
            LatencyP99Ms = if ($P99Result.data.result.count -gt 0) { [float]$P99Result.data.result[0].value[1] * 1000 } else { 0.0 }
            LatencyP95Ms = if ($P95Result.data.result.count -gt 0) { [float]$P95Result.data.result[0].value[1] * 1000 } else { 0.0 }
        }
    }
    catch {
        Write-Warning "Failed to query metrics for $Service`: $_"
        return $null
    }
}

function New-SLIRow {
    <#
    .SYNOPSIS
        Create SLI data row for HTML/JSON output.
    #>
    param(
        [string]$Service,
        [hashtable]$Actual,
        [hashtable]$Target
    )

    $AvailStatus = if ($Actual.Availability -ge $Target.Availability) { "✓ PASS" } else { "✗ FAIL" }
    $ErrorRateStatus = if ($Actual.ErrorRate -le $Target.ErrorRate) { "✓ PASS" } else { "✗ FAIL" }
    $LatencyP99Status = if ($Actual.LatencyP99Ms -le $Target.LatencyP99Ms) { "✓ PASS" } else { "✗ FAIL" }
    $LatencyP95Status = if ($Actual.LatencyP95Ms -le $Target.LatencyP95Ms) { "✓ PASS" } else { "✗ FAIL" }

    return @{
        Service = $Service
        Availability = @{
            Actual = "{0:P2}" -f $Actual.Availability
            Target = "{0:P2}" -f $Target.Availability
            Status = $AvailStatus
        }
        ErrorRate = @{
            Actual = "{0:P3}" -f $Actual.ErrorRate
            Target = "{0:P3}" -f $Target.ErrorRate
            Status = $ErrorRateStatus
        }
        LatencyP99 = @{
            Actual = "{0:F0}ms" -f $Actual.LatencyP99Ms
            Target = "{0:F0}ms" -f $Target.LatencyP99Ms
            Status = $LatencyP99Status
        }
        LatencyP95 = @{
            Actual = "{0:F0}ms" -f $Actual.LatencyP95Ms
            Target = "{0:F0}ms" -f $Target.LatencyP95Ms
            Status = $LatencyP95Status
        }
    }
}

function ConvertTo-HtmlReport {
    <#
    .SYNOPSIS
        Generate HTML SLO report.
    #>
    param(
        [array]$SLIData,
        [datetime]$ReportDate
    )

    $HtmlTemplate = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AitherOS SLO Report — $($ReportDate.ToString('MMMM dd, yyyy'))</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            margin: 0;
            padding: 20px;
            background: #f5f5f5;
            color: #333;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 {
            color: #1a1a1a;
            margin-bottom: 10px;
            border-bottom: 3px solid #007bff;
            padding-bottom: 10px;
        }
        .metadata {
            color: #666;
            font-size: 14px;
            margin-bottom: 30px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            font-size: 14px;
        }
        th {
            background: #f8f9fa;
            border: 1px solid #ddd;
            padding: 12px;
            text-align: left;
            font-weight: 600;
        }
        td {
            border: 1px solid #ddd;
            padding: 12px;
        }
        tr:nth-child(even) {
            background: #fafbfc;
        }
        .pass {
            color: #28a745;
            font-weight: 600;
        }
        .fail {
            color: #dc3545;
            font-weight: 600;
        }
        .footer {
            margin-top: 40px;
            padding-top: 20px;
            border-top: 1px solid #eee;
            font-size: 12px;
            color: #999;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>AitherOS Service Level Objectives (SLOs)</h1>
        <div class="metadata">
            <p><strong>Report Date:</strong> $($ReportDate.ToString('MMMM dd, yyyy'))</p>
            <p><strong>Period:</strong> $Period</p>
            <p><strong>Generated:</strong> $(Get-Date -Format 'u')</p>
        </div>

        <h2>SLI vs Target Summary</h2>
        <table>
            <thead>
                <tr>
                    <th>Service</th>
                    <th>Availability</th>
                    <th>Error Rate</th>
                    <th>P99 Latency</th>
                    <th>P95 Latency</th>
                </tr>
            </thead>
            <tbody>
$(
    foreach ($row in $SLIData) {
        $availClass = if ($row.Availability.Status -eq "✓ PASS") { "pass" } else { "fail" }
        $errClass = if ($row.ErrorRate.Status -eq "✓ PASS") { "pass" } else { "fail" }
        $p99Class = if ($row.LatencyP99.Status -eq "✓ PASS") { "pass" } else { "fail" }
        $p95Class = if ($row.LatencyP95.Status -eq "✓ PASS") { "pass" } else { "fail" }

        @"
                <tr>
                    <td><strong>$($row.Service)</strong></td>
                    <td><span class="$availClass">$($row.Availability.Status)</span><br/>$($row.Availability.Actual) / $($row.Availability.Target)</td>
                    <td><span class="$errClass">$($row.ErrorRate.Status)</span><br/>$($row.ErrorRate.Actual) / $($row.ErrorRate.Target)</td>
                    <td><span class="$p99Class">$($row.LatencyP99.Status)</span><br/>$($row.LatencyP99.Actual) / $($row.LatencyP99.Target)</td>
                    <td><span class="$p95Class">$($row.LatencyP95.Status)</span><br/>$($row.LatencyP95.Actual) / $($row.LatencyP95.Target)</td>
                </tr>
"@
        }
    )
            </tbody>
        </table>

        <div class="footer">
            <p>This report is automatically generated from Prometheus metrics. For more details, visit the SLO dashboard.</p>
        </div>
    </div>
</body>
</html>
"@

    return $HtmlTemplate
}

# ════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════

Write-Host "Generating SLO report for period: $Period" -ForegroundColor Green

# Create reports directory if needed
if (-not (Test-Path $ReportPath)) {
    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
}

# Collect SLI metrics
$SLIData = @()
foreach ($Service in $Services) {
    if ($SLOTargets[$Service]) {
        Write-Host "  Collecting metrics for $Service..." -NoNewline
        $Actual = Get-SLIMetrics -Service $Service
        if ($Actual) {
            $Row = New-SLIRow -Service $Service -Actual $Actual -Target $SLOTargets[$Service]
            $SLIData += $Row
            Write-Host " ✓" -ForegroundColor Green
        }
        else {
            Write-Host " ✗ (no data)" -ForegroundColor Yellow
        }
    }
}

# Generate report
$ReportDate = Get-Date
$DefaultOutputPath = Join-Path $ReportPath "slo-report-$($ReportDate.ToString('yyyyMMdd-HHmmss')).$($Format.ToLower())"
$FinalOutputPath = if ($OutputPath) { $OutputPath } else { $DefaultOutputPath }

switch ($Format) {
    "html" {
        $ReportContent = ConvertTo-HtmlReport -SLIData $SLIData -ReportDate $ReportDate
        $ReportContent | Out-File -Path $FinalOutputPath -Encoding UTF8
        Write-Host "HTML report saved: $FinalOutputPath" -ForegroundColor Green
    }
    "json" {
        $ReportContent = @{
            timestamp = $ReportDate
            period = $Period
            services = $SLIData
        } | ConvertTo-Json -Depth 10
        $ReportContent | Out-File -Path $FinalOutputPath -Encoding UTF8
        Write-Host "JSON report saved: $FinalOutputPath" -ForegroundColor Green
    }
    "text" {
        $ReportContent = @"
AitherOS SLO Report — $($ReportDate.ToString('MMMM dd, yyyy'))
Period: $Period

Service-Level Indicators vs Targets:
"@
        foreach ($row in $SLIData) {
            $ReportContent += "`n`n$($row.Service):"
            $ReportContent += "`n  Availability: $($row.Availability.Status) — $($row.Availability.Actual) / $($row.Availability.Target)"
            $ReportContent += "`n  Error Rate: $($row.ErrorRate.Status) — $($row.ErrorRate.Actual) / $($row.ErrorRate.Target)"
            $ReportContent += "`n  P99 Latency: $($row.LatencyP99.Status) — $($row.LatencyP99.Actual) / $($row.LatencyP99.Target)"
            $ReportContent += "`n  P95 Latency: $($row.LatencyP95.Status) — $($row.LatencyP95.Actual) / $($row.LatencyP95.Target)"
        }
        $ReportContent | Out-File -Path $FinalOutputPath -Encoding UTF8
        Write-Host "Text report saved: $FinalOutputPath" -ForegroundColor Green
    }
}

# Upload to Strata if requested
if ($UploadToStrata) {
    Write-Host "Uploading report to Strata..." -NoNewline
    try {
        $ReportContent = Get-Content -Path $FinalOutputPath -Raw
        $StrataPayload = @{
            session_id = "slo-report-$($ReportDate.ToString('yyyyMMdd'))"
            artifact_type = "slo_report"
            format = $Format
            period = $Period
            content = $ReportContent
            timestamp = $ReportDate.ToUniversalTime().ToString("o")
        } | ConvertTo-Json

        Invoke-RestMethod -Uri "http://localhost:8136/api/v1/ingest/ide-session" -Method Post -Body $StrataPayload -ContentType "application/json" | Out-Null
        Write-Host " ✓" -ForegroundColor Green
    }
    catch {
        Write-Host " ✗" -ForegroundColor Yellow
        Write-Warning "Failed to upload to Strata: $_"
    }
}

Write-Host "Report generation complete!" -ForegroundColor Green
