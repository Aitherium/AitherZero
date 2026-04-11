#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    High-level infrastructure agent that routes through the IDI pipeline.

.DESCRIPTION
    Invoke-AitherInfra is the agent-facing entry point for Intent-Driven Infrastructure.
    It wraps the full IDI pipeline and integrates with the AitherZero agent system.

    When called directly, it runs the complete IDI workflow:
      1. Intent classification via IntentEngine (Pillar 1)
      2. Resource extraction via ConvertTo-IntentGraph
      3. Live discovery via Invoke-CloudDiscovery
      4. Reconciliation via Compare-IntentVsDiscovery
      5. Cost projection via Get-IDICostProjection
      6. Execution via Invoke-IDIExecution (with approval gates)

    When called from Invoke-AitherAgent -Delegate infrastructure, it receives the
    natural language prompt and orchestrates the full pipeline autonomously.

    Smart features:
    - Auto-detects provider from intent (AWS, Docker, K8s, Azure, GCP)
    - Effort-based model routing (complex infra → reasoning model)
    - Budget enforcement (blocks if over cost limit)
    - Dry-run by default for production environments
    - Drift check before execution (warns if existing infra conflicts)

.PARAMETER Prompt
    Natural language infrastructure intent.

.PARAMETER Provider
    Override auto-detected provider. Default: auto.

.PARAMETER Environment
    Target environment. Default: dev.

.PARAMETER CostLimit
    Monthly cost limit in USD. Default: 500.

.PARAMETER DryRun
    Run the full pipeline but don't execute changes.

.PARAMETER SkipDiscovery
    Skip live cloud discovery (faster, but no drift detection).

.PARAMETER Watch
    After execution, start drift monitoring.

.PARAMETER WatchInterval
    Drift watch interval in seconds. Default: 300.

.PARAMETER Explain
    Show detailed pipeline decisions without executing.

.PARAMETER Force
    Skip all approval gates.

.PARAMETER GenesisUrl
    Genesis backend URL. Default: http://localhost:8001.

.EXAMPLE
    Invoke-AitherIDI "Deploy 3 t3.large EC2 instances in us-east-1 for the prod API"
    Invoke-AitherIDI "Spin up a Redis cluster with 3 nodes" -Environment staging
    Invoke-AitherIDI "Scale the worker fleet to 10 instances" -DryRun
    Invoke-AitherIDI "Tear down the dev environment" -Force

    # Via agent system:
    Invoke-AitherAgent -Prompt "Deploy a Kubernetes cluster" -Delegate infrastructure

