#Requires -Version 7.0
<#
.SYNOPSIS
    Exports cached news articles from AitherNewsWire and generates the GitHub Pages
    static news archive.

.DESCRIPTION
    This script connects to the running AitherNewsWire service, exports cached articles,
    runs the archive generator to produce Jekyll-compatible Markdown files, and optionally
    commits + pushes the results to GitHub for automatic Pages deployment.

    The archive at docs/news/ grows over time — each run adds new articles without
    removing existing ones. A manifest tracks all archived article IDs to prevent
    duplicates.

.PARAMETER HoursBack
    Number of hours of articles to export. Default: 24.

.PARAMETER MaxArticles
    Maximum number of articles per run. Default: 200.

.PARAMETER NewsWireUrl
    URL of the AitherNewsWire service. Default: http://localhost:8208.

.PARAMETER DryRun
    Preview changes without writing files or committing.

.PARAMETER AutoCommit
    Automatically commit and push changes to GitHub. Default: $false.

.PARAMETER OutputDir
    Output directory for the archive. Default: docs/news.

.EXAMPLE
    .\0848_Build-NewsArchive.ps1
    # Export last 24h of articles and generate archive

.EXAMPLE
    .\0848_Build-NewsArchive.ps1 -HoursBack 48 -AutoCommit
    # Export 48h of articles, commit and push

.EXAMPLE
    .\0848_Build-NewsArchive.ps1 -DryRun -Verbose
    # Preview without writing

.NOTES
    Category: aitheros
    Sequence: 0848
    Depends:  AitherNewsWire (port 8208), Python 3.10+
#>

