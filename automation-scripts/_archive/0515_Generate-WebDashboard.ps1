#Requires -Version 7.0

<#
.SYNOPSIS
    Generates a comprehensive, interactive HTML dashboard using the enhanced templates.
.DESCRIPTION
    Aggregates test results, coverage, quality metrics, and performance data.
    Uses the 'AitherZero/library/templates/dashboard' assets to create a rich UI.
.NOTES
    Stage: Reporting
    Order: 0515
    Tags: reporting, dashboard, html
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BranchName = "dev",
    [string]$CommitHash = "local",
    [string]$OutputPath = (Join-Path ($PSScriptRoot | Split-Path -Parent | Split-Path -Parent) "public"),
    [string]$TemplatePath = (Join-Path ($PSScriptRoot | Split-Path -Parent | Split-Path -Parent) "AitherZero/library/templates/dashboard"),
    [string]$ReportPath = (Join-Path ($PSScriptRoot | Split-Path -Parent | Split-Path -Parent) "AitherZero/library/tests/reports")
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Initialize logging
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Level $Level -Message $Message -Source "GenerateWebDashboard"
    } else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Generating Enhanced Dashboard for branch: $BranchName"

# 1. Prepare Output Directory
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    Write-ScriptLog "Created output directory: $OutputPath"
}

# 2. Copy Assets
$assets = @("styles.css", "enhanced-styles.css", "dashboard.js", "enhanced-scripts.js", "enhanced-charts.js", "ring-status-css.css")
foreach ($asset in $assets) {
    $src = Join-Path $TemplatePath $asset
    if (Test-Path $src) {
        Copy-Item $src $OutputPath -Force
    } else {
        Write-ScriptLog "Asset not found: $src" -Level Warning
    }
}

# 3. Load Data
$data = @{
    Tests = @{ Passed=0; Failed=0; Skipped=0; Total=0; Duration=0; Suites=@() }
    Coverage = @{ Total=0; Modules=@() }
    Quality = @{ Issues=0; Rules=@() }
    Performance = @{ TotalDuration=0; Commands=@() }
}

# Load Test Results
$testFiles = Get-ChildItem -Path $ReportPath -Filter "*Summary*.json" -Recurse -ErrorAction SilentlyContinue
foreach ($file in $testFiles) {
    try {
        $json = Get-Content $file.FullName | ConvertFrom-Json
        $data.Tests.Passed += $json.PassedCount
        $data.Tests.Failed += $json.FailedCount
        $data.Tests.Skipped += $json.SkippedCount
        $data.Tests.Total += $json.TotalCount
        if ($json.Duration) { $data.Tests.Duration += $json.Duration.TotalSeconds }

        $data.Tests.Suites += [PSCustomObject]@{
            Name = $file.BaseName
            Passed = $json.PassedCount
            Failed = $json.FailedCount
            Skipped = $json.SkippedCount
            Duration = if ($json.Duration) { $json.Duration.TotalSeconds } else { 0 }
        }
    } catch {}
}

# Load Coverage
$covFile = Join-Path $ReportPath "coverage-summary.json"
if (Test-Path $covFile) {
    try {
        $cov = Get-Content $covFile | ConvertFrom-Json
        $data.Coverage.Total = $cov.TotalCoverage
        $data.Coverage.Modules = $cov.Modules
    } catch {}
}

# Load Quality
$qualFile = Join-Path $ReportPath "psscriptanalyzer-results.json"
if (Test-Path $qualFile) {
    try {
        $qual = Get-Content $qualFile | ConvertFrom-Json
        $data.Quality.Issues = $qual.Count
        $data.Quality.Rules = $qual | Group-Object RuleName | Select-Object Name, Count
    } catch {}
}

# Load Performance
$perfFile = Join-Path $ReportPath "performance-profile.json"
if (Test-Path $perfFile) {
    try {
        $perf = Get-Content $perfFile | ConvertFrom-Json
        $data.Performance.TotalDuration = $perf.TotalDuration
        $data.Performance.Commands = $perf.Commands
    } catch {}
}

# 4. Generate HTML Content Sections
$content = [System.Text.StringBuilder]::new()

# -- Overview Section --
$content.AppendLine('<section id="overview" class="section active">') | Out-Null
$content.AppendLine('<h2>Overview</h2>') | Out-Null
$content.AppendLine('<div class="metrics-grid">') | Out-Null

