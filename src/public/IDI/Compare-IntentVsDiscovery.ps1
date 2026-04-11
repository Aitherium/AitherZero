#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Diff an IntentGraph against a live DiscoverySnapshot to produce an IDI ChangeSet.

.DESCRIPTION
    Compare-IntentVsDiscovery is the reconciliation engine of the IDI pipeline.
    Given a desired state (IntentGraph from ConvertTo-IntentGraph) and the actual state
    (DiscoverySnapshot from Invoke-CloudDiscovery), it computes a minimal ChangeSet:

    - CREATE:  Resources in intent but not in discovery
    - UPDATE:  Resources that exist but differ from intent (sizing, config, tags)
    - DESTROY: Resources in discovery but not in intent (orphans, if -IncludeOrphans)
    - NO_OP:   Resources that already match intent (already converged)

    The ChangeSet feeds directly into Get-IDICostProjection and Invoke-IDIExecution.
    It is the core of IDI's idempotent infrastructure reconciliation.

    Matching strategy:
    1. Exact match: resource type + name/tag match
    2. Type match: same resource type in same region → candidate for UPDATE
    3. Tag match: aither:intent-hash tag matches → same logical resource
    4. Fuzzy match: similar names with Levenshtein distance < 3

.PARAMETER IntentGraph
    The desired state DAG from ConvertTo-IntentGraph.

.PARAMETER DiscoverySnapshot
    The actual state from Invoke-CloudDiscovery.

.PARAMETER IncludeOrphans
    Include discovered resources NOT in intent as DESTROY candidates.

.PARAMETER DriftThreshold
    Percentage difference threshold to consider a resource "drifted". Default 10%.

.PARAMETER TagKey
    The tag key used to match intent resources to discovered resources.
    Default: 'aither:intent-hash'.

.EXAMPLE
    $Graph = ConvertTo-IntentGraph -Intent "Deploy 3 Redis nodes in us-east-1"
    $Live  = Invoke-CloudDiscovery -Provider aws -Region us-east-1
    $Changes = Compare-IntentVsDiscovery -IntentGraph $Graph -DiscoverySnapshot $Live

.EXAMPLE
    $Changes = Compare-IntentVsDiscovery -IntentGraph $Graph -DiscoverySnapshot $Live -IncludeOrphans
    $Changes.Changes | Where-Object action -eq 'destroy' | Format-Table

