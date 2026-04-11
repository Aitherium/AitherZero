<#
.SYNOPSIS
    Sync ROADMAP items to/from GitHub via AitherAtlas + AitherFlow.

.DESCRIPTION
    Uses the AitherAtlas /github/sync/roadmap endpoint to synchronize
    roadmap items with GitHub Issues, Milestones, and Project Boards.

    Atlas (PM) reads ACTIVE_ROADMAP.md and/or ROADMAP.md, then delegates
    to AitherFlow for actual GitHub API operations.

    Modes:
    - roadmap_to_github: Push roadmap items as GitHub issues
    - github_to_roadmap: Pull GitHub issue state into roadmap
    - bidirectional: Full two-way sync

.PARAMETER Direction
    Sync direction: roadmap_to_github, github_to_roadmap, bidirectional

.PARAMETER Scope
    What to sync: active (sprint items), full (entire ROADMAP.md), section

.PARAMETER SectionFilter
    Section name filter when Scope=section (e.g. "AitherSecrets")

.PARAMETER DryRun
    Preview changes without applying them.

.PARAMETER CreateMilestones
    Create GitHub milestones from roadmap sections (default: true).

.PARAMETER LabelPrefix
    Prefix for auto-created labels (default: "roadmap:")

.PARAMETER ShowOutput
    Display verbose output during execution.

.PARAMETER StatusOnly
    Just show current sync status without making changes.

.PARAMETER Report
    Generate a sprint/release/health report after sync.

.PARAMETER ReportType
    Report type: sprint, release, health, burndown, velocity

.EXAMPLE
    .\0897_Import-RoadmapToGitHub.ps1 -DryRun -ShowOutput
    Preview what would be synced to GitHub.

.EXAMPLE
    .\0897_Import-RoadmapToGitHub.ps1 -Direction roadmap_to_github -Scope active
    Sync current sprint items to GitHub.

.EXAMPLE
    .\0897_Import-RoadmapToGitHub.ps1 -StatusOnly
    Show sync status between roadmap and GitHub.

.EXAMPLE
    .\0897_Import-RoadmapToGitHub.ps1 -Report -ReportType sprint
    Generate a sprint report from GitHub + roadmap data.
#>

[CmdletBinding()]
param(
    [ValidateSet('roadmap_to_github', 'github_to_roadmap', 'bidirectional')]
    [string]$Direction = 'roadmap_to_github',

    [ValidateSet('active', 'full', 'section')]
    [string]$Scope = 'active',

    [string]$SectionFilter,

    [switch]$DryRun,
    [switch]$CreateMilestones,
    [switch]$ShowOutput,
    [switch]$StatusOnly,
    [switch]$Report,

    [ValidateSet('sprint', 'release', 'health', 'burndown', 'velocity')]
    [string]$ReportType = 'sprint',

    [string]$LabelPrefix = 'roadmap:'
)

# Initialize AitherZero
. "$PSScriptRoot/../_init.ps1"

$ErrorActionPreference = 'Stop'

#region Configuration
$AtlasPort = 8778
$AtlasUrl = "http://localhost:$AtlasPort"

# Check if Atlas is running
function Test-AtlasHealth {
    try {
        $response = Invoke-RestMethod -Uri "$AtlasUrl/health" -Method Get -TimeoutSec 5
        return $response.status -eq 'healthy'
    }
    catch {
        return $false
    }
}

function Write-Status {
    param([string]$Message, [string]$Level = 'Info')
    if ($ShowOutput -or $Level -eq 'Error') {
        $prefix = switch ($Level) {
            'Info'    { '[INFO]' }
            'Success' { '[OK]' }
            'Warning' { '[WARN]' }
            'Error'   { '[ERROR]' }
        }
        Write-Host "$prefix $Message" -ForegroundColor $(
            switch ($Level) {
                'Info'    { 'Cyan' }
                'Success' { 'Green' }
                'Warning' { 'Yellow' }
                'Error'   { 'Red' }
            }
        )
    }
}
#endregion

#region Main Logic

Write-Status "AitherOS Roadmap ↔ GitHub Sync" -Level Info
Write-Status "Atlas URL: $AtlasUrl" -Level Info

# Health check
if (-not (Test-AtlasHealth)) {
    Write-Status "Atlas (port $AtlasPort) is not running. Start it first:" -Level Error
    Write-Status "  docker compose -f docker-compose.aitheros.yml up -d aither-atlas" -Level Error
    exit 1
}

Write-Status "Atlas is healthy" -Level Success

