#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Generate a cleanup/nuke report for orphan and idle cloud resources.

.DESCRIPTION
    Get-IDINukeReport scans live infrastructure to identify resources that are:
    - Orphaned:  Tagged aither:managed but not declared in any active IntentGraph
    - Idle:      Running but underutilized (CPU < 5%, no connections, empty buckets)
    - Stale:     Not modified or accessed in > N days
    - Untagged:  Resources without aither:managed tag (potential shadow IT)

    The report provides:
    - Itemized list of waste with estimated monthly cost per resource
    - Total monthly burn from orphan/idle resources
    - Recommended cleanup actions (safe vs aggressive)
    - One-click nuke command generation for safe resources
    - Risk classification per resource (safe-to-delete, needs-review, do-not-touch)

    Integrates with Invoke-CloudDiscovery for live state and IntentEngine for intent
    validation of discovered resources.

.PARAMETER Provider
    Cloud provider to scan. Default: multi.

.PARAMETER IntentGraphs
    Array of IntentGraphs representing all active intents. Resources not matched
    to any IntentGraph are candidates for cleanup.

.PARAMETER StaleThresholdDays
    Days since last access/modification to consider a resource stale. Default: 30.

.PARAMETER IdleCPUThreshold
    CPU percentage below which a compute resource is considered idle. Default: 5.

.PARAMETER IncludeUntagged
    Include resources without aither:managed tag. Default: false.

.PARAMETER OutputFormat
    Output format: Object (default), Markdown, Json.

.PARAMETER GenesisUrl
    Genesis backend URL. Default: http://localhost:8001.

.EXAMPLE
    Get-IDINukeReport -Provider aws
    Get-IDINukeReport -Provider docker -IncludeUntagged
    Get-IDINukeReport -IntentGraphs $graphs -StaleThresholdDays 14

