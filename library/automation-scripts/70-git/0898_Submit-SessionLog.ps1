<#
.SYNOPSIS
    Automated IDE session logger for AitherOS.

.DESCRIPTION
    Called at the END of every coding session (by any IDE agent) to:
      1. Append a Session Log entry to AitherOS/ROADMAP.md
      2. POST structured session data to Strata (/api/v1/ingest/ide-session)
      3. (Optional) Sync roadmap changes to GitHub Issues via 0897

    This script replaces ALL manual session-end housekeeping.

.PARAMETER Summary
    One-line summary of the session (required).

.PARAMETER IDE
    IDE/tool name (default: auto-detected from $env:TERM_PROGRAM or "unknown").

.PARAMETER FilesModified
    Array of files modified during the session.

.PARAMETER FilesCreated
    Array of files created during the session.

.PARAMETER KeyDecisions
    Array of key decisions made during the session.

.PARAMETER PatternsLearned
    Array of patterns learned during the session.

.PARAMETER Bullets
    Array of markdown bullet points for the ROADMAP.md session log entry.
    Each entry becomes a "- **Label:** Description" line.

.PARAMETER QualityScore
    0.0-1.0 quality score for the session (default: 0.8).

.PARAMETER Outcome
    Session outcome: success, partial, or failed (default: success).

.PARAMETER SyncGitHub
    If set, also runs 0897_Import-RoadmapToGitHub.ps1 after updating ROADMAP.

.PARAMETER DryRun
    If set, prints what would be done without writing anything.