.NOTES
    Part of AitherZero IDI (Intent-Driven Infrastructure) module.
    Integrates with IntentEngine.py (Pillar 1) via Genesis SASE pipeline.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Compare-IntentVsDiscovery {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$IntentGraph,

        [Parameter(Mandatory)]
        [PSCustomObject]$DiscoverySnapshot,

        [switch]$IncludeOrphans,

        [ValidateRange(0, 100)]
        [int]$DriftThreshold = 10,

        [string]$TagKey = 'aither:intent-hash'
    )

    process {
        $Changes = @()
        $MatchedDiscoveryIds = @()
        $IntentResources = @($IntentGraph.resources)
        $DiscoveryResources = @($DiscoverySnapshot.resources)
        $Environment = $IntentGraph.environment ?? 'dev'
        $TotalCostDelta = 0.0

        Write-Verbose "Comparing $($IntentResources.Count) intent resources against $($DiscoveryResources.Count) discovered resources"

        # ── Pass 1: Match intent resources against discovery ──────────────
        foreach ($intentRes in $IntentResources) {
            $match = $null
            $matchType = 'none'

            # Strategy 1: Tag-based matching (most reliable)
            if ($intentRes.tags -and $intentRes.tags[$TagKey]) {
                $intentHash = $intentRes.tags[$TagKey]
                $match = $DiscoveryResources | Where-Object {
                    $_.tags -and $_.tags[$TagKey] -eq $intentHash
                } | Select-Object -First 1

                if ($match) { $matchType = 'tag-hash' }
            }

            # Strategy 2: Type + Name matching
            if (-not $match) {
                $match = $DiscoveryResources | Where-Object {
                    $_.type -eq $intentRes.type -and $_.name -eq $intentRes.name
                } | Select-Object -First 1

                if ($match) { $matchType = 'type-name' }
            }

            # Strategy 3: Type + Region matching (for singleton resources like VPCs)
            if (-not $match) {
                $singletonTypes = @('vpc:vpc', 'eks:cluster', 'ecs:service')
                if ($intentRes.type -in $singletonTypes) {
                    $match = $DiscoveryResources | Where-Object {
                        $_.type -eq $intentRes.type -and $_.region -eq $intentRes.region
                    } | Select-Object -First 1

                    if ($match) { $matchType = 'type-region-singleton' }
                }
            }

            # Strategy 4: Fuzzy name matching within same type
            if (-not $match) {
                $candidates = $DiscoveryResources | Where-Object { $_.type -eq $intentRes.type }
                foreach ($c in $candidates) {
                    if ($c.id -in $MatchedDiscoveryIds) { continue }
                    $dist = Get-LevenshteinDistance $intentRes.name $c.name
                    if ($dist -le 3) {
                        $match = $c
                        $matchType = "fuzzy-name(dist=$dist)"
                        break
                    }
                }
            }

            if ($match) {
                # Resource exists — check for drift
                $MatchedDiscoveryIds += $match.id
                $drifts = @()

                # Compare configurations
                $configDrifts = Compare-ResourceConfig -Intent $intentRes -Actual $match -Threshold $DriftThreshold
                $drifts += $configDrifts

                if ($drifts.Count -gt 0) {
                    $change = [PSCustomObject]@{
                        action          = 'update'
                        resource_type   = $intentRes.type
                        intent_resource = $intentRes
                        actual_resource = $match
                        match_type      = $matchType
                        drifts          = $drifts
                        drift_severity  = Get-DriftSeverity $drifts
                        cost_delta      = Get-CostDelta $intentRes $match
                        requires_downtime = Test-RequiresDowntime $drifts $intentRes.type
                        risk_level      = if ($Environment -eq 'prod') { 'high' } else { 'medium' }
                    }
                    $TotalCostDelta += $change.cost_delta
                    $Changes += $change
                } else {
                    $Changes += [PSCustomObject]@{
                        action          = 'no_op'
                        resource_type   = $intentRes.type
                        intent_resource = $intentRes
                        actual_resource = $match
                        match_type      = $matchType
                        drifts          = @()
                        drift_severity  = 'none'
                        cost_delta      = 0.0
                        requires_downtime = $false
                        risk_level      = 'none'
                    }
                }
            } else {
                # Resource doesn't exist — needs creation
                $hourlyCost = $intentRes.cost_hints.estimated_hourly ?? 0.05
                $monthlyCost = $intentRes.cost_hints.estimated_monthly ?? ($hourlyCost * 730)

                $Changes += [PSCustomObject]@{
                    action          = 'create'
                    resource_type   = $intentRes.type
                    intent_resource = $intentRes
                    actual_resource = $null
                    match_type      = 'none'
                    drifts          = @()
                    drift_severity  = 'none'
                    cost_delta      = $monthlyCost * $intentRes.quantity
                    requires_downtime = $false
                    risk_level      = if ($Environment -eq 'prod') { 'medium' } else { 'low' }
                }
                $TotalCostDelta += $monthlyCost * $intentRes.quantity
            }
        }

        # ── Pass 2: Orphan detection (discovered but not in intent) ──────
        $OrphanChanges = @()
        if ($IncludeOrphans) {
            $orphans = $DiscoveryResources | Where-Object { $_.id -notin $MatchedDiscoveryIds }
            foreach ($orphan in $orphans) {
                # Only flag aither-managed resources as orphans
                $isManaged = $orphan.tags -and $orphan.tags['aither:managed'] -eq 'true'
                if (-not $isManaged) { continue }

                $hourlyCost = $orphan.cost_hints.estimated_hourly ?? $orphan.cost.hourly ?? 0.05
                $monthlyCost = $hourlyCost * 730

                $OrphanChanges += [PSCustomObject]@{
                    action          = 'destroy'
                    resource_type   = $orphan.type
                    intent_resource = $null
                    actual_resource = $orphan
                    match_type      = 'orphan'
                    drifts          = @()
                    drift_severity  = 'orphan'
                    cost_delta      = -$monthlyCost  # Savings
                    requires_downtime = $true
                    risk_level      = if ($Environment -eq 'prod') { 'critical' } else { 'high' }
                }
                $TotalCostDelta -= $monthlyCost
            }
            $Changes += $OrphanChanges
        }

        # ── Build ChangeSet summary ──────────────────────────────────────
        $ActionCounts = @{}
        foreach ($c in $Changes) {
            $ActionCounts[$c.action] = ($ActionCounts[$c.action] ?? 0) + 1
        }

        $HighRisk = ($Changes | Where-Object { $_.risk_level -in @('high', 'critical') }).Count
        $NeedsApproval = $HighRisk -gt 0 -or $Environment -ne 'dev' -or
                         ($Changes | Where-Object { $_.action -eq 'destroy' }).Count -gt 0

        $ChangeSet = [PSCustomObject]@{
            version        = '1.0'
            engine         = 'aitherzero-idi-diff'
            timestamp      = [DateTime]::UtcNow.ToString('o')
            environment    = $Environment
            intent_hash    = $IntentGraph.intent_hash
            changes        = $Changes
            summary        = [PSCustomObject]@{
                total_changes      = $Changes.Count
                creates            = $ActionCounts['create'] ?? 0
                updates            = $ActionCounts['update'] ?? 0
                destroys           = $ActionCounts['destroy'] ?? 0
                no_ops             = $ActionCounts['no_op'] ?? 0
                total_cost_delta   = [math]::Round($TotalCostDelta, 2)
                cost_direction     = if ($TotalCostDelta -gt 0) { 'increase' } elseif ($TotalCostDelta -lt 0) { 'decrease' } else { 'neutral' }
                high_risk_count    = $HighRisk
                requires_approval  = $NeedsApproval
                downtime_required  = ($Changes | Where-Object { $_.requires_downtime }).Count -gt 0
            }
            execution_order = Get-ExecutionOrder $Changes $IntentGraph.dependencies
        }

        return $ChangeSet
    }
}

