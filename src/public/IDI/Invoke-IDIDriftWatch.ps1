#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Continuous drift detection for IDI-managed infrastructure.

.DESCRIPTION
    Invoke-IDIDriftWatch monitors the gap between declared intent and live infrastructure.
    It periodically runs the IDI discovery→diff pipeline and raises alerts when drift
    exceeds configured thresholds.

    Modes:
    - Once: Run a single drift scan and return results
    - Watch: Continuous monitoring with configurable interval
    - Report: Generate a drift report for a specific time window

    Drift severity levels:
    - None:     Infrastructure matches intent exactly
    - Low:      Cosmetic differences (tags, descriptions)
    - Medium:   Config drift (memory, CPU within acceptable range)
    - High:     Structural drift (missing resources, wrong regions)
    - Critical: Security drift (public exposure, missing encryption, orphan resources)

    Integrates with:
    - Compare-IntentVsDiscovery for diff computation
    - Invoke-CloudDiscovery for live state capture
    - ConvertTo-IntentGraph for intent state extraction
    - Flux event bus for alerting (idi.drift.detected)
    - Chronicle for historical drift logging

.PARAMETER IntentStatement
    The original infrastructure intent (natural language).

.PARAMETER IntentGraph
    Pre-computed IntentGraph. If omitted, IntentStatement is required.

.PARAMETER Provider
    Cloud provider to scan: aws, docker, kubernetes, azure, gcp, multi.

.PARAMETER Mode
    Once (single scan), Watch (continuous), Report (time-window analysis). Default: Once.

.PARAMETER IntervalSeconds
    Seconds between scans in Watch mode. Default: 300 (5 minutes).

.PARAMETER MaxScans
    Maximum number of scans in Watch mode (0 = unlimited). Default: 0.

.PARAMETER SeverityThreshold
    Minimum drift severity to alert on. Default: medium.

.PARAMETER GenesisUrl
    Genesis backend URL. Default: http://localhost:8001.

.EXAMPLE
    Invoke-IDIDriftWatch -IntentStatement "3 t3.large EC2 in us-east-1 for prod API" -Provider aws
    Invoke-IDIDriftWatch -IntentGraph $graph -Provider docker -Mode Watch -IntervalSeconds 60

.NOTES
    Part of AitherZero IDI (Intent-Driven Infrastructure) module.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Invoke-IDIDriftWatch {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ParameterSetName = 'Statement')]
        [string]$IntentStatement,

        [Parameter(ParameterSetName = 'Graph')]
        [PSCustomObject]$IntentGraph,

        [ValidateSet('aws', 'docker', 'kubernetes', 'azure', 'gcp', 'multi')]
        [string]$Provider = 'multi',

        [ValidateSet('Once', 'Watch', 'Report')]
        [string]$Mode = 'Once',

        [ValidateRange(10, 86400)]
        [int]$IntervalSeconds = 300,

        [int]$MaxScans = 0,

        [ValidateSet('none', 'low', 'medium', 'high', 'critical')]
        [string]$SeverityThreshold = 'medium',

        [string]$GenesisUrl = 'http://localhost:8001'
    )

    $WatchId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $SeverityOrder = @{ 'none' = 0; 'low' = 1; 'medium' = 2; 'high' = 3; 'critical' = 4 }

    Write-Host "`n  👁️  IDI Drift Watch ($WatchId)" -ForegroundColor Cyan
    Write-Host "  Mode: $Mode | Provider: $Provider | Threshold: $SeverityThreshold" -ForegroundColor Gray

    # ── Resolve IntentGraph ───────────────────────────────────────────
    if (-not $IntentGraph -and $IntentStatement) {
        try {
            $IntentGraph = ConvertTo-IntentGraph -Intent $IntentStatement
        } catch {
            Write-Host "  ⚠️  IntentGraph extraction failed, drift scan may be incomplete" -ForegroundColor DarkYellow
        }
    }

    if (-not $IntentGraph -and -not $IntentStatement) {
        throw "Either -IntentStatement or -IntentGraph is required"
    }

    # ── Execute mode ──────────────────────────────────────────────────
    switch ($Mode) {
        'Once'   { return Invoke-SingleScan -WatchId $WatchId -IntentGraph $IntentGraph -Provider $Provider -SeverityThreshold $SeverityThreshold -SeverityOrder $SeverityOrder -GenesisUrl $GenesisUrl }
        'Watch'  { return Invoke-ContinuousWatch -WatchId $WatchId -IntentGraph $IntentGraph -Provider $Provider -SeverityThreshold $SeverityThreshold -SeverityOrder $SeverityOrder -IntervalSeconds $IntervalSeconds -MaxScans $MaxScans -GenesisUrl $GenesisUrl }
        'Report' { return Get-DriftReport -WatchId $WatchId -IntentGraph $IntentGraph -Provider $Provider -SeverityOrder $SeverityOrder -GenesisUrl $GenesisUrl }
    }
}

