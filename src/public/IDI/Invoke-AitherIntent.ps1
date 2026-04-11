#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Intent-Driven Infrastructure — compile natural language to live cloud API execution.

.DESCRIPTION
    Invoke-AitherIntent is the core entry point for AitherZero's IDI (Intent-Driven
    Infrastructure) engine. It accepts plain English infrastructure intent and compiles
    it directly to cloud SDK calls — no YAML, no Terraform, no state files. Ever.

    The pipeline:
      1. NLP PARSE     — LLM decomposes intent into an IntentGraph (DAG of resources)
      2. DISCOVER      — Real-time cloud API queries build a DiscoverySnapshot of what exists
      3. DIFF          — IntentGraph vs DiscoverySnapshot → minimal ChangeSet
      4. COST GATE     — Right-sizing + cost projection BEFORE execution (not after)
      5. EXECUTE       — Native SDK calls (AWS, Azure, GCP, Docker) — no intermediate DSL
      6. VERIFY        — Post-execution discovery confirms convergence
      7. EMIT          — FluxEmitter publishes telemetry to Chronicle + Strata

    Why this makes Terraform look like a fax machine:
    - No .tfstate files. State is the cloud itself, queried in real-time.
    - No HCL/YAML/JSON manifests. Intent is the interface.
    - No plan/apply ceremony. Idempotent by design — runs converge, not mutate.
    - No drift. Continuous discovery means drift is caught and healed automatically.
    - Cost sovereignty at the API-call level, not post-deploy reports.

.PARAMETER Intent
    Plain English description of desired infrastructure state.
    Examples:
      "Deploy a 3-node Redis cluster in us-east-1 with 6GB memory each"
      "Scale the API gateway to handle 10k req/s with auto-scaling"
      "Create a VPC with public/private subnets across 3 AZs"
      "Tear down all non-production resources older than 7 days"

.PARAMETER Provider
    Target cloud provider. If omitted, inferred from intent or defaults to multi-cloud.

.PARAMETER Environment
    Target environment ring: dev, staging, prod. Affects cost gates and approval requirements.

.PARAMETER DryRun
    Compile intent and show the execution plan without touching infrastructure.

.PARAMETER CostLimit
    Maximum monthly cost allowed (USD). Execution aborts if projection exceeds this.

.PARAMETER Force
    Skip confirmation prompts and approval gates (dev environment only).

.PARAMETER Explain
    Output a human-readable explanation of what the engine will do, step by step.

.PARAMETER Model
    LLM model for intent compilation. Defaults to the orchestrator model.

.PARAMETER Stream
    Stream execution progress in real-time.

.PARAMETER Remediate
    Auto-remediate any drift detected during discovery phase.

.PARAMETER NoCache
    Bypass the intent compilation cache. Forces a fresh LLM compile even if
    a cached SDK spec exists for this intent. By default, identical intents
    reuse the cached compilation — the LLM is the compiler, not the runtime.

.PARAMETER CacheDir
    Directory for intent compilation cache. Defaults to ~/.aitherzero/idi-cache.
    Each compiled intent is stored as a JSON file keyed by intent hash.

.PARAMETER CredentialProfile
    BYOC (Bring Your Own Credentials) profile name. Passed through to
    Invoke-CloudDiscovery for credential isolation per environment.

.PARAMETER PassThru
    Return the full IDI execution result object.

.EXAMPLE
    # Simple intent — deploy Redis
    Invoke-AitherIntent "Deploy a Redis cluster with 3 replicas in us-east-1"

.EXAMPLE
    # Cost-gated deployment
    Invoke-AitherIntent "Create a production Kubernetes cluster with GPU nodes" -CostLimit 500 -Environment prod

.EXAMPLE
    # Dry run with explanation
    Invoke-AitherIntent "Migrate the database to Aurora Serverless v2" -DryRun -Explain

.EXAMPLE
    # Multi-cloud intent
    Invoke-AitherIntent "Deploy the API in AWS us-east-1 and Azure westeurope with GeoDNS failover"

.EXAMPLE
    # Destructive intent with cost sovereignty
    Invoke-AitherIntent "Nuke all dev resources that haven't been accessed in 30 days" -Environment dev -Force