# Status-only mode
if ($StatusOnly) {
    Write-Status "Fetching sync status..." -Level Info
    try {
        $status = Invoke-RestMethod -Uri "$AtlasUrl/github/sync/status" -Method Get -TimeoutSec 30
        $data = $status.data

        Write-Host ""
        Write-Host "=== Roadmap ↔ GitHub Sync Status ===" -ForegroundColor White
        Write-Host ""
        Write-Host "Synced Items: $($data.synced.count)" -ForegroundColor Green
        foreach ($item in $data.synced.items) {
            Write-Host "  ✅ [$($item.id)] $($item.title) ($($item.bucket))" -ForegroundColor DarkGreen
        }

        Write-Host ""
        Write-Host "Roadmap Only (not on GitHub): $($data.roadmap_only.count)" -ForegroundColor Yellow
        foreach ($item in $data.roadmap_only.items) {
            Write-Host "  📋 [$($item.id)] $($item.title) ($($item.bucket))" -ForegroundColor DarkYellow
        }

        Write-Host ""
        Write-Host "GitHub Only (not in roadmap): $($data.github_only.count)" -ForegroundColor Cyan
        foreach ($item in $data.github_only.items | Select-Object -First 10) {
            Write-Host "  🐙 #$($item.number) $($item.title)" -ForegroundColor DarkCyan
        }

        Write-Host ""
        Write-Host "Sync Health: $($data.sync_health)" -ForegroundColor $(
            if ($data.sync_health -eq 'healthy') { 'Green' } else { 'Yellow' }
        )
    }
    catch {
        Write-Status "Failed to get sync status: $_" -Level Error
    }
    exit 0
}

# Report mode
if ($Report) {
    Write-Status "Generating $ReportType report..." -Level Info
    try {
        $body = @{
            report_type      = $ReportType
            include_prs      = $true
            include_issues   = $true
            include_actions  = $true
            date_range_days  = 14
            format           = 'markdown'
        } | ConvertTo-Json

        $report = Invoke-RestMethod -Uri "$AtlasUrl/github/report" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 60

        $data = $report.data

        if ($data.markdown) {
            Write-Host ""
            Write-Host $data.markdown
        }
        else {
            $data | ConvertTo-Json -Depth 5 | Write-Host
        }
    }
    catch {
        Write-Status "Failed to generate report: $_" -Level Error
    }
    exit 0
}

# Sync mode
Write-Status "Starting sync: $Direction (scope: $Scope)" -Level Info
if ($DryRun) {
    Write-Status "DRY RUN - No changes will be made" -Level Warning
}

try {
    $body = @{
        direction        = $Direction
        scope            = $Scope
        dry_run          = [bool]$DryRun
        create_milestone = [bool]$CreateMilestones
        label_prefix     = $LabelPrefix
    }

    if ($SectionFilter) {
        $body.section_filter = $SectionFilter
    }

    $jsonBody = $body | ConvertTo-Json

    $result = Invoke-RestMethod -Uri "$AtlasUrl/github/sync/roadmap" -Method Post `
        -ContentType 'application/json' -Body $jsonBody -TimeoutSec 120

    $data = $result.data

    Write-Host ""
    Write-Host "=== Sync Results ===" -ForegroundColor White
    Write-Host ""
    Write-Host "Direction: $($data.direction)" -ForegroundColor Cyan
    Write-Host "Scope: $($data.scope)" -ForegroundColor Cyan
    Write-Host "Dry Run: $($data.dry_run)" -ForegroundColor $(if ($data.dry_run) { 'Yellow' } else { 'Green' })
    Write-Host ""
    Write-Host "Issues Created: $($data.issues_created)" -ForegroundColor Green
    Write-Host "Issues Updated: $($data.issues_updated)" -ForegroundColor Yellow
    Write-Host "Issues Closed: $($data.issues_closed)" -ForegroundColor DarkGray
    Write-Host "Milestones Created: $($data.milestones_created)" -ForegroundColor Blue
    Write-Host "Labels Created: $($data.labels_created)" -ForegroundColor Magenta
    Write-Host "Roadmap Items Updated: $($data.roadmap_items_updated)" -ForegroundColor Cyan
    Write-Host ""

    if ($data.details -and $data.details.Count -gt 0) {
        Write-Host "Details:" -ForegroundColor White
        foreach ($detail in $data.details) {
            $icon = switch ($detail.action) {
                'create' { '➕' }
                'update' { '🔄' }
                'roadmap_update' { '📋' }
                default { '•' }
            }
            Write-Host "  $icon [$($detail.item)] $($detail.title)" -ForegroundColor DarkCyan
            if ($detail.github_number) {
                Write-Host "    → GitHub #$($detail.github_number)" -ForegroundColor DarkGray
            }
        }
    }

    if ($data.errors -and $data.errors.Count -gt 0) {
        Write-Host ""
        Write-Host "Errors:" -ForegroundColor Red
        foreach ($err in $data.errors) {
            Write-Host "  ❌ $err" -ForegroundColor Red
        }
    }

    if ($DryRun -and ($data.issues_created -gt 0 -or $data.issues_updated -gt 0)) {
        Write-Host ""
        Write-Host "To apply these changes, run without -DryRun:" -ForegroundColor Yellow
        Write-Host "  .\0897_Import-RoadmapToGitHub.ps1 -Direction $Direction -Scope $Scope" -ForegroundColor White
    }
}
catch {
    Write-Status "Sync failed: $_" -Level Error
    exit 1
}

#endregion