# ── Single scan ──────────────────────────────────────────────────────────
function Invoke-SingleScan {
    param(
        [string]$WatchId,
        [PSCustomObject]$IntentGraph,
        [string]$Provider,
        [string]$SeverityThreshold,
        [hashtable]$SeverityOrder,
        [string]$GenesisUrl
    )

    $scanStart = [DateTime]::UtcNow
    Write-Host "  [SCAN] Starting drift scan..." -ForegroundColor Yellow

    # Step 1: Discover live state
    $Snapshot = $null
    try {
        $Snapshot = Invoke-CloudDiscovery -Provider $Provider
        $liveCount = ($Snapshot.resources | Measure-Object).Count
        Write-Host "  [SCAN] Discovered $liveCount live resources" -ForegroundColor Gray
    } catch {
        Write-Host "  ⚠️  Discovery failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        $Snapshot = [PSCustomObject]@{ resources = @() }
    }

    # Step 2: Compute diff
    $ChangeSet = $null
    try {
        $ChangeSet = Compare-IntentVsDiscovery -IntentGraph $IntentGraph -DiscoverySnapshot $Snapshot
    } catch {
        Write-Host "  ⚠️  Diff failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return [PSCustomObject]@{
            watch_id = $WatchId
            status   = 'error'
            error    = $_.Exception.Message
            scanned_at = $scanStart.ToString('o')
        }
    }

    # Step 3: Classify drift
    $drifts = @()
    foreach ($change in ($ChangeSet.changes | Where-Object { $_.action -ne 'no_op' })) {
        $severity = $change.drift_severity ?? 'medium'
        $resource = $change.intent_resource ?? $change.actual_resource

        $drifts += [PSCustomObject]@{
            resource_name   = $resource.name ?? $resource.type
            resource_type   = $resource.type
            action          = $change.action
            severity        = $severity
            severity_score  = $SeverityOrder[$severity] ?? 2
            drift_details   = $change.drift_details ?? @()
            risk_level      = $change.risk_level ?? 'medium'
            cost_delta      = $change.cost_delta ?? 0
        }
    }

    # Step 4: Filter by threshold
    $thresholdScore = $SeverityOrder[$SeverityThreshold] ?? 2
    $alertDrifts = $drifts | Where-Object { $_.severity_score -ge $thresholdScore }
    $maxSeverity = ($drifts | Sort-Object severity_score -Descending | Select-Object -First 1).severity ?? 'none'

    # Step 5: Format output
    $scanDuration = ([DateTime]::UtcNow - $scanStart).TotalMilliseconds

    if ($alertDrifts.Count -eq 0) {
        Write-Host "  ✅ No drift above threshold ($SeverityThreshold)" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  $($alertDrifts.Count) drift(s) detected:" -ForegroundColor Yellow
        foreach ($d in $alertDrifts) {
            $icon = switch ($d.severity) {
                'critical' { '🔴' }
                'high'     { '🟠' }
                'medium'   { '🟡' }
                'low'      { '🔵' }
                default    { '⚪' }
            }
            Write-Host "        $icon [$($d.severity.ToUpper())] $($d.action) $($d.resource_name) ($($d.resource_type))" -ForegroundColor $(
                switch ($d.severity) { 'critical' { 'Red' } 'high' { 'DarkYellow' } 'medium' { 'Yellow' } default { 'Gray' } }
            )
        }
    }

    # Step 6: Emit drift event
    if ($alertDrifts.Count -gt 0) {
        try {
            $event = @{
                event  = 'idi.drift.detected'
                source = 'aitherzero-idi-drift'
                data   = @{
                    watch_id       = $WatchId
                    drift_count    = $alertDrifts.Count
                    max_severity   = $maxSeverity
                    environment    = $IntentGraph.environment ?? 'unknown'
                }
            } | ConvertTo-Json -Depth 5

            Invoke-RestMethod -Uri "$GenesisUrl/api/v1/flux/emit" `
                -Method POST -Body $event -ContentType 'application/json' `
                -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-Verbose "Drift event emission failed (non-fatal)"
        }
    }

    return [PSCustomObject]@{
        watch_id       = $WatchId
        status         = if ($alertDrifts.Count -gt 0) { 'drift-detected' } else { 'in-sync' }
        scanned_at     = $scanStart.ToString('o')
        duration_ms    = $scanDuration
        max_severity   = $maxSeverity
        drift_count    = $drifts.Count
        alert_count    = $alertDrifts.Count
        threshold      = $SeverityThreshold
        drifts         = $drifts
        alerts         = $alertDrifts
        changeset      = $ChangeSet
        summary        = [PSCustomObject]@{
            creates    = ($ChangeSet.summary.creates ?? 0)
            updates    = ($ChangeSet.summary.updates ?? 0)
            destroys   = ($ChangeSet.summary.destroys ?? 0)
            no_ops     = ($ChangeSet.summary.no_ops ?? 0)
            cost_delta = ($ChangeSet.summary.cost_delta ?? 0)
        }
    }
}

