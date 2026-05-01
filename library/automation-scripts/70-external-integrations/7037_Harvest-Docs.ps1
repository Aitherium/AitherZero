#Requires -Version 7.0

<#
.SYNOPSIS
    Harvest ALL Roboflow documentation from every source — fully automated

.DESCRIPTION
    Wraps the Python harvest_docs.py script for AitherZero playbook integration.
    Downloads 88+ doc pages from docs.roboflow.com, inference docs, supervision,
    SDK, blog, autodistill, and universe. Discovers extra pages from sitemaps.
    Rebuilds the knowledge graph after harvesting.

    Exit Codes:
    0 - Success
    1 - Harvester script not found
    2 - Harvest failed

.PARAMETER Force
    Re-download all docs even if already cached

.PARAMETER Section
    Only harvest one section (core, inference, workflows, supervision, api, sdk, blog, enterprise, autodistill, universe, video)

.PARAMETER Discover
    Try to discover extra pages from sitemaps

.PARAMETER CheckOnly
    Just report coverage gaps without downloading

.PARAMETER SkipGraph
    Skip knowledge graph rebuild after harvest

.PARAMETER DryRun
    Show what would be done without making changes

.NOTES
    Stage: ExternalIntegrations
    Order: 7037
    Dependencies: 7030
    Tags: roboflow, documentation, harvest, knowledge-graph
    AllowParallel: false

.EXAMPLE
    .\7037_Harvest-Docs.ps1

.EXAMPLE
    .\7037_Harvest-Docs.ps1 -Force -Discover

.EXAMPLE
    .\7037_Harvest-Docs.ps1 -CheckOnly
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [string]$Section,
    [switch]$Discover,
    [switch]$CheckOnly,
    [switch]$SkipGraph,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/../_init.ps1"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Roboflow Documentation Harvester                    ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$roboflowRoot = Join-Path $projectRoot ".roboflow"
$harvester = Join-Path $roboflowRoot "harvest_docs.py"

if (-not (Test-Path $harvester)) {
    Write-Error "harvest_docs.py not found at: $harvester"
    exit 1
}

# Count existing docs before
$docsBefore = (Get-ChildItem -Path $roboflowRoot -Filter "rbflow-*.txt" -ErrorAction SilentlyContinue).Count
Write-Host "  Existing docs: $docsBefore" -ForegroundColor Gray

# Build command args
$pyArgs = @()

if ($CheckOnly) {
    $pyArgs += "--check"
} else {
    # Always run non-interactive for playbook
    $pyArgs += "--auto"
}

if ($Force) {
    $pyArgs += "--force"
}

if ($Discover) {
    $pyArgs += "--discover"
}

if ($Section) {
    $pyArgs += "--section"
    $pyArgs += $Section
}

if (-not $SkipGraph -and -not $CheckOnly) {
    $pyArgs += "--rebuild-graph"
}

$argString = $pyArgs -join " "
Write-Host "  Running: python harvest_docs.py $argString" -ForegroundColor Yellow
Write-Host ""

if ($DryRun) {
    Write-Host "  [DRY RUN] Would run: python $harvester $argString" -ForegroundColor DarkGray
    exit 0
}

# Activate venv if available
$venvActivate = Join-Path $roboflowRoot ".venv/Scripts/Activate.ps1"
if (Test-Path $venvActivate) {
    . $venvActivate
}

# Run the harvester
try {
    Push-Location $roboflowRoot
    & python $harvester @pyArgs
    $exitCode = $LASTEXITCODE
    Pop-Location

    if ($exitCode -ne 0) {
        Write-Warning "Harvester exited with code $exitCode"
    }
} catch {
    Write-Error "Harvest failed: $_"
    exit 2
}

# Count docs after
$docsAfter = (Get-ChildItem -Path $roboflowRoot -Filter "rbflow-*.txt" -ErrorAction SilentlyContinue).Count
$newDocs = $docsAfter - $docsBefore
$totalSizeKB = [math]::Round(((Get-ChildItem -Path $roboflowRoot -Filter "rbflow-*.txt" | Measure-Object -Property Length -Sum).Sum / 1KB), 0)

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║       Harvest Complete                                     ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "  Total docs:   $docsAfter files (${totalSizeKB}KB)" -ForegroundColor Green
Write-Host "  New this run: $newDocs" -ForegroundColor Green
Write-Host ""
