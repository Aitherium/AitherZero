#Requires -Version 7.0

<#
.SYNOPSIS
    Runs advanced simulations and syncs results to GH Pages.
.DESCRIPTION
    Executes the Python simulation suite, generates a report, and triggers the GH Pages deployment.
#>

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot
$AitherOSRoot = Resolve-Path "$PSScriptRoot/../../../../"
$SimScript = "$AitherOSRoot/AitherOS/tests/simulations/advanced_sim.py"
$DeployScript = "$AitherOSRoot/AitherZero/library/automation-scripts/_archive/0516_Deploy-GHPages.ps1"

Write-Host "🚀 Starting Advanced Simulation..." -ForegroundColor Cyan

# 1. Run Simulation
if (Test-Path $SimScript) {
    Write-Host "  Running simulation logic..." -ForegroundColor Gray
    python $SimScript
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Simulation failed!"
    }
} else {
    Write-Error "Simulation script not found at $SimScript"
}

# 2. Deploy to GH Pages
# Check if the deploy script exists (it might be in _archive or moved)
# The user's ls showed it in _archive earlier? No, I should check.
# The user's ls output:
# -a---          12/17/2025 11:50 AM           3310 0516_Deploy-GHPages.ps1
# It was in _archive based on my ls? 
# Let's double check path logic.
# My ls of `automation-scripts` showed `_archive` at the top and `0516` inside `_archive`.
# No wait, the `ls AitherZero/library/automation-scripts/_archive` output contained `0516_Deploy-GHPages.ps1`.
# So it IS in _archive.

if (Test-Path $DeployScript) {
    Write-Host "🌍 Syncing to GitHub Pages..." -ForegroundColor Cyan
    & $DeployScript
} else {
    Write-Warning "Deploy script not found at $DeployScript. Skipping sync."
}

Write-Host "✅ Simulation Cycle Complete." -ForegroundColor Green