# ── Continuous watch ─────────────────────────────────────────────────────
function Invoke-ContinuousWatch {
    param(
        [string]$WatchId,
        [PSCustomObject]$IntentGraph,
        [string]$Provider,
        [string]$SeverityThreshold,
        [hashtable]$SeverityOrder,
        [int]$IntervalSeconds,
        [int]$MaxScans,
        [string]$GenesisUrl
    )

    $scanHistory = @()
    $scanNum = 0

    Write-Host "  [WATCH] Starting continuous drift monitoring (Ctrl+C to stop)" -ForegroundColor Yellow
    Write-Host "  [WATCH] Interval: ${IntervalSeconds}s | Max scans: $(if ($MaxScans -eq 0) { '∞' } else { $MaxScans })" -ForegroundColor Gray

    try {
        while ($true) {
            $scanNum++
            if ($MaxScans -gt 0 -and $scanNum -gt $MaxScans) {
                Write-Host "`n  [WATCH] Max scans ($MaxScans) reached. Stopping." -ForegroundColor Cyan
                break
            }

            Write-Host "`n  ─── Scan #$scanNum at $([DateTime]::UtcNow.ToString('HH:mm:ss')) ───" -ForegroundColor DarkGray

            $result = Invoke-SingleScan -WatchId $WatchId -IntentGraph $IntentGraph `
                -Provider $Provider -SeverityThreshold $SeverityThreshold `
                -SeverityOrder $SeverityOrder -GenesisUrl $GenesisUrl

            $result | Add-Member -NotePropertyName 'scan_number' -NotePropertyValue $scanNum
            $scanHistory += $result

            # Detect worsening drift
            if ($scanHistory.Count -ge 2) {
                $prev = $scanHistory[-2]
                $curr = $scanHistory[-1]
                if ($curr.drift_count -gt $prev.drift_count) {
                    Write-Host "  📈 Drift INCREASING: $($prev.drift_count) → $($curr.drift_count)" -ForegroundColor Red
                } elseif ($curr.drift_count -lt $prev.drift_count) {
                    Write-Host "  📉 Drift DECREASING: $($prev.drift_count) → $($curr.drift_count)" -ForegroundColor Green
                }
            }

            if ($MaxScans -eq 0 -or $scanNum -lt $MaxScans) {
                Write-Host "  [WATCH] Next scan in ${IntervalSeconds}s..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $IntervalSeconds
            }
        }
    } catch {
        # Ctrl+C or other interrupt
        Write-Host "`n  [WATCH] Stopped." -ForegroundColor Cyan
    }

    return [PSCustomObject]@{
        watch_id     = $WatchId
        mode         = 'watch'
        total_scans  = $scanNum
        history      = $scanHistory
        trend        = Get-DriftTrend -History $scanHistory
        stopped_at   = [DateTime]::UtcNow.ToString('o')
    }
}