.NOTES
    Part of AitherZero IDI (Intent-Driven Infrastructure) module.
    This is the recommended entry point for infrastructure operations.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Invoke-AitherIDI {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Prompt,

        [ValidateSet('auto', 'aws', 'docker', 'kubernetes', 'azure', 'gcp', 'multi')]
        [string]$Provider = 'auto',

        [ValidateSet('dev', 'staging', 'prod')]
        [string]$Environment = 'dev',

        [double]$CostLimit = 500.0,

        [switch]$DryRun,

        [switch]$SkipDiscovery,

        [switch]$Watch,

        [int]$WatchInterval = 300,

        [switch]$Explain,

        [switch]$Force,

        [string]$GenesisUrl = 'http://localhost:8001',

        [switch]$UsePipeline,

        [string]$InfraRepoPath,

        [ValidateSet('Module', 'Inline', 'Hybrid')]
        [string]$Strategy = 'Module',

        [ValidateSet('local', 's3', 'azurerm', 'gcs')]
        [string]$Backend = 'local',

        [string]$CometUrl = 'http://localhost:8125'
    )

    process {
        $SessionId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $PipelineStart = [DateTime]::UtcNow
        $ForceDryRun = ($Environment -eq 'prod' -and -not $Force)

        Write-Host "`n" -NoNewline
        Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║            ⚡ AitherZero Infrastructure Agent                ║" -ForegroundColor Cyan
        Write-Host "  ║            Intent-Driven Infrastructure (IDI)                ║" -ForegroundColor Cyan
        Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host "  Session: $SessionId | Env: $Environment" -ForegroundColor Gray

        if ($ForceDryRun) {
            Write-Host "  🔒 Production environment — DryRun enforced (use -Force to override)" -ForegroundColor Yellow
            $DryRun = [switch]::new($true)
        }

        # ── Pipeline mode: full OpenTofu pipeline ─────────────────────
        if ($UsePipeline) {
            Write-Host "`n  ── OpenTofu Pipeline Mode ──" -ForegroundColor Magenta
            $pipelineParams = @{
                Intent      = $Prompt
                Environment = $Environment
                Strategy    = $Strategy
                Backend     = $Backend
                DryRun      = $DryRun
                CometUrl    = $CometUrl
                GenesisUrl  = $GenesisUrl
                PassThru    = $true
            }
            if ($Provider -ne 'auto') { $pipelineParams['Provider'] = $Provider }
            if ($InfraRepoPath) { $pipelineParams['InfraRepoPath'] = $InfraRepoPath }
            if ($Force) { $pipelineParams['Force'] = $true; $pipelineParams['AutoApprove'] = $true }

            return Invoke-AitherInfraPipeline @pipelineParams
        }

        # ── Stage 1: Full IDI Pipeline ────────────────────────────────
        Write-Host "`n  ── Running IDI Pipeline ──" -ForegroundColor Cyan

        $idiParams = @{
            Statement   = $Prompt
            Environment = $Environment
            Provider    = if ($Provider -ne 'auto') { $Provider } else { $null }
            CostLimit   = $CostLimit
            GenesisUrl  = $GenesisUrl
        }
        if ($Explain) { $idiParams['Explain'] = $true }
        if ($SkipDiscovery) { $idiParams['SkipDiscovery'] = $true }

        # Remove null values
        $idiParams = $idiParams.GetEnumerator() | Where-Object { $null -ne $_.Value } | ForEach-Object -Begin { $h = @{} } -Process { $h[$_.Key] = $_.Value } -End { $h }

        $Pipeline = Invoke-AitherIntent @idiParams

        if ($Explain) {
            # Explain mode — show analysis and stop
            return $Pipeline
        }

        # ── Check pipeline results ────────────────────────────────────
        if (-not $Pipeline -or -not $Pipeline.Phases) {
            Write-Host "  ❌ IDI pipeline returned no results" -ForegroundColor Red
            return $Pipeline
        }

        $CostPhase = $Pipeline.Phases | Where-Object { $_.Name -eq 'cost' }
        $DiffPhase = $Pipeline.Phases | Where-Object { $_.Name -eq 'diff' }

        # ── Stage 2: Cost gate ────────────────────────────────────────
        if ($CostPhase -and $CostPhase.Result.gate.blocked -and -not $Force) {
            Write-Host "`n  💰 COST GATE BLOCKED" -ForegroundColor Red
            Write-Host "  Reason: $($CostPhase.Result.gate.reason)" -ForegroundColor Red
            Write-Host "  Net monthly: `$$($CostPhase.Result.totals.net_monthly_impact)" -ForegroundColor Yellow
            Write-Host "  Budget limit: `$$CostLimit" -ForegroundColor Yellow
            Write-Host "`n  Use -Force to override or increase -CostLimit" -ForegroundColor DarkGray
            return $Pipeline
        }

        # ── Stage 3: Execute (or dry-run) ─────────────────────────────
        $ChangeSet = $DiffPhase.Result
        if ($ChangeSet -and $ChangeSet.changes.Count -gt 0) {
            $actionableChanges = ($ChangeSet.changes | Where-Object action -ne 'no_op').Count
            if ($actionableChanges -gt 0) {
                Write-Host "`n  ── Execution ──" -ForegroundColor Cyan

                $execParams = @{
                    ChangeSet        = $ChangeSet
                    DryRun           = $DryRun
                    RollbackOnFailure = $true
                    GenesisUrl       = $GenesisUrl
                }
                if ($CostPhase) { $execParams['CostProjection'] = $CostPhase.Result }
                if ($Force) { $execParams['Force'] = $true }

                $ExecResult = Invoke-IDIExecution @execParams
                $Pipeline | Add-Member -NotePropertyName 'Execution' -NotePropertyValue $ExecResult -Force
            } else {
                Write-Host "`n  ✅ No actionable changes — infrastructure matches intent" -ForegroundColor Green
            }
        }

        # ── Stage 4: Post-execution drift watch ──────────────────────
        if ($Watch -and -not $DryRun) {
            Write-Host "`n  ── Starting Drift Watch ──" -ForegroundColor Cyan
            $IntentGraph = ($Pipeline.Phases | Where-Object { $_.Name -eq 'parse' }).Result

            $driftResult = Invoke-IDIDriftWatch -IntentGraph $IntentGraph `
                -Provider ($Provider -ne 'auto' ? $Provider : 'multi') `
                -Mode Watch -IntervalSeconds $WatchInterval `
                -GenesisUrl $GenesisUrl

            $Pipeline | Add-Member -NotePropertyName 'DriftWatch' -NotePropertyValue $driftResult -Force
        }

        # ── Final summary ─────────────────────────────────────────────
        $Duration = ([DateTime]::UtcNow - $PipelineStart).TotalSeconds
        Write-Host "`n  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  Pipeline complete in $([math]::Round($Duration, 1))s" -ForegroundColor Gray
        Write-Host "  Session: $SessionId" -ForegroundColor Gray

        return $Pipeline
    }
}

# Export handled by build.ps1
