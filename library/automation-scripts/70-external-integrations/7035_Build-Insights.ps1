#Requires -Version 7.0

<#
.SYNOPSIS
    Generate insights dashboard, CSV exports, webhook notifications, and presentation video
    
.DESCRIPTION
    Builds the actionable insights layer: processes pipeline logs into a dashboard,
    exports CSV of all processed assets, sends webhook notifications for new 3D assets,
    and generates the final presentation video using the AitherOS content director.
    
    Exit Codes:
    0 - Success
    1 - No pipeline data found
    2 - Video generation failed
    
.PARAMETER Action
    Action to perform:
    - Dashboard: Generate HTML insights dashboard from pipeline logs
    - Export: Export all asset metadata to CSV
    - Webhook: Configure and test webhook notifications
    - Video: Generate presentation video using direct_video_from_directory
    - Presentation: Build full presentation deck from .roboflow/ docs
    - Full: Run all actions
    
.PARAMETER WebhookUrl
    URL for webhook notifications (default: logs to file)
    
.PARAMETER VideoMinutes
    Target video length in minutes (default: 10)
    
.PARAMETER DryRun
    Show what would be done without making changes

.NOTES
    Stage: ExternalIntegrations
    Order: 7035
    Dependencies: 7030, 7033, 7034
    Tags: roboflow, insights, dashboard, presentation, video
    AllowParallel: false
    
.EXAMPLE
    .\7035_Build-Insights.ps1 -Action Full
    
.EXAMPLE
    .\7035_Build-Insights.ps1 -Action Video -VideoMinutes 15
    
.EXAMPLE
    .\7035_Build-Insights.ps1 -Action Presentation
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Dashboard", "Export", "Webhook", "Video", "Presentation", "Full")]
    [string]$Action = "Full",
    
    [string]$WebhookUrl = "",
    [int]$VideoMinutes = 10,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/../_init.ps1"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Roboflow Insights & Presentation Builder            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$roboflowRoot = Join-Path $projectRoot ".roboflow"
$logsDir = Join-Path $roboflowRoot "outputs/logs"
$presDir = Join-Path $roboflowRoot "presentation"