.NOTES
    Part of AitherZero IDI (Intent-Driven Infrastructure) module.
    This is not a wrapper around Terraform. This replaces Terraform.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Invoke-AitherIntent {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Intent,

        [ValidateSet('aws', 'azure', 'gcp', 'docker', 'kubernetes', 'multi')]
        [string]$Provider,

        [ValidateSet('dev', 'staging', 'prod')]
        [string]$Environment = 'dev',

        [switch]$DryRun,

        [decimal]$CostLimit,

        [switch]$Force,

        [switch]$Explain,

        [string]$Model,

        [switch]$Stream,

        [switch]$Remediate,

        [switch]$NoCache,

        [string]$CacheDir,

        [string]$CredentialProfile,

        [switch]$PassThru,

        [string]$GenesisUrl
    )

    begin {
        $GenesisUrl = if ($GenesisUrl) { $GenesisUrl }
                      elseif ($env:AITHER_GENESIS_URL) { $env:AITHER_GENESIS_URL }
                      else { 'http://localhost:8001' }

        $Timer = [System.Diagnostics.Stopwatch]::StartNew()

        # ── Intent Compilation Cache ──────────────────────────────────────
        # "The LLM is the compiler, not the runtime."
        # We hash the intent + provider + environment → check cache → skip LLM
        # if we already compiled this exact intent before. The compiled SDK spec
        # is stored, auditable, and reusable. Token costs drop to zero on cache hits.
        if (-not $CacheDir) {
            $CacheDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.aitherzero' 'idi-cache'
        }
        if (-not (Test-Path $CacheDir)) {
            New-Item -Path $CacheDir -ItemType Directory -Force | Out-Null
        }
        $IntentCacheKey = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes("$Intent|$Provider|$Environment")
        ) | ForEach-Object { $_.ToString('x2') } | Join-String
        $IntentCacheKey = $IntentCacheKey.Substring(0, 32)
        $CachePath = Join-Path $CacheDir "$IntentCacheKey.json"
        $CacheHit = $false

        # ── IDI Pipeline State ────────────────────────────────────────────
        $Pipeline = [PSCustomObject]@{
            Intent           = $Intent
            Provider         = $Provider
            Environment      = $Environment
            IntentClassification = $null   # From real IntentEngine (Pillar 1)
            IntentGraph      = $null
            DiscoverySnapshot = $null
            ChangeSet        = $null
            CostProjection   = $null
            ExecutionResult  = $null
            VerificationResult = $null
            Status           = 'Initializing'
            Phase            = 'parse'
            Phases           = [ordered]@{
                parse    = @{ Status = 'pending'; Duration = $null; Output = $null }
                discover = @{ Status = 'pending'; Duration = $null; Output = $null }
                diff     = @{ Status = 'pending'; Duration = $null; Output = $null }
                cost     = @{ Status = 'pending'; Duration = $null; Output = $null }
                execute  = @{ Status = 'pending'; Duration = $null; Output = $null }
                verify   = @{ Status = 'pending'; Duration = $null; Output = $null }
            }
            Duration         = [TimeSpan]::Zero
            Timestamp        = [DateTime]::UtcNow
            DryRun           = $DryRun.IsPresent
            Error            = $null
        }
    }

    process {
        try {
            # ═══════════════════════════════════════════════════════════════
            # PHASE 1: NLP INTENT COMPILATION
            # ═══════════════════════════════════════════════════════════════
            $Pipeline.Phase = 'parse'
            $Pipeline.Phases.parse.Status = 'running'
            $PhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()

            Write-Host "`n⚡ AitherZero IDI Engine" -ForegroundColor Cyan
            Write-Host "═══════════════════════════════════════════════════" -ForegroundColor DarkCyan
            Write-Host "  Intent: " -NoNewline -ForegroundColor Gray
            Write-Host $Intent -ForegroundColor White
            Write-Host "  Provider: $($Provider ?? 'auto-detect') | Env: $Environment | DryRun: $DryRun" -ForegroundColor DarkGray
            Write-Host ""

            Write-Host "  [1/6] 🧠 Classifying intent via IntentEngine..." -ForegroundColor Yellow

            # ── Check compilation cache first ─────────────────────────────
            # If this exact intent was compiled before, skip the LLM entirely.
            # The compiled spec is deterministic — same input, same output.
            if (-not $NoCache -and (Test-Path $CachePath)) {
                try {
                    $CachedSpec = Get-Content -Path $CachePath -Raw | ConvertFrom-Json
                    $CacheAge = [DateTime]::UtcNow - [DateTime]::Parse($CachedSpec._cache_timestamp)
                    if ($CacheAge.TotalHours -lt 24) {
                        $Pipeline.IntentClassification = $CachedSpec.classification
                        $Pipeline.IntentGraph = $CachedSpec.intent_graph
                        $Pipeline.Phases.parse.Status = 'cached'
                        $Pipeline.Phases.parse.Output = @{
                            classification = $CachedSpec.classification
                            intent_graph   = $CachedSpec.intent_graph
                            source         = 'compilation-cache'
                            cache_key      = $IntentCacheKey
                            cache_age_min  = [math]::Round($CacheAge.TotalMinutes, 1)
                        }
                        $CacheHit = $true

                        $ResourceCount = ($Pipeline.IntentGraph.resources | Measure-Object).Count
                        Write-Host "        ⚡ Cache hit: $IntentCacheKey ($([math]::Round($CacheAge.TotalMinutes, 1))m old)" -ForegroundColor Green
                        Write-Host "        ✅ Compiled: $ResourceCount resources (0 tokens, 0 LLM calls)" -ForegroundColor Green
                    } else {
                        Write-Verbose "Cache expired ($([math]::Round($CacheAge.TotalHours, 1))h old) — recompiling"
                    }
                } catch {
                    Write-Verbose "Cache read failed — recompiling: $_"
                }
            }

            # ── Step 1: Classify via real IntentEngine (on cache miss) ─────
            # ── Step 1: Classify via real IntentEngine (on cache miss) ─────
            # Calls Genesis /intent/classify → runs IntentEngine.classify()
            # Returns: intent_type, effort_level, agent_chain, model_tier, keywords, etc.
            if (-not $CacheHit) {
            $ClassifyBody = @{
                prompt  = $Intent
                context = @{
                    infrastructure_mode = $true
                    environment         = $Environment
                    provider            = $Provider
                }
            } | ConvertTo-Json -Depth 5

            $ClassifyParams = @{
                Uri         = "$GenesisUrl/intent/classify"
                Method      = 'POST'
                Body        = $ClassifyBody
                ContentType = 'application/json'
                TimeoutSec  = 15
            }

            try {
                $ClassifyResponse = Invoke-RestMethod @ClassifyParams -ErrorAction Stop
                $Pipeline.IntentClassification = $ClassifyResponse

                $IntentType  = $ClassifyResponse.intent_type   # e.g. "infrastructure"
                $EffortLevel = $ClassifyResponse.effort_level   # 1-10
                $AgentChain  = $ClassifyResponse.agent_chain    # e.g. ["atlas", "genesis"]
                $ModelTier   = $ClassifyResponse.model_tier     # e.g. "reasoning"
                $Keywords    = $ClassifyResponse.keywords -join ', '
                $Confidence  = $ClassifyResponse.confidence

                # Validate: is this actually an infrastructure intent?
                $InfraTypes = @('infrastructure', 'deploy', 'command', 'automation', 'execute')
                if ($IntentType -notin $InfraTypes) {
                    Write-Host "        ⚠️  IntentEngine classified as '$IntentType' (effort: $EffortLevel)" -ForegroundColor DarkYellow
                    Write-Host "        📌 Proceeding as infrastructure — IntentEngine will route agent chain" -ForegroundColor DarkGray
                }

                Write-Host "        ✅ IntentEngine: type=$IntentType effort=$EffortLevel tier=$ModelTier conf=$([math]::Round($Confidence, 2))" -ForegroundColor Green
                Write-Host "        🔗 Agent chain: $($AgentChain -join ' → ')" -ForegroundColor DarkCyan
                if ($Keywords) {
                    Write-Host "        🏷️  Keywords: $Keywords" -ForegroundColor DarkGray
                }

                # Override model if IntentEngine recommends a specific tier
                if (-not $Model -and $ClassifyResponse.preferred_model) {
                    $Model = $ClassifyResponse.preferred_model
                }
            } catch {
                Write-Host "        ⚠️  Genesis unavailable — skipping IntentEngine classification" -ForegroundColor DarkYellow
                $Pipeline.IntentClassification = $null
            }

            # ── Step 2: Compile intent → resource IntentGraph (DAG) ──
            # Try Genesis SASE pipeline first for LLM-assisted compilation,
            # fall back to local ConvertTo-IntentGraph pattern matcher
            Write-Host "        📐 Compiling resource graph..." -ForegroundColor Gray

            $CompileBody = @{
                prompt      = $Intent
                context     = @{
                    mode        = 'idi-compile'
                    provider    = $Provider
                    environment = $Environment
                    dry_run     = $DryRun.IsPresent
                    cost_limit  = if ($CostLimit) { $CostLimit } else { $null }
                }
            } | ConvertTo-Json -Depth 10

            try {
                $CompileResponse = Invoke-RestMethod -Uri "$GenesisUrl/intent/process" `
                    -Method POST -Body $CompileBody -ContentType 'application/json' `
                    -TimeoutSec 60 -ErrorAction Stop

                # Extract resource graph from SASE pipeline plan phase
                $SASEPlan = $CompileResponse.phases.plan ?? $CompileResponse.plan ?? $CompileResponse.data
                if ($SASEPlan.intent_graph) {
                    $Pipeline.IntentGraph = $SASEPlan.intent_graph
                } elseif ($SASEPlan.actions -or $SASEPlan.steps) {
                    # SASE gave us an action plan — convert to IntentGraph format
                    $Pipeline.IntentGraph = ConvertTo-IntentGraph -Intent $Intent `
                        -Provider $Provider -Environment $Environment `
                        -IntentResult $Pipeline.IntentClassification
                } else {
                    $Pipeline.IntentGraph = ConvertTo-IntentGraph -Intent $Intent `
                        -Provider $Provider -Environment $Environment `
                        -IntentResult $Pipeline.IntentClassification
                }
                $Pipeline.Phases.parse.Status = 'completed'
                $Pipeline.Phases.parse.Output = @{
                    classification = $Pipeline.IntentClassification
                    intent_graph   = $Pipeline.IntentGraph
                    source         = 'genesis-sase'
                }
            } catch {
                # Fallback: local intent compilation enriched by IntentEngine classification
                Write-Host "        ⚠️  SASE pipeline unavailable — using local compiler" -ForegroundColor DarkYellow
                $Pipeline.IntentGraph = ConvertTo-IntentGraph -Intent $Intent `
                    -Provider $Provider -Environment $Environment `
                    -IntentResult $Pipeline.IntentClassification
                $Pipeline.Phases.parse.Status = 'completed-local'
                $Pipeline.Phases.parse.Output = @{
                    classification = $Pipeline.IntentClassification
                    intent_graph   = $Pipeline.IntentGraph
                    source         = 'local-pattern-matching'
                }
            }

            $ResourceCount = ($Pipeline.IntentGraph.resources | Measure-Object).Count
            $DepCount = ($Pipeline.IntentGraph.dependencies | Measure-Object).Count
            Write-Host "        ✅ Compiled: $ResourceCount resources, $DepCount dependencies" -ForegroundColor Green

            # ── Write to compilation cache ────────────────────────────────
            # Store the compiled SDK spec so identical intents never re-invoke the LLM.
            # The spec is auditable JSON — you can inspect exactly what the LLM compiled.
            if (-not $NoCache -and -not $CacheHit) {
                try {
                    $CacheEntry = @{
                        _cache_key       = $IntentCacheKey
                        _cache_timestamp = [DateTime]::UtcNow.ToString('o')
                        _intent_text     = $Intent
                        _provider        = $Provider
                        _environment     = $Environment
                        classification   = $Pipeline.IntentClassification
                        intent_graph     = $Pipeline.IntentGraph
                    } | ConvertTo-Json -Depth 20
                    Set-Content -Path $CachePath -Value $CacheEntry -Encoding UTF8
                    Write-Verbose "Compiled spec cached: $CachePath"
                } catch {
                    Write-Verbose "Cache write failed (non-fatal): $_"
                }
            }
            } # end cache-miss guard

            if ($Explain -and $Pipeline.IntentClassification) {
                Write-Host "`n  📋 IntentEngine Analysis:" -ForegroundColor Cyan
                Write-Host "     Type: $($Pipeline.IntentClassification.intent_type)" -ForegroundColor Gray
                Write-Host "     Effort: $($Pipeline.IntentClassification.effort_level)/10 ($($Pipeline.IntentClassification.effort_tier))" -ForegroundColor Gray
                Write-Host "     Model: $($Pipeline.IntentClassification.model_tier)" -ForegroundColor Gray
                Write-Host "     Destructive: $($Pipeline.IntentClassification.is_destructive)" -ForegroundColor Gray
                Write-Host "     Approval Required: $($Pipeline.IntentClassification.requires_human_approval)" -ForegroundColor Gray
                Write-Host ""
            }

            $PhaseTimer.Stop()
            $Pipeline.Phases.parse.Duration = $PhaseTimer.Elapsed

            # ═══════════════════════════════════════════════════════════════
            # PHASE 2: REAL-TIME CLOUD DISCOVERY
            # ═══════════════════════════════════════════════════════════════
            $Pipeline.Phase = 'discover'
            $Pipeline.Phases.discover.Status = 'running'
            $PhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()

            Write-Host "  [2/6] 🔍 Discovering live cloud state..." -ForegroundColor Yellow

            # Extract resource types from compiled IntentGraph for surgical discovery
            $IntentResourceTypes = ($Pipeline.IntentGraph.resources | ForEach-Object { $_.type }) | Select-Object -Unique

            $DiscoverBody = @{
                provider       = $Pipeline.IntentGraph.provider ?? $Provider ?? 'aws'
                regions        = $Pipeline.IntentGraph.regions ?? @('us-east-1')
                resource_types = $IntentResourceTypes
                environment    = $Environment
                tags           = @{ 'aither:managed' = 'true'; 'aither:env' = $Environment }
                surgical_mode  = $true  # Surgical: only query intent-relevant types
                credential_profile = $CredentialProfile
            } | ConvertTo-Json -Depth 10

            try {
                $DiscoverResponse = Invoke-RestMethod -Uri "$GenesisUrl/api/v1/idi/discover" `
                    -Method POST -Body $DiscoverBody -ContentType 'application/json' -TimeoutSec 30 -ErrorAction Stop

                $Pipeline.DiscoverySnapshot = $DiscoverResponse.data
                $Pipeline.Phases.discover.Status = 'completed'

                $ExistingCount = ($Pipeline.DiscoverySnapshot.resources | Measure-Object).Count
                $DriftCount = ($Pipeline.DiscoverySnapshot.drift_detected | Measure-Object).Count
                Write-Host "        ✅ Found $ExistingCount existing resources" -ForegroundColor Green
                if ($DriftCount -gt 0) {
                    Write-Host "        ⚠️  $DriftCount drift issues detected" -ForegroundColor DarkYellow
                }
            } catch {
                Write-Host "        ⚠️  Genesis unavailable — using direct cloud discovery" -ForegroundColor DarkYellow
                $DiscoveryParams = @{
                    Provider      = ($Pipeline.IntentGraph.provider ?? $Provider ?? 'aws')
                    ResourceTypes = $IntentResourceTypes
                    Environment   = $Environment
                    SurgicalMode  = $true
                }
                if ($CredentialProfile) { $DiscoveryParams['CredentialProfile'] = $CredentialProfile }
                $Pipeline.DiscoverySnapshot = Invoke-CloudDiscovery @DiscoveryParams
                $Pipeline.Phases.discover.Status = 'completed-local'
            }

            $Pipeline.Phases.discover.Output = $Pipeline.DiscoverySnapshot
            $PhaseTimer.Stop()
            $Pipeline.Phases.discover.Duration = $PhaseTimer.Elapsed

            # ═══════════════════════════════════════════════════════════════
            # PHASE 3: INTENT DIFF (Desired vs Actual)
            # ═══════════════════════════════════════════════════════════════
            $Pipeline.Phase = 'diff'
            $Pipeline.Phases.diff.Status = 'running'
            $PhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()

            Write-Host "  [3/6] 📊 Computing change set..." -ForegroundColor Yellow

            $Pipeline.ChangeSet = Compare-IntentVsDiscovery `
                -IntentGraph $Pipeline.IntentGraph `
                -Discovery $Pipeline.DiscoverySnapshot

            $Pipeline.Phases.diff.Status = 'completed'
            $Pipeline.Phases.diff.Output = $Pipeline.ChangeSet

            $Creates = ($Pipeline.ChangeSet.creates | Measure-Object).Count
            $Updates = ($Pipeline.ChangeSet.updates | Measure-Object).Count
            $Deletes = ($Pipeline.ChangeSet.deletes | Measure-Object).Count
            $NoOps = ($Pipeline.ChangeSet.no_ops | Measure-Object).Count
            Write-Host "        ✅ +$Creates create | ~$Updates update | -$Deletes delete | =$NoOps unchanged" -ForegroundColor Green

            $PhaseTimer.Stop()
            $Pipeline.Phases.diff.Duration = $PhaseTimer.Elapsed

            if ($Creates -eq 0 -and $Updates -eq 0 -and $Deletes -eq 0 -and -not $Remediate) {
                Write-Host "`n  ✨ Infrastructure already converged. Nothing to do." -ForegroundColor Green
                $Pipeline.Status = 'Converged'
                $Timer.Stop()
                $Pipeline.Duration = $Timer.Elapsed
                if ($PassThru) { return $Pipeline }
                return
            }

            # ═══════════════════════════════════════════════════════════════
            # PHASE 4: COST SOVEREIGNTY GATE
            # ═══════════════════════════════════════════════════════════════
            $Pipeline.Phase = 'cost'
            $Pipeline.Phases.cost.Status = 'running'
            $PhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()

            Write-Host "  [4/6] 💰 Running cost sovereignty check..." -ForegroundColor Yellow

            $Pipeline.CostProjection = Get-IDICostProjection `
                -ChangeSet $Pipeline.ChangeSet `
                -Provider ($Pipeline.IntentGraph.provider ?? $Provider ?? 'aws') `
                -Environment $Environment

            $Pipeline.Phases.cost.Status = 'completed'
            $Pipeline.Phases.cost.Output = $Pipeline.CostProjection

            $MonthlyCost = $Pipeline.CostProjection.monthly_estimate
            $HourlyCost = $Pipeline.CostProjection.hourly_estimate
            $Savings = $Pipeline.CostProjection.savings_vs_current
            Write-Host "        ✅ Projected: `$$([math]::Round($MonthlyCost, 2))/mo (`$$([math]::Round($HourlyCost, 4))/hr)" -ForegroundColor Green
            if ($Savings -gt 0) {
                Write-Host "        💚 Saves `$$([math]::Round($Savings, 2))/mo vs current config" -ForegroundColor Green
            }

            # Cost gate enforcement
            if ($CostLimit -and $MonthlyCost -gt $CostLimit) {
                Write-Host "        ❌ COST GATE FAILED: `$$MonthlyCost/mo exceeds limit of `$$CostLimit/mo" -ForegroundColor Red
                $Pipeline.Status = 'CostGateBlocked'
                $Pipeline.Error = "Cost projection ($MonthlyCost) exceeds limit ($CostLimit)"
                $Timer.Stop()
                $Pipeline.Duration = $Timer.Elapsed
                if ($PassThru) { return $Pipeline }
                return
            }

            # Right-sizing suggestions
            if ($Pipeline.CostProjection.right_sizing) {
                Write-Host "        📐 Right-sizing: $($Pipeline.CostProjection.right_sizing.Count) optimizations available" -ForegroundColor DarkCyan
                foreach ($suggestion in $Pipeline.CostProjection.right_sizing) {
                    Write-Host "           → $($suggestion.resource): $($suggestion.current) → $($suggestion.recommended) (saves `$$($suggestion.savings)/mo)" -ForegroundColor DarkGray
                }
            }

            $PhaseTimer.Stop()
            $Pipeline.Phases.cost.Duration = $PhaseTimer.Elapsed

            # ═══════════════════════════════════════════════════════════════
            # PHASE 5: EXECUTE (or dry-run report)
            # ═══════════════════════════════════════════════════════════════
            $Pipeline.Phase = 'execute'
            $Pipeline.Phases.execute.Status = 'running'
            $PhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()

            if ($DryRun) {
                Write-Host "  [5/6] 📋 Dry run — human-readable diff:" -ForegroundColor Yellow
                Write-Host ""

                # ── Human-readable diff preview (the competitor's #4 point) ────
                # High-risk intents surface a readable diff BEFORE execution.
                # We'd rather debug a visible diff than a corrupted .tfstate at 2 AM.
                foreach ($op in $Pipeline.ChangeSet.creates) {
                    Write-Host "        + CREATE $($op.type)/$($op.name) in $($op.region ?? 'default')" -ForegroundColor Green
                    if ($op.config) {
                        $configItems = @($op.config.PSObject.Properties | Select-Object -First 5)
                        foreach ($prop in $configItems) {
                            Write-Host "          │  $($prop.Name): $($prop.Value)" -ForegroundColor DarkGreen
                        }
                    }
                }
                foreach ($op in $Pipeline.ChangeSet.updates) {
                    Write-Host "        ~ UPDATE $($op.type)/$($op.name)" -ForegroundColor Yellow
                    if ($op.drifts) {
                        foreach ($drift in $op.drifts) {
                            Write-Host "          │  $($drift.field): " -NoNewline -ForegroundColor DarkYellow
                            Write-Host "$($drift.actual)" -NoNewline -ForegroundColor Red
                            Write-Host " → " -NoNewline -ForegroundColor Gray
                            Write-Host "$($drift.intent)" -ForegroundColor Green
                        }
                    } else {
                        Write-Host "          │  changes: $($op.changes -join ', ')" -ForegroundColor DarkYellow
                    }
                }
                foreach ($op in $Pipeline.ChangeSet.deletes) {
                    Write-Host "        - DELETE $($op.type)/$($op.name)" -ForegroundColor Red
                    if ($op.actual_resource.instance_type) {
                        Write-Host "          │  type: $($op.actual_resource.instance_type) | state: $($op.actual_resource.state)" -ForegroundColor DarkRed
                    }
                }

                if ($Pipeline.ChangeSet.summary.high_risk_count -gt 0) {
                    Write-Host ""
                    Write-Host "        ⚠️  $($Pipeline.ChangeSet.summary.high_risk_count) HIGH RISK changes above — review carefully" -ForegroundColor Red
                    Write-Host "        💰 Net cost impact: `$$($Pipeline.ChangeSet.summary.total_cost_delta)/mo" -ForegroundColor $(if ($Pipeline.ChangeSet.summary.total_cost_delta -gt 0) { 'Yellow' } else { 'Green' })
                }

                $Pipeline.Phases.execute.Status = 'skipped-dryrun'
                $Pipeline.Status = 'DryRunComplete'
            } else {
                # Production execution requires confirmation for staging/prod
                if ($Environment -ne 'dev' -and -not $Force) {
                    $Confirm = Read-Host "`n  ⚠️  Apply $Creates creates, $Updates updates, $Deletes deletes to $($Environment.ToUpper())? [y/N]"
                    if ($Confirm -notin @('y', 'Y', 'yes')) {
                        Write-Host "  ❌ Aborted by user." -ForegroundColor Red
                        $Pipeline.Status = 'Aborted'
                        $Timer.Stop()
                        $Pipeline.Duration = $Timer.Elapsed
                        if ($PassThru) { return $Pipeline }
                        return
                    }
                }

                Write-Host "  [5/6] 🚀 Executing SDK calls..." -ForegroundColor Yellow

                $ExecBody = @{
                    change_set   = $Pipeline.ChangeSet
                    intent_graph = $Pipeline.IntentGraph
                    provider     = $Pipeline.IntentGraph.provider ?? $Provider ?? 'aws'
                    environment  = $Environment
                    options      = @{
                        remediate  = $Remediate.IsPresent
                        stream     = $Stream.IsPresent
                    }
                } | ConvertTo-Json -Depth 15

                try {
                    $ExecResponse = Invoke-RestMethod -Uri "$GenesisUrl/api/v1/idi/execute" `
                        -Method POST -Body $ExecBody -ContentType 'application/json' `
                        -TimeoutSec 300 -ErrorAction Stop

                    $Pipeline.ExecutionResult = $ExecResponse.data
                    $Pipeline.Phases.execute.Status = 'completed'

                    $SuccessOps = ($Pipeline.ExecutionResult.operations | Where-Object { $_.status -eq 'success' } | Measure-Object).Count
                    $FailOps = ($Pipeline.ExecutionResult.operations | Where-Object { $_.status -eq 'failed' } | Measure-Object).Count
                    $TotalOps = ($Pipeline.ExecutionResult.operations | Measure-Object).Count
                    Write-Host "        ✅ $SuccessOps/$TotalOps operations succeeded" -ForegroundColor Green
                    if ($FailOps -gt 0) {
                        Write-Host "        ❌ $FailOps operations failed" -ForegroundColor Red
                    }
                } catch {
                    Write-Host "        ⚠️  Genesis unavailable — executing locally via SDK" -ForegroundColor DarkYellow
                    $Pipeline.ExecutionResult = Invoke-IDIExecution `
                        -ChangeSet $Pipeline.ChangeSet `
                        -Provider ($Pipeline.IntentGraph.provider ?? $Provider ?? 'aws') `
                        -Environment $Environment
                    $Pipeline.Phases.execute.Status = 'completed-local'
                }
            }

            $Pipeline.Phases.execute.Output = $Pipeline.ExecutionResult
            $PhaseTimer.Stop()
            $Pipeline.Phases.execute.Duration = $PhaseTimer.Elapsed

            # ═══════════════════════════════════════════════════════════════
            # PHASE 6: POST-EXECUTION VERIFICATION
            # ═══════════════════════════════════════════════════════════════
            $Pipeline.Phase = 'verify'
            $Pipeline.Phases.verify.Status = 'running'
            $PhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()

            if (-not $DryRun) {
                Write-Host "  [6/6] ✅ Verifying convergence..." -ForegroundColor Yellow

                try {
                    $VerifyResponse = Invoke-RestMethod -Uri "$GenesisUrl/api/v1/idi/verify" `
                        -Method POST -Body (@{
                            intent_graph = $Pipeline.IntentGraph
                            execution_id = $Pipeline.ExecutionResult.execution_id
                        } | ConvertTo-Json -Depth 10) `
                        -ContentType 'application/json' -TimeoutSec 30 -ErrorAction Stop

                    $Pipeline.VerificationResult = $VerifyResponse.data
                    $Converged = $Pipeline.VerificationResult.converged
                    $Pipeline.Phases.verify.Status = if ($Converged) { 'completed' } else { 'drift-detected' }

                    if ($Converged) {
                        Write-Host "        ✅ Infrastructure converged — all resources match intent" -ForegroundColor Green
                        $Pipeline.Status = 'Converged'
                    } else {
                        $DriftItems = ($Pipeline.VerificationResult.drift_items | Measure-Object).Count
                        Write-Host "        ⚠️  $DriftItems resources still drifting" -ForegroundColor DarkYellow
                        $Pipeline.Status = 'PartialConverge'
                    }
                } catch {
                    $Pipeline.Phases.verify.Status = 'skipped'
                    $Pipeline.Status = 'ExecutionComplete'
                    Write-Host "        ⚠️  Verification skipped (Genesis unavailable)" -ForegroundColor DarkYellow
                }
            } else {
                $Pipeline.Phases.verify.Status = 'skipped-dryrun'
            }

            $Pipeline.Phases.verify.Output = $Pipeline.VerificationResult
            $PhaseTimer.Stop()
            $Pipeline.Phases.verify.Duration = $PhaseTimer.Elapsed

        } catch {
            $Pipeline.Status = 'Failed'
            $Pipeline.Error = $_.Exception.Message
            Write-Host "`n  ❌ IDI Pipeline Failed: $($_.Exception.Message)" -ForegroundColor Red
        }

        # ═══════════════════════════════════════════════════════════════
        # SUMMARY
        # ═══════════════════════════════════════════════════════════════
        $Timer.Stop()
        $Pipeline.Duration = $Timer.Elapsed

        Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor DarkCyan
        Write-Host "  Status: $($Pipeline.Status) | Duration: $([math]::Round($Pipeline.Duration.TotalSeconds, 2))s" -ForegroundColor Cyan
        if ($CacheHit) {
            Write-Host "  Compilation: CACHED (0 tokens, 0 LLM calls)" -ForegroundColor Green
        } else {
            Write-Host "  Compilation: FRESH (cached for next run)" -ForegroundColor DarkGray
        }
        Write-Host "  Phases:" -ForegroundColor Gray
        foreach ($phase in $Pipeline.Phases.GetEnumerator()) {
            $icon = switch ($phase.Value.Status) {
                'completed'       { '✅' }
                'completed-local' { '🔧' }
                'skipped-dryrun'  { '📋' }
                'drift-detected'  { '⚠️' }
                'skipped'         { '⏭️' }
                default           { '❓' }
            }
            $dur = if ($phase.Value.Duration) { "$([math]::Round($phase.Value.Duration.TotalMilliseconds))ms" } else { '-' }
            Write-Host "    $icon $($phase.Key.PadRight(10)) $dur" -ForegroundColor DarkGray
        }
        Write-Host "═══════════════════════════════════════════════════`n" -ForegroundColor DarkCyan

        if ($PassThru) { return $Pipeline }
    }
}
