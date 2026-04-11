<#
.SYNOPSIS
    Archives older roadmap session logs to training data for AitherTrainer.

.DESCRIPTION
    Implements roadmap pruning rules from Section 59.2:
    - Target: ~5,000 lines (max 8,000)
    - Session logs: Max 500 lines, keep last 15-20 sessions
    - Exports archived sessions to JSONL for fine-tuning

.PARAMETER KeepRecentSessions
    Number of recent sessions to keep. Default: 15

.PARAMETER DryRun
    Preview changes without modifying files.

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    ./0890_Archive-RoadmapContent.ps1 -DryRun
    ./0890_Archive-RoadmapContent.ps1 -KeepRecentSessions 15

.NOTES
    Part of AitherChronicle system (Section 59)
    Author: Aitherium
#>

[CmdletBinding()]
param(
    [int]$KeepRecentSessions = 15,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

$AitherZeroRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$RoadmapPath = Join-Path $AitherZeroRoot "AitherOS/ROADMAP.md"
$ChronicleDir = Join-Path $AitherZeroRoot "AitherOS/training-data/chronicle"
$TrainingDataDir = Join-Path $AitherZeroRoot "AitherOS/training-data/aither-7b/conversations"

# Ensure directories exist
@($ChronicleDir, $TrainingDataDir, "$ChronicleDir/sessions") | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

function Get-RoadmapSessions {
    <#
    .SYNOPSIS
        Extract session entries from roadmap.
    #>
    param([string]$Content)
    
    $sessions = @()
    $pattern = '(?ms)^### Session: (.+?)$(.+?)(?=^### Session:|^## |^---\s*$|\z)'
    
    $matches = [regex]::Matches($Content, $pattern, 'Multiline')
    
    foreach ($match in $matches) {
        $header = $match.Groups[1].Value.Trim()
        $body = $match.Groups[2].Value.Trim()
        
        # Extract date from header (e.g., "2025-11-30 (async-opus) - Title")
        $dateMatch = [regex]::Match($header, '(\d{4}-\d{2}-\d{2})')
        $date = if ($dateMatch.Success) { $dateMatch.Groups[1].Value } else { "unknown" }
        
        # Extract title
        $titleMatch = [regex]::Match($header, '\)\s*-\s*(.+)$')
        $title = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { $header }
        
        $sessions += [PSCustomObject]@{
            FullMatch = $match.Value
            Header = $header
            Body = $body
            Date = $date
            Title = $title
            LineCount = ($match.Value -split "`n").Count
            StartIndex = $match.Index
            Length = $match.Length
        }
    }
    
    return $sessions | Sort-Object { [datetime]::Parse($_.Date) } -ErrorAction SilentlyContinue
}

function Convert-SessionToTrainingData {
    <#
    .SYNOPSIS
        Convert a session entry to JSONL training data format.
    #>
    param(
        [PSCustomObject]$Session,
        [string]$OutputPath
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $id = "chronicle-session-$($Session.Date)-$(Get-Random -Maximum 9999)"
    
    # Extract completed items from session body
    $completed = @()
    $bodyLines = $Session.Body -split "`n"
    foreach ($line in $bodyLines) {
        if ($line -match '^\s*-\s*✅\s*(.+)') {
            $completed += $Matches[1].Trim()
        }
    }
    
    # Create training example
    $trainingExample = @{
        id = $id
        type = "session_log"
        source = "roadmap_chronicle"
        messages = @(
            @{
                role = "system"
                content = "You are Aither, an AI coding agent working on the AitherZero ecosystem."
            },
            @{
                role = "user"
                content = "Session focus: $($Session.Title)"
            },
            @{
                role = "assistant"
                content = "Session completed the following:`n`n$($completed -join "`n- ")`n`nFull session log:`n$($Session.Body)"
            }
        )
        metadata = @{
            date = $Session.Date
            title = $Session.Title
            quality_score = 0.8  # Chronicle data is high quality
            domain = "aitherzero"
            tags = @("session-log", "chronicle", "development")
            archived_at = $timestamp
            line_count = $Session.LineCount
        }
    }
    
    # Append to JSONL file
    $jsonl = $trainingExample | ConvertTo-Json -Depth 10 -Compress
    $outputFile = Join-Path $OutputPath "chronicle-sessions.jsonl"
    
    if (-not $DryRun) {
        Add-Content -Path $outputFile -Value $jsonl -Encoding UTF8
    }
    
    return $trainingExample
}

function Export-SessionToArchive {
    <#
    .SYNOPSIS
        Export session to markdown archive file.
    #>
    param(
        [PSCustomObject]$Session,
        [string]$OutputPath
    )
    
    $archiveFile = Join-Path $OutputPath "sessions/session-$($Session.Date)-$([System.IO.Path]::GetRandomFileName().Substring(0,6)).md"
    
    $content = @"
# Session: $($Session.Header)

**Archived:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Original Line Count:** $($Session.LineCount)

---

$($Session.Body)
"@
    
    if (-not $DryRun) {
        Set-Content -Path $archiveFile -Value $content -Encoding UTF8
    }
    
    return $archiveFile
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  AITHER CHRONICLE - Roadmap Archival System" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

# Check roadmap exists
if (-not (Test-Path $RoadmapPath)) {
    Write-Error "Roadmap not found: $RoadmapPath"
    exit 1
}

# Read roadmap
$roadmapContent = Get-Content $RoadmapPath -Raw -Encoding UTF8
$totalLines = ($roadmapContent -split "`n").Count

Write-Host "`nRoadmap Stats:" -ForegroundColor Yellow
Write-Host "  Path: $RoadmapPath"
Write-Host "  Total Lines: $totalLines"
Write-Host "  Target Max: 8,000 lines"

# Extract sessions
$sessions = Get-RoadmapSessions -Content $roadmapContent
$sessionCount = $sessions.Count

Write-Host "`nSession Log Stats:" -ForegroundColor Yellow
Write-Host "  Total Sessions: $sessionCount"
Write-Host "  Keep Recent: $KeepRecentSessions"

if ($sessionCount -le $KeepRecentSessions) {
    Write-Host "`n✅ No archival needed. Session count ($sessionCount) <= Keep threshold ($KeepRecentSessions)" -ForegroundColor Green
    exit 0
}

# Calculate sessions to archive
$sessionsToArchive = $sessions | Select-Object -First ($sessionCount - $KeepRecentSessions)
$sessionsToKeep = $sessions | Select-Object -Last $KeepRecentSessions

$archiveLineCount = ($sessionsToArchive | Measure-Object -Property LineCount -Sum).Sum

Write-Host "`nArchival Plan:" -ForegroundColor Yellow
Write-Host "  Sessions to Archive: $($sessionsToArchive.Count)"
Write-Host "  Sessions to Keep: $($sessionsToKeep.Count)"
Write-Host "  Lines to Remove: ~$archiveLineCount"
Write-Host "  Estimated New Total: $($totalLines - $archiveLineCount) lines"

# List sessions to archive
Write-Host "`nSessions to Archive:" -ForegroundColor Magenta
foreach ($session in $sessionsToArchive) {
    Write-Host "  - $($session.Date): $($session.Title) ($($session.LineCount) lines)"
}

# Confirm
if (-not $Force -and -not $DryRun) {
    $confirm = Read-Host "`nProceed with archival? (y/N)"
    if ($confirm -ne 'y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

if ($DryRun) {
    Write-Host "`n[DRY RUN] Would archive $($sessionsToArchive.Count) sessions" -ForegroundColor Cyan
}

# Process each session to archive
$archived = 0
foreach ($session in $sessionsToArchive) {
    Write-Host "`nArchiving: $($session.Date) - $($session.Title)" -ForegroundColor Yellow
    
    # Export to markdown archive
    $archiveFile = Export-SessionToArchive -Session $session -OutputPath $ChronicleDir
    Write-Host "  → Archive: $archiveFile"
    
    # Convert to training data
    $trainingData = Convert-SessionToTrainingData -Session $session -OutputPath $TrainingDataDir
    Write-Host "  → Training: $($trainingData.id)"
    
    $archived++
}

# Remove archived sessions from roadmap
if (-not $DryRun) {
    Write-Host "`nUpdating roadmap..." -ForegroundColor Yellow
    
    $newContent = $roadmapContent
    foreach ($session in $sessionsToArchive) {
        # Remove the full session match including trailing separator
        $newContent = $newContent.Replace($session.FullMatch, "")
    }
    
    # Clean up multiple consecutive blank lines
    $newContent = $newContent -replace "(`n\s*){3,}", "`n`n"
    
    Set-Content -Path $RoadmapPath -Value $newContent -Encoding UTF8
    
    $newLines = ($newContent -split "`n").Count
    Write-Host "  New line count: $newLines (was $totalLines)"
}

# Summary
Write-Host "`n════════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ARCHIVAL COMPLETE" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Sessions Archived: $archived"
Write-Host "  Training Data: $TrainingDataDir/chronicle-sessions.jsonl"
Write-Host "  Archives: $ChronicleDir/sessions/"
if ($DryRun) {
    Write-Host "`n  [DRY RUN - No files modified]" -ForegroundColor Cyan
}