# Metric Cards
$passRate = if ($data.Tests.Total -gt 0) { [math]::Round(($data.Tests.Passed / $data.Tests.Total) * 100, 1) } else { 0 }
$content.AppendLine(@"
    <div class="card metric-card">
        <h3>Test Pass Rate</h3>
        <div class="value $(if ($passRate -eq 100) { 'pass' } else { 'fail' })">$passRate%</div>
        <div class="label">$($data.Tests.Passed) / $($data.Tests.Total) Passed</div>
    </div>
    <div class="card metric-card">
        <h3>Code Coverage</h3>
        <div class="value">$([math]::Round($data.Coverage.Total, 1))%</div>
        <div class="label">Target: 80%</div>
    </div>
    <div class="card metric-card">
        <h3>Quality Issues</h3>
        <div class="value">$($data.Quality.Issues)</div>
        <div class="label">PSScriptAnalyzer</div>
    </div>
    <div class="card metric-card">
        <h3>Build Time</h3>
        <div class="value">$([math]::Round($data.Tests.Duration, 1))s</div>
        <div class="label">Test Execution</div>
    </div>
"@) | Out-Null
$content.AppendLine('</div>') | Out-Null # End metrics-grid

# Charts Container
$content.AppendLine('<div class="charts-container">') | Out-Null
$content.AppendLine('  <div class="chart-wrapper"><canvas id="testDistributionChart"></canvas></div>') | Out-Null
$content.AppendLine('  <div class="chart-wrapper"><canvas id="coverageTrendChart"></canvas></div>') | Out-Null
$content.AppendLine('</div>') | Out-Null
$content.AppendLine('</section>') | Out-Null

# -- Quality Section --
$content.AppendLine('<section id="quality" class="section">') | Out-Null
$content.AppendLine('<h2>Quality Metrics</h2>') | Out-Null
if ($data.Quality.Issues -gt 0) {
    $content.AppendLine('<table class="data-table"><thead><tr><th>Rule</th><th>Count</th></tr></thead><tbody>') | Out-Null
    foreach ($rule in $data.Quality.Rules) {
        $content.AppendLine("<tr><td>$($rule.Name)</td><td>$($rule.Count)</td></tr>") | Out-Null
    }
    $content.AppendLine('</tbody></table>') | Out-Null
} else {
    $content.AppendLine('<div class="alert success">No quality issues found!</div>') | Out-Null
}
$content.AppendLine('</section>') | Out-Null

# -- Tests Section --
$content.AppendLine('<section id="tests" class="section">') | Out-Null
$content.AppendLine('<h2>Test Results</h2>') | Out-Null
$content.AppendLine('<table class="data-table"><thead><tr><th>Suite</th><th>Passed</th><th>Failed</th><th>Skipped</th><th>Duration</th></tr></thead><tbody>') | Out-Null
foreach ($suite in $data.Tests.Suites) {
    $content.AppendLine("<tr><td>$($suite.Name)</td><td>$($suite.Passed)</td><td>$($suite.Failed)</td><td>$($suite.Skipped)</td><td>$($suite.Duration.ToString('F2'))s</td></tr>") | Out-Null
}
$content.AppendLine('</tbody></table>') | Out-Null
$content.AppendLine('</section>') | Out-Null

# 5. Assemble Final HTML
$baseHtmlPath = Join-Path $TemplatePath "base.html"
if (-not (Test-Path $baseHtmlPath)) {
    Write-ScriptLog "Base template not found at $baseHtmlPath" -Level Error
    exit 1
}

$baseHtml = Get-Content $baseHtmlPath -Raw
$finalHtml = $baseHtml.Replace("{{TITLE}}", "AitherZero - $BranchName")
$finalHtml = $finalHtml.Replace("{{PROJECT_NAME}}", "AitherZero")
$finalHtml = $finalHtml.Replace("{{SUBTITLE}}", "Branch: $BranchName | Commit: $CommitHash")
$finalHtml = $finalHtml.Replace("{{TIMESTAMP}}", (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
$finalHtml = $finalHtml.Replace("{{CONTENT}}", $content.ToString())

# 6. Inject Data for Charts (Script Injection)
$chartScript = @"
<script>
    document.addEventListener('DOMContentLoaded', function() {
        initCharts({
            tests: { passed: $($data.Tests.Passed), failed: $($data.Tests.Failed), skipped: $($data.Tests.Skipped) },
            coverage: { total: $($data.Coverage.Total) }
        });
    });
</script>
"@
$finalHtml = $finalHtml.Replace("</body>", "$chartScript`n</body>")

$finalHtml | Set-Content (Join-Path $OutputPath "index.html")
Write-ScriptLog "Dashboard generated at $OutputPath/index.html" -Level Success