.NOTES
    Part of AitherZero IDI (Intent-Driven Infrastructure) module.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Get-IDINukeReport {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('aws', 'docker', 'kubernetes', 'azure', 'gcp', 'multi')]
        [string]$Provider = 'multi',

        [PSCustomObject[]]$IntentGraphs = @(),

        [ValidateRange(1, 365)]
        [int]$StaleThresholdDays = 30,

        [ValidateRange(0, 100)]
        [int]$IdleCPUThreshold = 5,

        [switch]$IncludeUntagged,

        [ValidateSet('Object', 'Markdown', 'Json')]
        [string]$OutputFormat = 'Object',

        [string]$GenesisUrl = 'http://localhost:8001'
    )

    $ReportId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $StartTime = [DateTime]::UtcNow

    Write-Host "`n  🗑️  IDI Nuke Report ($ReportId)" -ForegroundColor Cyan
    Write-Host "  Provider: $Provider | Stale: ${StaleThresholdDays}d | Idle CPU: <${IdleCPUThreshold}%" -ForegroundColor Gray

    # ── Step 1: Discover all live resources ───────────────────────────
    Write-Host "  [1/4] Discovering live resources..." -ForegroundColor Yellow
    $Snapshot = $null
    try {
        $Snapshot = Invoke-CloudDiscovery -Provider $Provider
    } catch {
        Write-Host "  ⚠️  Discovery failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        $Snapshot = [PSCustomObject]@{ resources = @(); orphans = @() }
    }

    $allResources = @($Snapshot.resources) + @($Snapshot.orphans ?? @())
    Write-Host "  [1/4] Found $($allResources.Count) total resources" -ForegroundColor Gray

    # ── Step 2: Build intent coverage map ─────────────────────────────
    Write-Host "  [2/4] Building intent coverage map..." -ForegroundColor Yellow
    $intentResources = @{}
    foreach ($graph in $IntentGraphs) {
        foreach ($res in ($graph.resources ?? @())) {
            $key = "$($res.type):$($res.name)"
            $intentResources[$key] = $true
        }
    }

    # ── Step 3: Classify each resource ────────────────────────────────
    Write-Host "  [3/4] Classifying resources..." -ForegroundColor Yellow
    $nukeTargets = @()
    $safeResources = @()
    $reviewResources = @()

    foreach ($res in $allResources) {
        $isManaged = ($res.tags.'aither:managed' -eq 'true') -or ($res.managed -eq $true)
        $key = "$($res.type):$($res.name)"
        $hasCoverage = $intentResources.ContainsKey($key)

        # Skip untagged unless requested
        if (-not $isManaged -and -not $IncludeUntagged) { continue }

        $classification = Classify-Resource -Resource $res `
            -IsManaged $isManaged -HasCoverage $hasCoverage `
            -StaleThresholdDays $StaleThresholdDays -IdleCPUThreshold $IdleCPUThreshold

        $target = [PSCustomObject]@{
            name               = $res.name ?? $res.id
            type               = $res.type
            provider           = $res.provider ?? $Provider
            region             = $res.region ?? 'unknown'
            status             = $res.status ?? 'unknown'
            is_managed         = $isManaged
            has_intent_coverage = $hasCoverage
            classification     = $classification.class   # orphan, idle, stale, untagged, covered
            risk               = $classification.risk     # safe-to-delete, needs-review, do-not-touch
            reason             = $classification.reason
            estimated_monthly  = Get-ResourceMonthlyCost -Resource $res
            last_activity      = $res.last_activity ?? $res.created ?? 'unknown'
            nuke_command       = $classification.nuke_command
        }

        switch ($classification.risk) {
            'safe-to-delete'  { $nukeTargets += $target }
            'needs-review'    { $reviewResources += $target }
            'do-not-touch'    { $safeResources += $target }
        }
    }

    # ── Step 4: Build report ──────────────────────────────────────────
    Write-Host "  [4/4] Building report..." -ForegroundColor Yellow

    $totalWaste = ($nukeTargets + $reviewResources) | ForEach-Object { $_.estimated_monthly } | Measure-Object -Sum
    $safeWaste = $nukeTargets | ForEach-Object { $_.estimated_monthly } | Measure-Object -Sum
    $reviewWaste = $reviewResources | ForEach-Object { $_.estimated_monthly } | Measure-Object -Sum

    $Report = [PSCustomObject]@{
        report_id          = $ReportId
        generated_at       = $StartTime.ToString('o')
        provider           = $Provider
        scan_duration_ms   = ([DateTime]::UtcNow - $StartTime).TotalMilliseconds
        total_resources    = $allResources.Count
        nuke_targets       = $nukeTargets
        review_required    = $reviewResources
        safe_resources     = $safeResources.Count
        summary            = [PSCustomObject]@{
            orphaned_count          = ($nukeTargets + $reviewResources | Where-Object classification -eq 'orphan').Count
            idle_count              = ($nukeTargets + $reviewResources | Where-Object classification -eq 'idle').Count
            stale_count             = ($nukeTargets + $reviewResources | Where-Object classification -eq 'stale').Count
            untagged_count          = ($nukeTargets + $reviewResources | Where-Object classification -eq 'untagged').Count
            safe_to_delete_count    = $nukeTargets.Count
            needs_review_count      = $reviewResources.Count
            total_waste_monthly     = [math]::Round(($totalWaste.Sum ?? 0), 2)
            safe_savings_monthly    = [math]::Round(($safeWaste.Sum ?? 0), 2)
            review_savings_monthly  = [math]::Round(($reviewWaste.Sum ?? 0), 2)
            safe_savings_annual     = [math]::Round(($safeWaste.Sum ?? 0) * 12, 2)
        }
    }

    # ── Display summary ───────────────────────────────────────────────
    $summaryBox = @"

  ╔══════════════════════════════════════════════════════════════╗
  ║              💀 IDI NUKE REPORT                             ║
  ╠══════════════════════════════════════════════════════════════╣
  ║  Total resources scanned:   $($Report.total_resources.ToString().PadLeft(5))                         ║
  ║  Safe to delete:            $($nukeTargets.Count.ToString().PadLeft(5))  → -`$$($Report.summary.safe_savings_monthly)/mo     ║
  ║  Needs review:              $($reviewResources.Count.ToString().PadLeft(5))  → -`$$($Report.summary.review_savings_monthly)/mo     ║
  ║  Protected (in-intent):     $($safeResources.Count.ToString().PadLeft(5))                         ║
  ╠══════════════════════════════════════════════════════════════╣
  ║  EST. ANNUAL SAVINGS:       `$$($Report.summary.safe_savings_annual)                       ║
  ╚══════════════════════════════════════════════════════════════╝
"@
    Write-Host $summaryBox -ForegroundColor Cyan

    if ($nukeTargets.Count -gt 0) {
        Write-Host "`n  🟢 SAFE TO DELETE:" -ForegroundColor Green
        foreach ($t in ($nukeTargets | Sort-Object estimated_monthly -Descending)) {
            Write-Host "      $($t.classification.ToUpper().PadRight(10)) $($t.name.PadRight(30)) $($t.type.PadRight(20)) `$$($t.estimated_monthly)/mo  ($($t.reason))" -ForegroundColor Green
        }
    }

    if ($reviewResources.Count -gt 0) {
        Write-Host "`n  🟡 NEEDS REVIEW:" -ForegroundColor Yellow
        foreach ($t in ($reviewResources | Sort-Object estimated_monthly -Descending)) {
            Write-Host "      $($t.classification.ToUpper().PadRight(10)) $($t.name.PadRight(30)) $($t.type.PadRight(20)) `$$($t.estimated_monthly)/mo  ($($t.reason))" -ForegroundColor Yellow
        }
    }

    # ── Output format ─────────────────────────────────────────────────
    switch ($OutputFormat) {
        'Markdown' { return Format-NukeReportMarkdown -Report $Report }
        'Json'     { return $Report | ConvertTo-Json -Depth 10 }
        default    { return $Report }
    }
}