# ── Helper: Compare resource configurations ──────────────────────────────
function Compare-ResourceConfig {
    param(
        [PSCustomObject]$Intent,
        [PSCustomObject]$Actual,
        [int]$Threshold
    )

    $Drifts = @()
    $intentConfig = $Intent.config
    $actualConfig = $Actual.config ?? @{}

    # Compare instance type
    if ($intentConfig.instance_type -and $actualConfig.instance_type -and
        $intentConfig.instance_type -ne $actualConfig.instance_type) {
        $Drifts += [PSCustomObject]@{
            field    = 'instance_type'
            intent   = $intentConfig.instance_type
            actual   = $actualConfig.instance_type
            severity = 'medium'
        }
    }

    # Compare memory
    if ($intentConfig.memory_gb -and $actualConfig.memory_gb) {
        $memDiff = [math]::Abs($intentConfig.memory_gb - $actualConfig.memory_gb)
        $memPct = if ($actualConfig.memory_gb -gt 0) { ($memDiff / $actualConfig.memory_gb) * 100 } else { 100 }
        if ($memPct -gt $Threshold) {
            $Drifts += [PSCustomObject]@{
                field    = 'memory_gb'
                intent   = $intentConfig.memory_gb
                actual   = $actualConfig.memory_gb
                severity = if ($memPct -gt 50) { 'high' } else { 'medium' }
            }
        }
    }

    # Compare CPU
    if ($intentConfig.cpu -and $actualConfig.cpu) {
        $cpuDiff = [math]::Abs($intentConfig.cpu - $actualConfig.cpu)
        $cpuPct = if ($actualConfig.cpu -gt 0) { ($cpuDiff / $actualConfig.cpu) * 100 } else { 100 }
        if ($cpuPct -gt $Threshold) {
            $Drifts += [PSCustomObject]@{
                field    = 'cpu'
                intent   = $intentConfig.cpu
                actual   = $actualConfig.cpu
                severity = if ($cpuPct -gt 50) { 'high' } else { 'medium' }
            }
        }
    }

    # Compare storage
    if ($intentConfig.storage_gb -and $actualConfig.storage_gb) {
        $stgDiff = [math]::Abs($intentConfig.storage_gb - $actualConfig.storage_gb)
        $stgPct = if ($actualConfig.storage_gb -gt 0) { ($stgDiff / $actualConfig.storage_gb) * 100 } else { 100 }
        if ($stgPct -gt $Threshold) {
            $Drifts += [PSCustomObject]@{
                field    = 'storage_gb'
                intent   = $intentConfig.storage_gb
                actual   = $actualConfig.storage_gb
                severity = 'low'  # Storage changes are usually safe
            }
        }
    }

    # Compare quantity (scaling drift)
    if ($Intent.quantity -and $Actual.quantity -and $Intent.quantity -ne $Actual.quantity) {
        $Drifts += [PSCustomObject]@{
            field    = 'quantity'
            intent   = $Intent.quantity
            actual   = $Actual.quantity
            severity = 'medium'
        }
    }

    return $Drifts
}

# ── Helper: Determine drift severity ─────────────────────────────────────
function Get-DriftSeverity {
    param([array]$Drifts)
    if ($Drifts.Count -eq 0) { return 'none' }
    $severities = $Drifts | ForEach-Object { $_.severity }
    if ('critical' -in $severities) { return 'critical' }
    if ('high' -in $severities) { return 'high' }
    if ('medium' -in $severities) { return 'medium' }
    return 'low'
}