[CmdletBinding()]
param(
    [int]$HoursBack = 24,
    [int]$MaxArticles = 200,
    [string]$NewsWireUrl = "http://localhost:8208",
    [switch]$DryRun,
    [switch]$AutoCommit,
    [string]$OutputDir = "docs/news"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve paths ─────────────────────────────────────────────────────
$RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
$GeneratorScript = Join-Path $RepoRoot "AitherOS/services/social/news_archive_generator.py"
$OutputPath = Join-Path $RepoRoot $OutputDir
$SnapshotDir = Join-Path $RepoRoot "data/newswire"

Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  📰 AitherOS News Archive Builder" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Repo Root:    $RepoRoot" -ForegroundColor Gray
Write-Host "  Output Dir:   $OutputPath" -ForegroundColor Gray
Write-Host "  NewsWire URL: $NewsWireUrl" -ForegroundColor Gray
Write-Host "  Hours Back:   $HoursBack" -ForegroundColor Gray
Write-Host "  Max Articles: $MaxArticles" -ForegroundColor Gray
Write-Host "  Dry Run:      $DryRun" -ForegroundColor Gray
Write-Host "  Auto Commit:  $AutoCommit" -ForegroundColor Gray
Write-Host ""

# ── Step 1: Check prerequisites ───────────────────────────────────────
Write-Host "📋 Checking prerequisites..." -ForegroundColor Yellow

if (-not (Test-Path $GeneratorScript)) {
    Write-Error "Generator script not found: $GeneratorScript"
    exit 1
}

$pythonCmd = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" }
             elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" }
             else { $null }

if (-not $pythonCmd) {
    Write-Error "Python not found. Install Python 3.10+ to run the archive generator."
    exit 1
}

Write-Host "  ✅ Python: $pythonCmd" -ForegroundColor Green
Write-Host "  ✅ Generator: $GeneratorScript" -ForegroundColor Green

# ── Step 2: Try to fetch from live service ────────────────────────────
Write-Host ""
Write-Host "📡 Attempting to export from NewsWire..." -ForegroundColor Yellow

$ExportJson = $null
$ExportPath = Join-Path $SnapshotDir "archive_export_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"

try {
    $response = Invoke-RestMethod -Uri "$NewsWireUrl/newswire/archive/export" `
        -Method POST `
        -Body (@{ hours_back = $HoursBack; limit = $MaxArticles } | ConvertTo-Json) `
        -ContentType "application/json" `
        -TimeoutSec 30 `
        -ErrorAction Stop

    $articleCount = $response.count
    Write-Host "  ✅ Exported $articleCount articles from live service" -ForegroundColor Green

    # Save export to file
    New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null
    $response | ConvertTo-Json -Depth 10 | Set-Content -Path $ExportPath -Encoding UTF8
    $ExportJson = $ExportPath
    Write-Host "  💾 Saved export: $ExportPath" -ForegroundColor Gray
}
catch {
    Write-Host "  ⚠️ Live fetch failed: $($_.Exception.Message)" -ForegroundColor DarkYellow

    # Try to find a recent snapshot
    if (Test-Path $SnapshotDir) {
        $latest = Get-ChildItem $SnapshotDir -Filter "archive_snapshot_*.json" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($latest) {
            $ExportJson = $latest.FullName
            $age = [math]::Round(((Get-Date) - $latest.LastWriteTime).TotalHours, 1)
            Write-Host "  📂 Using cached snapshot ($age hours old): $($latest.Name)" -ForegroundColor DarkYellow
        }
    }

    if (-not $ExportJson) {
        Write-Host "  ❌ No articles available. Run with live NewsWire or provide a snapshot." -ForegroundColor Red
        exit 0
    }
}

# ── Step 3: Run the archive generator ─────────────────────────────────
Write-Host ""
Write-Host "🔧 Running archive generator..." -ForegroundColor Yellow

$genArgs = @(
    $GeneratorScript,
    "--output-dir", $OutputPath,
    "--from-json", $ExportJson,
    "--hours", $HoursBack,
    "--limit", $MaxArticles,
    "--verbose"
)

if ($DryRun) {
    $genArgs += "--dry-run"
}

$result = & $pythonCmd @genArgs 2>&1
$lastLine = ($result | Select-Object -Last 1) -as [string]

# Display output
$result | Where-Object { $_ -notmatch '^\{' } | ForEach-Object {
    Write-Host "  $_" -ForegroundColor Gray
}

# Try to parse the JSON summary
try {
    $summary = $lastLine | ConvertFrom-Json
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  📊 Archive Generation Complete" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  New articles:     $($summary.new_articles)" -ForegroundColor White
    Write-Host "  Duplicates:       $($summary.skipped_duplicates)" -ForegroundColor Gray
    Write-Host "  Errors:           $($summary.errors)" -ForegroundColor $(if ($summary.errors -gt 0) { "Red" } else { "Gray" })
    Write-Host "  Total archived:   $($summary.total_in_archive)" -ForegroundColor Cyan
    Write-Host "  Categories:       $($summary.categories)" -ForegroundColor Gray
    Write-Host "  Sources:          $($summary.sources)" -ForegroundColor Gray
    Write-Host ""
}
catch {
    Write-Host "  ⚠️ Could not parse generator output" -ForegroundColor DarkYellow
}

# ── Step 4: Git commit (if requested) ─────────────────────────────────
if ($AutoCommit -and -not $DryRun) {
    Write-Host "📤 Committing changes to Git..." -ForegroundColor Yellow

    Push-Location $RepoRoot
    try {
        git add "docs/news/" 2>$null

        $changes = git diff --cached --stat 2>$null
        if ($changes) {
            $newFiles = (git diff --cached --name-only --diff-filter=A | Select-String "docs/news/" | Measure-Object).Count
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm UTC"

            git commit -m "📰 News Archive: +$newFiles articles ($timestamp)" `
                -m "Automated archive update by AitherNewsWire.`nNew articles: $newFiles" 2>$null

            git push 2>$null
            Write-Host "  ✅ Committed and pushed" -ForegroundColor Green
        }
        else {
            Write-Host "  ℹ️ No changes to commit" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "  ⚠️ Git commit failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "Done! Archive at: $OutputPath" -ForegroundColor Green