# ── Resource classification engine ───────────────────────────────────────
function Classify-Resource {
    param(
        [PSCustomObject]$Resource,
        [bool]$IsManaged,
        [bool]$HasCoverage,
        [int]$StaleThresholdDays,
        [int]$IdleCPUThreshold
    )

    $nukeCmd = Get-NukeCommand -Resource $Resource

    # Category 1: Orphaned (managed but no longer in any intent)
    if ($IsManaged -and -not $HasCoverage) {
        $risk = if ($Resource.status -eq 'stopped') { 'safe-to-delete' } else { 'needs-review' }
        return @{
            class = 'orphan'
            risk = $risk
            reason = "Managed resource with no matching intent"
            nuke_command = $nukeCmd
        }
    }

    # Category 2: Idle (running but not doing anything useful)
    $cpuAvg = $Resource.metrics.cpu_avg ?? $Resource.cpu_percent ?? 100
    if ($cpuAvg -lt $IdleCPUThreshold -and $Resource.status -eq 'running') {
        return @{
            class = 'idle'
            risk = 'needs-review'
            reason = "CPU avg ${cpuAvg}% < ${IdleCPUThreshold}% threshold"
            nuke_command = $nukeCmd
        }
    }

    # Category 3: Stale (not accessed in threshold days)
    $lastActivity = $null
    if ($Resource.last_activity) {
        try { $lastActivity = [DateTime]::Parse($Resource.last_activity) } catch { }
    }
    if ($lastActivity -and ([DateTime]::UtcNow - $lastActivity).TotalDays -gt $StaleThresholdDays) {
        $daysSince = [math]::Round(([DateTime]::UtcNow - $lastActivity).TotalDays)
        return @{
            class = 'stale'
            risk = if ($daysSince -gt ($StaleThresholdDays * 2)) { 'safe-to-delete' } else { 'needs-review' }
            reason = "No activity for ${daysSince}d (threshold: ${StaleThresholdDays}d)"
            nuke_command = $nukeCmd
        }
    }

    # Category 4: Untagged (no aither:managed tag)
    if (-not $IsManaged) {
        return @{
            class = 'untagged'
            risk = 'needs-review'
            reason = "No aither:managed tag — potential shadow IT"
            nuke_command = $nukeCmd
        }
    }

    # Category 5: Covered (has intent, is active)
    return @{
        class = 'covered'
        risk = 'do-not-touch'
        reason = "Active and covered by intent"
        nuke_command = $null
    }
}