# ── Helper: Calculate cost delta ─────────────────────────────────────────
function Get-CostDelta {
    param(
        [PSCustomObject]$Intent,
        [PSCustomObject]$Actual
    )

    $intentMonthlyCost = $Intent.cost_hints.estimated_monthly ?? 0
    $actualMonthlyCost = $Actual.cost_hints.estimated_monthly ?? $Actual.cost.monthly ?? 0
    return [math]::Round($intentMonthlyCost - $actualMonthlyCost, 2)
}

# ── Helper: Check if update requires downtime ────────────────────────────
function Test-RequiresDowntime {
    param(
        [array]$Drifts,
        [string]$ResourceType
    )

    $downtimeFields = @('instance_type', 'engine', 'cpu')
    $downtimeTypes = @('rds:instance', 'rds:aurora', 'eks:cluster')

    if ($ResourceType -in $downtimeTypes) {
        foreach ($drift in $Drifts) {
            if ($drift.field -in $downtimeFields) { return $true }
        }
    }
    return $false
}

# ── Helper: Levenshtein distance ─────────────────────────────────────────
function Get-LevenshteinDistance {
    param([string]$s, [string]$t)

    $n = $s.Length
    $m = $t.Length
    $d = New-Object 'int[,]' ($n + 1), ($m + 1)

    for ($i = 0; $i -le $n; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $m; $j++) { $d[0, $j] = $j }

    for ($i = 1; $i -le $n; $i++) {
        for ($j = 1; $j -le $m; $j++) {
            $cost = if ($s[$i - 1] -eq $t[$j - 1]) { 0 } else { 1 }
            $d[$i, $j] = [math]::Min(
                [math]::Min($d[($i - 1), $j] + 1, $d[$i, ($j - 1)] + 1),
                $d[($i - 1), ($j - 1)] + $cost
            )
        }
    }
    return $d[$n, $m]
}

# ── Helper: Topological execution order ──────────────────────────────────
function Get-ExecutionOrder {
    param(
        [array]$Changes,
        [array]$Dependencies
    )

    # Simple dependency-aware ordering:
    # 1. Creates before updates (new deps first)
    # 2. Respect dependency edges
    # 3. Destroys last (reverse dependency order)
    $creates = @($Changes | Where-Object { $_.action -eq 'create' })
    $updates = @($Changes | Where-Object { $_.action -eq 'update' })
    $destroys = @($Changes | Where-Object { $_.action -eq 'destroy' })

    # Within creates: dependency order (VPCs → subnets → instances)
    $orderedCreates = @()
    $depGraph = @{}
    foreach ($dep in $Dependencies) {
        if (-not $depGraph[$dep.to]) { $depGraph[$dep.to] = @() }
        $depGraph[$dep.to] += $dep.from
    }

    # Simple topological sort via Kahn's algorithm
    $remaining = [System.Collections.ArrayList]::new(@($creates))
    $visited = @{}
    $maxIterations = $creates.Count * 2 + 1

    for ($iter = 0; $iter -lt $maxIterations -and $remaining.Count -gt 0; $iter++) {
        $ready = $remaining | Where-Object {
            $resId = $_.intent_resource.id
            $deps = $depGraph[$resId]
            if (-not $deps) { return $true }
            $unmet = $deps | Where-Object { $_ -notin $visited.Keys }
            return ($unmet | Measure-Object).Count -eq 0
        } | Select-Object -First 1

        if ($ready) {
            $orderedCreates += $ready
            $visited[$ready.intent_resource.id] = $true
            $remaining.Remove($ready)
        } else {
            # Circular dependency — just append remaining
            $orderedCreates += $remaining
            break
        }
    }

    # Execution order: ordered creates → updates → reverse destroys
    $order = @()
    $step = 1
    foreach ($c in $orderedCreates) {
        $order += [PSCustomObject]@{
            step     = $step++
            action   = 'create'
            resource = $c.intent_resource.name ?? $c.intent_resource.type
            risk     = $c.risk_level
        }
    }
    foreach ($u in $updates) {
        $order += [PSCustomObject]@{
            step     = $step++
            action   = 'update'
            resource = $u.intent_resource.name ?? $u.intent_resource.type
            risk     = $u.risk_level
        }
    }
    foreach ($d in ($destroys | Sort-Object { $_.actual_resource.id } -Descending)) {
        $order += [PSCustomObject]@{
            step     = $step++
            action   = 'destroy'
            resource = $d.actual_resource.name ?? $d.actual_resource.type
            risk     = $d.risk_level
        }
    }

    return $order
}