.EXAMPLE
    .\0898_Submit-SessionLog.ps1 -Summary "Built Godot bridge" `
        -Bullets @("**Feature:** WebSocket bridge for Godot", "**Status:** Done") `
        -FilesModified @("AitherPrometheus.py") `
        -FilesCreated @("godot_bridge.py", "godot_exporter.py") `
        -KeyDecisions @("Used WebSocket over HTTP polling") `
        -SyncGitHub
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Summary,

    [string]$IDE = "",

    [string[]]$FilesModified = @(),
    [string[]]$FilesCreated = @(),
    [string[]]$FilesDeleted = @(),
    [string[]]$KeyDecisions = @(),
    [string[]]$PatternsLearned = @(),
    [string[]]$Bullets = @(),

    [ValidateRange(0.0, 1.0)]
    [double]$QualityScore = 0.8,

    [ValidateSet("success", "partial", "failed")]
    [string]$Outcome = "success",

    [switch]$SyncGitHub,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"

# ─── Resolve paths ───────────────────────────────────────────────────

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..\..\..\..")
$RoadmapPath = Join-Path $RepoRoot "AitherOS\ROADMAP.md"
$StrataUrl = "http://localhost:8136/api/v1/ingest/ide-session"

# ─── Auto-detect IDE ─────────────────────────────────────────────────

if (-not $IDE) {
    if ($env:ANTIGRAVITY_SESSION)    { $IDE = "antigravity" }
    elseif ($env:CURSOR_SESSION)     { $IDE = "cursor" }
    elseif ($env:CLAUDE_CODE)        { $IDE = "claude-code" }
    elseif ($env:TERM_PROGRAM -match "vscode") { $IDE = "vscode" }
    else                             { $IDE = "unknown" }
}

# ─── Timestamp ───────────────────────────────────────────────────────

$DateStr = (Get-Date).ToString("yyyy-MM-dd")
$Timestamp = (Get-Date).ToString("o")
$SessionId = [guid]::NewGuid().ToString()

# ─── 1. Update ROADMAP.md ───────────────────────────────────────────

$SessionTitle = "### Session Log $DateStr ($Summary)"

# Build markdown bullets
$BulletLines = @()
foreach ($b in $Bullets) {
    $BulletLines += "- $b"
}
if ($BulletLines.Count -eq 0) {
    # Auto-generate minimal bullets from structured data
    $BulletLines += "- **Summary:** $Summary"
    if ($FilesCreated.Count -gt 0) {
        $fileList = ($FilesCreated | ForEach-Object { Split-Path $_ -Leaf }) -join ", "
        $BulletLines += "- **Created:** ``$fileList``"
    }
    if ($FilesModified.Count -gt 0) {
        $fileList = ($FilesModified | ForEach-Object { Split-Path $_ -Leaf }) -join ", "
        $BulletLines += "- **Modified:** ``$fileList``"
    }
    if ($KeyDecisions.Count -gt 0) {
        $BulletLines += "- **Decisions:** $($KeyDecisions -join '; ')"
    }
    $BulletLines += "- **Status:** $Outcome"
}

$SessionBlock = @($SessionTitle, "") + $BulletLines + @("")

# Find insertion point: after "### Automation Scripts Added This Session" table
if (Test-Path $RoadmapPath) {
    $roadmapContent = Get-Content $RoadmapPath -Raw

    # Insert before the first existing "### Session Log" entry
    $insertMarker = "### Session Log "
    $insertIdx = $roadmapContent.IndexOf($insertMarker)

    if ($insertIdx -gt 0) {
        $newContent = $roadmapContent.Substring(0, $insertIdx) +
                      ($SessionBlock -join "`r`n") + "`r`n" +
                      $roadmapContent.Substring($insertIdx)

        if ($DryRun) {
            Write-Host "[DRY RUN] Would insert session log into ROADMAP.md:" -ForegroundColor Cyan
            $SessionBlock | ForEach-Object { Write-Host "  $_" }
        } else {
            Set-Content -Path $RoadmapPath -Value $newContent -NoNewline
            Write-Host "[OK] Session log appended to ROADMAP.md" -ForegroundColor Green
        }
    } else {
        Write-Host "[WARN] Could not find insertion point in ROADMAP.md — skipping" -ForegroundColor Yellow
    }
} else {
    Write-Host "[WARN] ROADMAP.md not found at $RoadmapPath" -ForegroundColor Yellow
}

# ─── 2. POST to Strata ──────────────────────────────────────────────

$sessionData = @{
    session_id       = $SessionId
    ide              = $IDE
    timestamp        = $Timestamp
    summary          = $Summary
    files_modified   = $FilesModified
    files_created    = $FilesCreated
    files_deleted    = $FilesDeleted
    key_decisions    = $KeyDecisions
    patterns_learned = $PatternsLearned
    quality_score    = $QualityScore
    outcome          = $Outcome
    context_used     = @{
        services_referenced = @()
        docs_referenced     = @("ROADMAP.md", "services.yaml")
        tools_used          = @()
    }
}

$jsonStr = $sessionData | ConvertTo-Json -Depth 5

if ($DryRun) {
    Write-Host "[DRY RUN] Would POST to $StrataUrl`:" -ForegroundColor Cyan
    Write-Host $jsonStr
} else {
    try {
        $response = Invoke-RestMethod -Uri $StrataUrl -Method Post -Body $jsonStr -ContentType "application/json" -TimeoutSec 10
        Write-Host "[OK] Session ingested to Strata (session: $($response.session_id))" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] Strata offline or ingest failed: $_" -ForegroundColor Yellow
        # Fallback: save locally
        $fallbackDir = Join-Path $RepoRoot "AitherOS\Library\Data\ide-sessions\$IDE"
        if (-not (Test-Path $fallbackDir)) { New-Item -Path $fallbackDir -ItemType Directory -Force | Out-Null }
        $fallbackPath = Join-Path $fallbackDir "$DateStr`_$SessionId.json"
        $jsonStr | Out-File -FilePath $fallbackPath -Encoding utf8
        Write-Host "[OK] Session saved locally: $fallbackPath" -ForegroundColor Yellow
    }
}

# ─── 3. (Optional) Sync to GitHub ───────────────────────────────────

if ($SyncGitHub -and -not $DryRun) {
    $syncScript = Join-Path $ScriptDir "0897_Import-RoadmapToGitHub.ps1"
    if (Test-Path $syncScript) {
        Write-Host "[INFO] Syncing roadmap to GitHub..." -ForegroundColor Cyan
        & $syncScript -ShowOutput
    } else {
        Write-Host "[WARN] GitHub sync script not found at $syncScript" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Session logging complete." -ForegroundColor Green