# ── Generate provider-specific nuke commands ─────────────────────────────
function Get-NukeCommand {
    param([PSCustomObject]$Resource)

    $provider = $Resource.provider
    $name = $Resource.name ?? $Resource.id
    $type = $Resource.type

    switch ($provider) {
        'aws' {
            switch -Wildcard ($type) {
                'ec2:*'    { return "aws ec2 terminate-instances --instance-ids $($Resource.id)" }
                's3:*'     { return "aws s3 rb s3://$name --force" }
                'rds:*'    { return "aws rds delete-db-instance --db-instance-identifier $name --skip-final-snapshot" }
                'elb:*'    { return "aws elbv2 delete-load-balancer --load-balancer-arn $($Resource.arn)" }
                default    { return "# aws cleanup for $type $name" }
            }
        }
        'docker' {
            return "docker rm -f $name"
        }
        'kubernetes' {
            $kind = ($type -replace 'k8s:', '') ?? 'deployment'
            return "kubectl delete $kind $name"
        }
        'azure' {
            return "az resource delete --ids $($Resource.id)"
        }
        'gcp' {
            return "gcloud compute instances delete $name --quiet"
        }
        default { return "# manual cleanup required for $provider/$type/$name" }
    }
}

# ── Cost estimation for individual resources ─────────────────────────────
function Get-ResourceMonthlyCost {
    param([PSCustomObject]$Resource)

    # Simplified cost lookup — same catalog as Get-IDICostProjection
    $type = $Resource.type
    $instanceType = $Resource.config.instance_type ?? $Resource.instance_type ?? ''
    $provider = $Resource.provider

    $hourlyRates = @{
        't3.micro'   = 0.0104; 't3.small'  = 0.0208; 't3.medium' = 0.0416
        't3.large'   = 0.0832; 't3.xlarge' = 0.1664
        'm5.large'   = 0.096;  'm5.xlarge' = 0.192;  'm5.2xlarge' = 0.384
        'r5.large'   = 0.126;  'r5.xlarge' = 0.252
        'c5.large'   = 0.085;  'c5.xlarge' = 0.170
    }

    $monthly = switch -Wildcard ($type) {
        'ec2:*' {
            $rate = $hourlyRates[$instanceType] ?? 0.05
            [math]::Round($rate * 730 * ($Resource.quantity ?? 1), 2)
        }
        'rds:*' {
            $rate = ($hourlyRates[$instanceType] ?? 0.05) * 1.4  # RDS premium
            [math]::Round($rate * 730 * ($Resource.quantity ?? 1), 2)
        }
        's3:*'     { 2.30 }  # Avg S3 bucket
        'elb:*'    { 22.27 }
        'ebs:*'    { [math]::Round(0.10 * ($Resource.config.storage_gb ?? 50), 2) }
        'docker:*' { 0 }     # No cloud cost for local docker
        'k8s:*'    { 5.00 }  # Nominal per-workload cost
        default    { 1.00 }  # Unknown — minimum estimate
    }

    return $monthly
}

# ── Markdown formatter ───────────────────────────────────────────────────
function Format-NukeReportMarkdown {
    param([PSCustomObject]$Report)

    $md = @"
# 💀 IDI Nuke Report

**Generated:** $($Report.generated_at)
**Provider:** $($Report.provider)
**Total Resources:** $($Report.total_resources)

## Summary

| Metric | Count | Monthly Cost |
|--------|-------|-------------|
| Safe to Delete | $($Report.summary.safe_to_delete_count) | `$$($Report.summary.safe_savings_monthly) |
| Needs Review | $($Report.summary.needs_review_count) | `$$($Report.summary.review_savings_monthly) |
| Orphaned | $($Report.summary.orphaned_count) | — |
| Idle | $($Report.summary.idle_count) | — |
| Stale | $($Report.summary.stale_count) | — |
| **Est. Annual Savings** | — | **`$$($Report.summary.safe_savings_annual)** |

## 🟢 Safe to Delete

"@
    foreach ($t in $Report.nuke_targets) {
        $md += "- **$($t.name)** ($($t.type)) — `$$($t.estimated_monthly)/mo — $($t.reason)`n"
        if ($t.nuke_command) {
            $md += "  ``````$($t.nuke_command)```````n"
        }
    }

    $md += "`n## 🟡 Needs Review`n`n"
    foreach ($t in $Report.review_required) {
        $md += "- **$($t.name)** ($($t.type)) — `$$($t.estimated_monthly)/mo — $($t.reason)`n"
    }

    return $md
}
