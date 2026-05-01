#Requires -Version 7.0

<#
.SYNOPSIS
    Complete non-interactive bootstrap — system check, auto-fix, knowledge graph, Mission Control

.DESCRIPTION
    The glue script that ties everything together for fully automated bootstrap.
    Can run individual actions or the full sequence. Used by the roboflow-3d-bootstrap
    playbook for phases that don't have dedicated scripts.

    Actions:
    - SystemCheck: Run check_system.py with auto-fix
    - KnowledgeGraph: Rebuild knowledge graph from harvested docs
    - MissionControl: Start checker API + HTTP server + open browser
    - Validate: Run custom block import tests and pipeline dry-run
    - Full: All of the above in sequence

    Exit Codes:
    0 - Success
    1 - Critical failure
    2 - Partial failure (non-critical checks failed)

.PARAMETER Action
    Action to perform (SystemCheck, KnowledgeGraph, MissionControl, Validate, Full)

.PARAMETER AutoFix
    Run auto-fix for missing packages and environment issues

.PARAMETER Port
    HTTP server port for Mission Control (default: 8900)

.PARAMETER CheckerPort
    System checker API port (default: 8901)

.PARAMETER NoBrowser
    Don't open browser after starting Mission Control

.PARAMETER DryRun
    Show what would be done without making changes

.NOTES
    Stage: ExternalIntegrations
    Order: 7038
    Dependencies: 7030, 7037
    Tags: roboflow, bootstrap, system-check, knowledge-graph, dashboard
    AllowParallel: false

.EXAMPLE
    .\7038_Bootstrap-Complete.ps1 -Action Full

.EXAMPLE
    .\7038_Bootstrap-Complete.ps1 -Action SystemCheck -AutoFix

.EXAMPLE
    .\7038_Bootstrap-Complete.ps1 -Action MissionControl -NoBrowser
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("SystemCheck", "KnowledgeGraph", "MissionControl", "Validate", "Full")]
    [string]$Action = "Full",

    [switch]$AutoFix,
    [int]$Port = 8900,
    [int]$CheckerPort = 8901,
    [switch]$NoBrowser,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/../_init.ps1"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║       Roboflow 3D Pipeline — Bootstrap Complete           ║" -ForegroundColor Magenta
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

$roboflowRoot = Join-Path $projectRoot ".roboflow"
$checkSystem  = Join-Path $roboflowRoot "check_system.py"
$buildGraph   = Join-Path $roboflowRoot "build_knowledge_graph.py"

# Activate venv if available
$venvActivate = Join-Path $roboflowRoot ".venv/Scripts/Activate.ps1"
if (Test-Path $venvActivate) {
    . $venvActivate
}

$exitCode = 0

# ── SystemCheck ───────────────────────────────────────────────────────
if ($Action -in "SystemCheck", "Full") {
    Write-Host "━━━ System Check ━━━" -ForegroundColor Yellow

    if (-not (Test-Path $checkSystem)) {
        Write-Warning "check_system.py not found at $checkSystem"
        $exitCode = 2
    } elseif ($DryRun) {
        Write-Host "  [DRY RUN] Would run: python check_system.py$(if ($AutoFix) {' --auto-fix'})" -ForegroundColor DarkGray
    } else {
        $pyArgs = @()
        if ($AutoFix) { $pyArgs += "--auto-fix" }

        Push-Location $roboflowRoot
        & python $checkSystem @pyArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "System check reported issues (exit code $LASTEXITCODE)"
            $exitCode = 2
        }
        Pop-Location
    }
    Write-Host ""
}

# ── KnowledgeGraph ────────────────────────────────────────────────────
if ($Action -in "KnowledgeGraph", "Full") {
    Write-Host "━━━ Knowledge Graph ━━━" -ForegroundColor Yellow

    if (-not (Test-Path $buildGraph)) {
        Write-Warning "build_knowledge_graph.py not found at $buildGraph"
        $exitCode = 2
    } elseif ($DryRun) {
        Write-Host "  [DRY RUN] Would run: python build_knowledge_graph.py" -ForegroundColor DarkGray
    } else {
        Push-Location $roboflowRoot
        & python $buildGraph
        Pop-Location

        # Report results
        $graphData = Join-Path $roboflowRoot "explorer/graph_data.json"
        if (Test-Path $graphData) {
            $g = Get-Content $graphData -Raw | ConvertFrom-Json
            $nodeCount = $g.nodes.Count
            $edgeCount = $g.edges.Count
            Write-Host "  ✅ Knowledge graph: $nodeCount nodes, $edgeCount edges" -ForegroundColor Green
        }
    }
    Write-Host ""
}