# ── Drift report ─────────────────────────────────────────────────────────
function Get-DriftReport {
    param(
        [string]$WatchId,
        [PSCustomObject]$IntentGraph,
        [string]$Provider,
        [hashtable]$SeverityOrder,
        [string]$GenesisUrl
    )

    Write-Host "  [REPORT] Generating drift report..." -ForegroundColor Yellow

    # Run a fresh scan for current state
    $current = Invoke-SingleScan -WatchId $WatchId -IntentGraph $IntentGraph `
        -Provider $Provider -SeverityThreshold 'none' `
        -SeverityOrder $SeverityOrder -GenesisUrl $GenesisUrl

    # Build report
    $report = @"
╔══════════════════════════════════════════════════════════════╗
║              IDI DRIFT REPORT — $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm')) UTC             ║
╠══════════════════════════════════════════════════════════════╣
║  Watch ID:     $WatchId                              ║
║  Provider:     $Provider                                     ║
║  Status:       $($current.status)                            ║
║  Drift Count:  $($current.drift_count)                       ║
║  Max Severity: $($current.max_severity)                      ║
╠══════════════════════════════════════════════════════════════╣
║  SUMMARY                                                     ║
║  Creates needed:    $($current.summary.creates)              ║
║  Updates needed:    $($current.summary.updates)              ║
║  Destroys needed:   $($current.summary.destroys)             ║
║  In sync:           $($current.summary.no_ops)               ║
║  Est. cost delta:   `$$($current.summary.cost_delta)/mo      ║
╚══════════════════════════════════════════════════════════════╝
"@
    Write-Host $report -ForegroundColor Cyan

    if ($current.drifts.Count -gt 0) {
        Write-Host "`n  DRIFT DETAILS:" -ForegroundColor Yellow
        foreach ($d in ($current.drifts | Sort-Object severity_score -Descending)) {
            Write-Host "    [$($d.severity.ToUpper().PadRight(8))] $($d.action.PadRight(8)) $($d.resource_name) ($($d.resource_type)) — cost: `$$($d.cost_delta)/mo" -ForegroundColor $(
                switch ($d.severity) { 'critical' { 'Red' } 'high' { 'DarkYellow' } 'medium' { 'Yellow' } default { 'Gray' } }
            )
        }
    }

    return [PSCustomObject]@{
        watch_id   = $WatchId
        mode       = 'report'
        generated  = [DateTime]::UtcNow.ToString('o')
        scan       = $current
        text       = $report
    }
}

# ── Trend analysis helper ────────────────────────────────────────────────
function Get-DriftTrend {
    param([array]$History)

    if ($History.Count -lt 2) { return 'insufficient-data' }

    $first = $History[0].drift_count
    $last = $History[-1].drift_count

    if ($last -gt $first) { return 'worsening' }
    if ($last -lt $first) { return 'improving' }
    return 'stable'
}