# ── Dashboard ─────────────────────────────────────────────────────────
if ($Action -in "Dashboard", "Full") {
    Write-Host "Building insights dashboard..." -ForegroundColor Yellow
    
    $dashboardScript = @"
import json, os
from datetime import datetime
from pathlib import Path
from collections import Counter

logs_dir = r"$logsDir"
pres_dir = r"$presDir"

# Read pipeline results
results = []
log_file = os.path.join(logs_dir, "pipeline_results.jsonl")
if os.path.exists(log_file):
    with open(log_file) as f:
        for line in f:
            if line.strip():
                try:
                    results.append(json.loads(line))
                except json.JSONDecodeError:
                    pass

total_images = len(results)
total_detections = sum(r.get("detections", 0) for r in results)
all_quality = []
for r in results:
    all_quality.extend(r.get("quality_results", []))

total_passed = sum(1 for q in all_quality if q.get("pass_fail") == "PASS")
total_failed = sum(1 for q in all_quality if q.get("pass_fail") == "FAIL")
class_counts = Counter(q.get("class", "unknown") for q in all_quality)
avg_quality = sum(q.get("quality_score", 0) for q in all_quality) / max(len(all_quality), 1)

# Generate HTML dashboard
html = f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Roboflow 3D Asset Pipeline — Dashboard</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ font-family: -apple-system, system-ui, sans-serif; background: #0f172a; color: #e2e8f0; padding: 2rem; }}
        h1 {{ font-size: 1.8rem; margin-bottom: 0.5rem; color: #22c55e; }}
        .subtitle {{ color: #94a3b8; margin-bottom: 2rem; }}
        .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1.5rem; margin-bottom: 2rem; }}
        .card {{ background: #1e293b; border-radius: 12px; padding: 1.5rem; border: 1px solid #334155; }}
        .card .label {{ font-size: 0.85rem; color: #94a3b8; margin-bottom: 0.5rem; }}
        .card .value {{ font-size: 2rem; font-weight: 700; }}
        .card .value.green {{ color: #22c55e; }}
        .card .value.red {{ color: #ef4444; }}
        .card .value.blue {{ color: #6366f1; }}
        .card .value.amber {{ color: #f59e0b; }}
        .bar-chart {{ margin-top: 2rem; }}
        .bar {{ display: flex; align-items: center; margin-bottom: 0.5rem; }}
        .bar-label {{ width: 100px; font-size: 0.85rem; color: #94a3b8; }}
        .bar-fill {{ height: 24px; background: #6366f1; border-radius: 4px; min-width: 4px; transition: width 0.5s; }}
        .bar-count {{ margin-left: 0.5rem; font-size: 0.85rem; color: #94a3b8; }}
        .timestamp {{ color: #475569; font-size: 0.8rem; margin-top: 2rem; }}
    </style>
</head>
<body>
    <h1>See It. Segment It. Build It.</h1>
    <p class="subtitle">Roboflow 3D Asset Pipeline — Live Dashboard</p>
    
    <div class="grid">
        <div class="card">
            <div class="label">Images Processed</div>
            <div class="value blue">{total_images}</div>
        </div>
        <div class="card">
            <div class="label">Total Detections</div>
            <div class="value blue">{total_detections}</div>
        </div>
        <div class="card">
            <div class="label">Quality Gate: Passed</div>
            <div class="value green">{total_passed}</div>
        </div>
        <div class="card">
            <div class="label">Quality Gate: Failed</div>
            <div class="value red">{total_failed}</div>
        </div>
        <div class="card">
            <div class="label">Pass Rate</div>
            <div class="value {'green' if total_passed > total_failed else 'amber'}">{total_passed / max(total_passed + total_failed, 1) * 100:.1f}%</div>
        </div>
        <div class="card">
            <div class="label">Avg Quality Score</div>
            <div class="value {'green' if avg_quality > 0.6 else 'amber'}">{avg_quality:.2f}</div>
        </div>
    </div>
    
    <h2 style="color: #cbd5e1; margin-bottom: 1rem;">Detections by Class</h2>
    <div class="bar-chart">'''

max_count = max(class_counts.values()) if class_counts else 1
for cls, count in class_counts.most_common():
    width = int(count / max_count * 400)
    html += f'''
        <div class="bar">
            <div class="bar-label">{cls}</div>
            <div class="bar-fill" style="width: {width}px;"></div>
            <div class="bar-count">{count}</div>
        </div>'''

html += f'''
    </div>
    <p class="timestamp">Generated: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</p>
</body>
</html>'''

dashboard_path = os.path.join(pres_dir, "dashboard.html")
os.makedirs(pres_dir, exist_ok=True)
with open(dashboard_path, "w") as f:
    f.write(html)

print(f"Dashboard: {dashboard_path}")
print(f"  Images: {total_images}, Detections: {total_detections}")
print(f"  Passed: {total_passed}, Failed: {total_failed}")
print(f"  Avg Quality: {avg_quality:.2f}")
"@
    $scriptPath = Join-Path $roboflowRoot "scripts/_build_dashboard.py"
    Set-Content -Path $scriptPath -Value $dashboardScript
    
    if (-not $DryRun) {
        $venvPython = Join-Path $roboflowRoot ".venv/Scripts/python.exe"
        if (-not (Test-Path $venvPython)) { $venvPython = "python" }
        & $venvPython $scriptPath
    }
    Write-Host "  ✓ Dashboard generated" -ForegroundColor Green
}

# ── CSV Export ────────────────────────────────────────────────────────
if ($Action -in "Export", "Full") {
    Write-Host "Exporting asset metadata to CSV..." -ForegroundColor Yellow
    
    $exportScript = @"
import json, csv, os
from pathlib import Path

logs_dir = r"$logsDir"
log_file = os.path.join(logs_dir, "pipeline_results.jsonl")
csv_path = os.path.join(logs_dir, "assets_export.csv")

rows = []
if os.path.exists(log_file):
    with open(log_file) as f:
        for line in f:
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
                for q in entry.get("quality_results", []):
                    rows.append({
                        "timestamp": entry.get("timestamp", ""),
                        "source": entry.get("source", ""),
                        "asset_id": q.get("asset_id", ""),
                        "class": q.get("class", ""),
                        "quality_score": q.get("quality_score", 0),
                        "pass_fail": q.get("pass_fail", ""),
                        "area_pct": q.get("area_pct", 0),
                        "confidence": q.get("confidence", 0),
                    })
            except json.JSONDecodeError:
                pass

if rows:
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    print(f"Exported {len(rows)} assets to {csv_path}")
else:
    print("No pipeline data to export yet")
"@
    $scriptPath = Join-Path $roboflowRoot "scripts/_export_csv.py"
    Set-Content -Path $scriptPath -Value $exportScript
    
    if (-not $DryRun) {
        $venvPython = Join-Path $roboflowRoot ".venv/Scripts/python.exe"
        if (-not (Test-Path $venvPython)) { $venvPython = "python" }
        & $venvPython $scriptPath
    }
    Write-Host "  ✓ CSV export complete" -ForegroundColor Green
}

# ── Presentation Video ────────────────────────────────────────────────
if ($Action -in "Video", "Presentation", "Full") {
    Write-Host "Generating presentation video from .roboflow/ docs..." -ForegroundColor Yellow
    Write-Host "  Target: $VideoMinutes minutes" -ForegroundColor Gray
    
    $videoScript = @"
import os, sys, json
sys.path.insert(0, r"$projectRoot\AitherOS")
sys.path.insert(0, r"$projectRoot\AitherOS\apps\AitherNode\tools\mcp")

os.environ["AITHER_TESTING"] = "1"
os.environ["AITHER_SKIP_HARDWARE_DETECT"] = "1"

from mcp_content_pipeline import direct_video_from_directory

result = direct_video_from_directory(
    directory=r"$roboflowRoot",
    prompt="Create an engaging technical presentation about this computer vision pipeline project. "
           "Focus on the architecture (detection -> segmentation -> quality gate -> 3D reconstruction), "
           "the custom Roboflow Workflow blocks, training strategy, failure modes and solutions, "
           "and the AitherOS integration for autonomous 3D asset generation. "
           "Include code examples for the custom blocks and pipeline client. "
           "Show real metrics and stats from the training process. "
           "Frame it as a customer enablement session: how YOU would build this pipeline.",
    title="See It. Segment It. Build It.",
    target_minutes=$VideoMinutes,
    theme="dark",
    accent_color="#22C55E",
    author="David Parkhurst",
    narrate=True,
    voice="nova",
    background_music="tour-ambient",
    music_volume=0.08,
    render=True,
)

data = json.loads(result)
if data.get("success"):
    print(f"\n  Video: {data.get('output_path', '?')}")
    print(f"  Duration: {data.get('duration_seconds', 0):.0f}s")
    print(f"  Slides: {data.get('slide_count', 0)}")
    print(f"  Files ingested: {data.get('files_ingested', 0)}")
    print(f"  Pipeline time: {data.get('pipeline_seconds', 0):.1f}s")
else:
    print(f"\n  Failed at step '{data.get('step', '?')}': {data.get('error', '?')}")
    print(f"  Full result: {json.dumps(data, indent=2)}")
"@
    $scriptPath = Join-Path $roboflowRoot "scripts/_generate_video.py"
    Set-Content -Path $scriptPath -Value $videoScript
    
    if (-not $DryRun) {
        Write-Host "  Running content director (this takes several minutes)..." -ForegroundColor Gray
        $venvPython = Join-Path $roboflowRoot ".venv/Scripts/python.exe"
        if (-not (Test-Path $venvPython)) { $venvPython = "python" }
        & $venvPython $scriptPath
    }
    Write-Host "  ✓ Presentation video pipeline complete" -ForegroundColor Green
}

Write-Host ""
exit 0