# ── Validate ──────────────────────────────────────────────────────────
if ($Action -in "Validate", "Full") {
    Write-Host "━━━ Validation ━━━" -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would validate custom blocks and pipeline" -ForegroundColor DarkGray
    } else {
        # Test custom block imports
        Push-Location $roboflowRoot
        $blockTest = @"
import sys
try:
    from custom_blocks.asset_quality_gate import AssetQualityGateBlockV1
    from custom_blocks.asset_metadata_builder import AssetMetadataBuilderBlockV1
    print('BLOCKS_OK')
except Exception as e:
    print(f'BLOCKS_FAIL: {e}')
    sys.exit(1)
"@
        $result = & python -c $blockTest 2>&1
        if ($result -match "BLOCKS_OK") {
            Write-Host "  ✅ Custom blocks: OK" -ForegroundColor Green
        } else {
            Write-Warning "  Custom blocks: $result"
            $exitCode = 2
        }

        # Test system checker JSON output
        $sysResult = & python $checkSystem --json 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($sysResult) {
            $checks = @("python", "docker", "gpu", "disk", "packages")
            foreach ($check in $checks) {
                $ok = $sysResult.$check.ok
                $icon = if ($ok) { "✅" } else { "⚠️" }
                Write-Host "  $icon $check" -ForegroundColor $(if ($ok) { "Green" } else { "Yellow" })
            }
        }
        Pop-Location
    }
    Write-Host ""
}

# ── MissionControl ────────────────────────────────────────────────────
if ($Action -in "MissionControl", "Full") {
    Write-Host "━━━ Mission Control ━━━" -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would start system checker API on port $CheckerPort" -ForegroundColor DarkGray
        Write-Host "  [DRY RUN] Would start HTTP server on port $Port" -ForegroundColor DarkGray
    } else {
        # Start checker API in background
        $checkerRunning = $false
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$CheckerPort/api/check" -TimeoutSec 3 -ErrorAction Stop
            $checkerRunning = $true
            Write-Host "  ⏭ Checker API already running on port $CheckerPort" -ForegroundColor Gray
        } catch {
            Write-Host "  Starting system checker API on port $CheckerPort…" -ForegroundColor Gray
            Start-Process -NoNewWindow -FilePath python -ArgumentList "$checkSystem --serve --port=$CheckerPort" -WorkingDirectory $roboflowRoot
            Start-Sleep -Seconds 2
            Write-Host "  ✅ Checker API started" -ForegroundColor Green
        }

        # Start HTTP server in background
        $httpRunning = $false
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -TimeoutSec 3 -ErrorAction Stop
            $httpRunning = $true
            Write-Host "  ⏭ HTTP server already running on port $Port" -ForegroundColor Gray
        } catch {
            Write-Host "  Starting HTTP server on port $Port…" -ForegroundColor Gray
            Start-Process -NoNewWindow -FilePath python -ArgumentList "-m http.server $Port" -WorkingDirectory $roboflowRoot
            Start-Sleep -Seconds 2
            Write-Host "  ✅ HTTP server started" -ForegroundColor Green
        }

        # Open browser
        $url = "http://localhost:$Port/command_center/app.html"
        if (-not $NoBrowser) {
            Write-Host "  🌐 Opening Mission Control: $url" -ForegroundColor Cyan
            Start-Process $url
        } else {
            Write-Host "  🌐 Mission Control available at: $url" -ForegroundColor Cyan
        }
    }
    Write-Host ""
}

# ── Final Summary ─────────────────────────────────────────────────────
$docCount = (Get-ChildItem -Path $roboflowRoot -Filter "rbflow-*.txt" -ErrorAction SilentlyContinue).Count
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor $(if ($exitCode -eq 0) { "Green" } else { "Yellow" })
Write-Host "║       Bootstrap Complete — $docCount docs harvested              ║" -ForegroundColor $(if ($exitCode -eq 0) { "Green" } else { "Yellow" })
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor $(if ($exitCode -eq 0) { "Green" } else { "Yellow" })

exit $exitCode
