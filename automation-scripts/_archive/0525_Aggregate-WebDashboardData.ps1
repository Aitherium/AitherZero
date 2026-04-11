#Requires -Version 7.0

<#
.SYNOPSIS
    Aggregates all project data for the Web Dashboard (Next.js).
.DESCRIPTION
    Runs reporting scripts (0510, 0513) and consolidates data into the
    Web Dashboard's public/data directory.
.NOTES
    Stage: Reporting
    Order: 0525
    Tags: dashboard, data, integration
#>

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Paths
$ProjectRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent
$ReportsDir = Join-Path $ProjectRoot "AitherZero/library/reports"
$WebDashDir = Join-Path $ProjectRoot "AitherZero/library/integrations/AitherZero-WebDash"
$WebDataDir = Join-Path $WebDashDir "public/data"

# Ensure directories exist
if (-not (Test-Path $WebDataDir)) {
    New-Item -Path $WebDataDir -ItemType Directory -Force | Out-Null
}

# 1. Generate Project Report (0510)
Write-Host "Generating Project Report..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "0510_Generate-ProjectReport.ps1") -Format JSON

# 2. Generate Performance Metrics (0513)
Write-Host "Generating Performance Metrics..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "0513_Profile-ModulePerformance.ps1")

# 3. Copy Data to Web Dashboard
Write-Host "Syncing data to Web Dashboard..." -ForegroundColor Cyan

# Find latest Project Report
$latestReport = Get-ChildItem -Path $ReportsDir -Filter "ProjectReport-*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestReport) {
    Copy-Item $latestReport.FullName -Destination (Join-Path $WebDataDir "project-report.json") -Force
    Write-Host "  Synced: project-report.json" -ForegroundColor Green
}

# Find Performance Metrics
$perfMetrics = Join-Path $ReportsDir "performance-metrics.json"
if (Test-Path $perfMetrics) {
    Copy-Item $perfMetrics -Destination (Join-Path $WebDataDir "performance-metrics.json") -Force
    Write-Host "  Synced: performance-metrics.json" -ForegroundColor Green
}

$perfDash = Join-Path $ReportsDir "performance-dashboard.json"
if (Test-Path $perfDash) {
    Copy-Item $perfDash -Destination (Join-Path $WebDataDir "performance-dashboard.json") -Force
    Write-Host "  Synced: performance-dashboard.json" -ForegroundColor Green
}

# 4. Generate Manifest
$manifest = @{
    LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Files = @(
        "project-report.json",
        "performance-metrics.json",
        "performance-dashboard.json"
    )
}
$manifest | ConvertTo-Json | Set-Content (Join-Path $WebDataDir "manifest.json")

Write-Host "Dashboard data aggregation complete." -ForegroundColor Green
