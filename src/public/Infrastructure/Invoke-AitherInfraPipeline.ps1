#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    End-to-end infrastructure deployment pipeline: Intent → HCL → Git → Plan → Approve → Apply → Deploy.

.DESCRIPTION
    Invoke-AitherInfraPipeline is the master orchestrator for the AitherZero infrastructure
    deployment workflow. It chains the entire IDI pipeline with OpenTofu provisioning and
    AitherComet mesh deployment into a single, auditable pipeline.

    Pipeline stages:
    1. INTENT       — Parse natural language via IDI (Invoke-AitherIntent)
    2. GRAPH        — Compile IntentGraph DAG (ConvertTo-IntentGraph)
    3. GENERATE     — Convert IntentGraph to OpenTofu HCL (ConvertTo-OpenTofuConfig)
    4. COMMIT       — Git commit generated configs to infra repo
    5. VALIDATE     — tofu validate + policy checks (checkov)
    6. PLAN         — tofu plan with output capture
    7. COST         — Cost projection gate (Get-IDICostProjection)
    8. APPROVE      — Approval gate (auto for dev, Genesis for staging/prod)
    9. APPLY        — tofu apply
    10. DEPLOY      — Post-provision deployment via AitherComet (containers/services)
    11. VERIFY      — Health checks and drift baseline
    12. REPORT      — Strata telemetry + Flux event emission

    Integration points:
    - IDI pipeline: Invoke-AitherIntent, ConvertTo-IntentGraph, Get-IDICostProjection
    - OpenTofu: Invoke-AitherInfra (plan/apply/init/validate)
    - Git: Sync-InfraState (commit configs + state)
    - AitherComet: POST /v1/unified for container/service deployment
    - Genesis: /infra/requests for approval workflow
    - Strata: /api/v1/ingest/ide-session for telemetry
    - Flux: Event emission for pipeline lifecycle events

.PARAMETER Intent
    Natural language infrastructure intent (shortcut for full IDI flow).

.PARAMETER IntentGraph
    Pre-compiled IntentGraph (skip stages 1-2).

.PARAMETER HCLPath
    Pre-generated HCL directory (skip stages 1-3).

.PARAMETER InfraRepoPath
    Path to the infrastructure repository. Auto-detected from config or current dir.

.PARAMETER Environment
    Target environment: dev, staging, prod.

.PARAMETER Provider
    Target provider override.

.PARAMETER Strategy
    HCL generation strategy: Module, Inline, Hybrid.

.PARAMETER Backend
    State backend: local, s3, azurerm, gcs.

.PARAMETER BackendConfig
    Backend configuration hashtable.

.PARAMETER AutoApprove
    Skip approval gate (dev only unless -Force).

.PARAMETER SkipDeploy
    Skip AitherComet post-provision deployment.

.PARAMETER SkipCommit
    Skip Git commit of generated configs.

.PARAMETER DryRun
    Run entire pipeline in dry-run mode (no apply, no deploy).

.PARAMETER Force
    Override all safety gates.

.PARAMETER CometUrl
    AitherComet endpoint. Default: http://localhost:8125.

.PARAMETER GenesisUrl
    Genesis backend URL. Default: http://localhost:8001.

.PARAMETER PassThru
    Return the pipeline result object.

.EXAMPLE
    # Full pipeline from natural language
    Invoke-AitherInfraPipeline -Intent "Deploy 3 Redis nodes with 6GB memory in us-east-1" -Environment dev

.EXAMPLE
    # Pipeline with pre-compiled IntentGraph
    $Graph = ConvertTo-IntentGraph -Intent "Create a VPC with 3 subnets" -Provider aws
    Invoke-AitherInfraPipeline -IntentGraph $Graph -Environment staging

.EXAMPLE
    # Dry-run pipeline for production
    Invoke-AitherInfraPipeline -Intent "Scale ECS to 5 instances" -Environment prod -DryRun

.NOTES
    Part of AitherZero Infrastructure pipeline.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Invoke-AitherInfraPipeline {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ParameterSetName = 'FromIntent')]
        [string]$Intent,

        [Parameter(ParameterSetName = 'FromGraph', ValueFromPipeline)]
        [PSCustomObject]$IntentGraph,

        [Parameter(ParameterSetName = 'FromHCL')]
        [string]$HCLPath,

        [string]$InfraRepoPath,

        [ValidateSet('dev', 'staging', 'prod')]
        [string]$Environment = 'dev',

        [ValidateSet('aws', 'azure', 'gcp', 'docker', 'kubernetes', 'multi')]
        [string]$Provider,

        [ValidateSet('Module', 'Inline', 'Hybrid')]
        [string]$Strategy = 'Module',

        [ValidateSet('local', 's3', 'azurerm', 'gcs')]
        [string]$Backend = 'local',

        [hashtable]$BackendConfig = @{},

        [switch]$AutoApprove,

        [switch]$SkipDeploy,

        [switch]$SkipCommit,

        [switch]$DryRun,

        [switch]$Force,

        [string]$CometUrl = 'http://localhost:8125',

        [string]$GenesisUrl = 'http://localhost:8001',

        [switch]$PassThru
    )

    $PipelineId = "pipe-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([Guid]::NewGuid().ToString('N').Substring(0,6))"
    $StartTime = [DateTime]::UtcNow
    $StageResults = [ordered]@{}
    $PipelineStatus = 'running'
    $CurrentStage = ''

    # ── Pipeline banner ───────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  🚀 AitherZero Infrastructure Pipeline                      ║" -ForegroundColor Cyan
    Write-Host "  ║  Pipeline: $PipelineId                      ║" -ForegroundColor Cyan
    Write-Host "  ║  Environment: $($Environment.PadRight(47))║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    function _Stage {
        param([string]$Name, [string]$Icon, [scriptblock]$Action)
        $CurrentStage = $Name
        $StageTimer = [System.Diagnostics.Stopwatch]::StartNew()

        Write-Host "  [$Icon] Stage: $Name" -ForegroundColor White

        try {
            $result = & $Action
            $StageTimer.Stop()

            $StageResults[$Name] = [PSCustomObject]@{
                status      = 'success'
                duration_ms = $StageTimer.ElapsedMilliseconds
                result      = $result
            }
            Write-Host "      ✅ $Name completed ($($StageTimer.ElapsedMilliseconds)ms)" -ForegroundColor Green
            return $result
        } catch {
            $StageTimer.Stop()
            $StageResults[$Name] = [PSCustomObject]@{
                status      = 'failed'
                duration_ms = $StageTimer.ElapsedMilliseconds
                error       = $_.Exception.Message
            }
            Write-Host "      ❌ $Name FAILED: $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
    }

    try {
        # ══════════════════════════════════════════════════════════════════
        # STAGE 1: INTENT — Parse natural language
        # ══════════════════════════════════════════════════════════════════
        if ($Intent -and -not $IntentGraph -and -not $HCLPath) {
            $IntentResult = _Stage -Name 'INTENT' -Icon '🧠' -Action {
                $intentParams = @{ Intent = $Intent; GenesisUrl = $GenesisUrl }
                if ($DryRun) { $intentParams['DryRun'] = $true }
                Invoke-AitherIntent @intentParams -PassThru
            }
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 2: GRAPH — Compile IntentGraph
        # ══════════════════════════════════════════════════════════════════
        if (-not $IntentGraph -and -not $HCLPath) {
            $IntentGraph = _Stage -Name 'GRAPH' -Icon '📊' -Action {
                $graphParams = @{
                    Intent      = $Intent
                    Environment = $Environment
                }
                if ($Provider) { $graphParams['Provider'] = $Provider }
                if ($IntentResult) { $graphParams['IntentResult'] = $IntentResult }
                ConvertTo-IntentGraph @graphParams
            }
        }

        if ($IntentGraph -and -not $Provider) {
            $Provider = $IntentGraph.provider
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 3: GENERATE — Convert IntentGraph → HCL
        # ══════════════════════════════════════════════════════════════════
        if (-not $HCLPath) {
            # Determine output directory
            if ($InfraRepoPath) {
                $HCLPath = Join-Path $InfraRepoPath 'environments' $Environment
            } else {
                # Auto-detect infra repo or use temp
                $InfraRepoPath = _Find-InfraRepo
                if ($InfraRepoPath) {
                    $HCLPath = Join-Path $InfraRepoPath 'environments' $Environment
                } else {
                    $HCLPath = Join-Path ([System.IO.Path]::GetTempPath()) "aither-infra-$PipelineId" $Environment
                }
            }

            $GenerateResult = _Stage -Name 'GENERATE' -Icon '📝' -Action {
                $genParams = @{
                    IntentGraph      = $IntentGraph
                    OutputPath       = $HCLPath
                    Strategy         = $Strategy
                    Backend          = $Backend
                    BackendConfig    = $BackendConfig
                    PassThru         = $true
                }
                if ($DryRun) { $genParams['DryRun'] = $true }
                ConvertTo-OpenTofuConfig @genParams
            }
        } else {
            # Using pre-generated HCL
            $StageResults['GENERATE'] = [PSCustomObject]@{
                status = 'skipped'
                result = @{ path = $HCLPath }
            }
            Write-Host "  [⏭️] Stage: GENERATE — Using pre-generated HCL at $HCLPath" -ForegroundColor DarkGray
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 4: COMMIT — Git commit generated configs
        # ══════════════════════════════════════════════════════════════════
        if (-not $SkipCommit -and -not $DryRun -and $InfraRepoPath -and (Test-Path (Join-Path $InfraRepoPath '.git'))) {
            _Stage -Name 'COMMIT' -Icon '📦' -Action {
                Push-Location $InfraRepoPath
                try {
                    $IntentHash = $IntentGraph.intent_hash ?? 'manual'
                    git add -A 2>&1 | Out-Null
                    $status = git status --porcelain 2>&1
                    if ($status) {
                        git commit -m "infra($Environment): update from IDI pipeline [$IntentHash]" 2>&1 | Out-Null
                        Write-Host "        Committed changes to $Environment" -ForegroundColor DarkGray
                    } else {
                        Write-Host "        No changes to commit" -ForegroundColor DarkGray
                    }
                } finally {
                    Pop-Location
                }
                return @{ committed = [bool]$status }
            }
        } else {
            $StageResults['COMMIT'] = [PSCustomObject]@{ status = 'skipped' }
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 5: VALIDATE — tofu validate + policy check
        # ══════════════════════════════════════════════════════════════════
        if (Test-Path $HCLPath) {
            $ValidateResult = _Stage -Name 'VALIDATE' -Icon '🔍' -Action {
                $validation = @{ tofu_valid = $false; policy_pass = $true }

                # OpenTofu validate
                $infraResult = Invoke-AitherInfra -Action Validate -Provider ($Provider ?? 'docker') `
                    -WorkspacePath $HCLPath -PassThru -ErrorAction SilentlyContinue

                if ($infraResult -and $infraResult.Status -eq 'Valid') {
                    $validation.tofu_valid = $true
                } elseif ($DryRun) {
                    $validation.tofu_valid = $true  # Accept in dry-run
                    Write-Host "        (dry-run: skipping actual validation)" -ForegroundColor DarkGray
                }

                # Checkov policy check (if available)
                if (Get-Command 'checkov' -ErrorAction SilentlyContinue) {
                    $policyDir = Join-Path $InfraRepoPath 'policies' -ErrorAction SilentlyContinue
                    $checkovArgs = @('-d', $HCLPath, '--framework', 'terraform', '--quiet')
                    if ($policyDir -and (Test-Path (Join-Path $policyDir 'checkov.yaml'))) {
                        $checkovArgs += @('--config-file', (Join-Path $policyDir 'checkov.yaml'))
                    }
                    try {
                        checkov @checkovArgs 2>&1 | Out-Null
                    } catch {
                        $validation.policy_pass = $false
                        Write-Host "        ⚠️  Policy check failed" -ForegroundColor DarkYellow
                    }
                }

                return $validation
            }
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 6: PLAN — tofu plan
        # ══════════════════════════════════════════════════════════════════
        $PlanResult = _Stage -Name 'PLAN' -Icon '📋' -Action {
            if ($DryRun) {
                Write-Host "        (dry-run: simulating plan)" -ForegroundColor DarkGray
                return @{ status = 'PlanReady'; output = '(dry-run)'; changes = $IntentGraph.resources.Count }
            }

            $planParams = @{
                Action        = 'Plan'
                Provider      = $Provider ?? 'docker'
                Environment   = $Environment
                WorkspacePath = $HCLPath
                PassThru      = $true
            }
            $result = Invoke-AitherInfra @planParams
            return @{
                status  = $result.Status
                output  = $result.Output
                changes = if ($result.Output -match '(\d+) to add') { [int]$Matches[1] } else { 0 }
            }
        }

        # Check plan result
        if ($PlanResult.status -eq 'PlanFailed' -and -not $DryRun) {
            throw "Plan failed. Review plan output and fix configuration."
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 7: COST — Cost projection
        # ══════════════════════════════════════════════════════════════════
        $CostResult = $null
        if ($IntentGraph) {
            $CostResult = _Stage -Name 'COST' -Icon '💰' -Action {
                # Build a lightweight changeset for cost estimation
                $changes = @($IntentGraph.resources | ForEach-Object {
                    [PSCustomObject]@{
                        action          = $_.action
                        intent_resource = $_
                    }
                })
                $changeSet = [PSCustomObject]@{
                    changes     = $changes
                    environment = $Environment
                    summary     = @{
                        creates = ($changes | Where-Object { $_.action -eq 'create' }).Count
                        updates = ($changes | Where-Object { $_.action -eq 'update' }).Count
                        destroys = ($changes | Where-Object { $_.action -eq 'destroy' }).Count
                    }
                }
                Get-IDICostProjection -ChangeSet $changeSet
            }
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 8: APPROVE — Approval gate
        # ══════════════════════════════════════════════════════════════════
        $Approved = _Stage -Name 'APPROVE' -Icon '🔐' -Action {
            if ($DryRun) {
                Write-Host "        (dry-run: auto-approved)" -ForegroundColor DarkGray
                return $true
            }

            # Dev auto-approves
            if ($Environment -eq 'dev' -or $AutoApprove -or $Force) {
                Write-Host "        Auto-approved ($Environment)" -ForegroundColor DarkGray
                return $true
            }

            # Staging/prod → Genesis approval
            try {
                $reqBody = @{
                    provider    = $Provider
                    environment = $Environment
                    changes     = $PlanResult.changes
                    cost        = $CostResult.totals ?? @{}
                    pipeline_id = $PipelineId
                    hcl_path    = $HCLPath
                    intent      = $IntentGraph.intent ?? ''
                } | ConvertTo-Json -Depth 5

                $resp = Invoke-RestMethod -Uri "$GenesisUrl/infra/requests" -Method POST `
                    -Body $reqBody -ContentType 'application/json' -TimeoutSec 30

                Write-Host "        📝 Request $($resp.id) submitted to Genesis" -ForegroundColor Yellow
                Write-Host "        ⏳ Waiting for approval..." -ForegroundColor Yellow

                # Poll for approval (max 5 minutes)
                $MaxWait = 300
                $Elapsed = 0
                while ($Elapsed -lt $MaxWait) {
                    Start-Sleep -Seconds 10
                    $Elapsed += 10
                    $statusResp = Invoke-RestMethod -Uri "$GenesisUrl/infra/requests/$($resp.id)/status" `
                        -Method Get -ErrorAction SilentlyContinue
                    if ($statusResp.status -eq 'approved') {
                        Write-Host "        ✅ Approved!" -ForegroundColor Green
                        return $true
                    } elseif ($statusResp.status -eq 'rejected') {
                        Write-Host "        ❌ Rejected: $($statusResp.reason)" -ForegroundColor Red
                        return $false
                    }
                    Write-Host "        ⏳ ($($Elapsed)s / ${MaxWait}s) Status: $($statusResp.status)" -ForegroundColor DarkGray
                }

                Write-Host "        ⏰ Approval timed out" -ForegroundColor Red
                return $false
            } catch {
                Write-Host "        ⚠️  Genesis not reachable. Use -Force or -AutoApprove." -ForegroundColor DarkYellow
                return $false
            }
        }

        if (-not $Approved -and -not $DryRun) {
            $PipelineStatus = 'blocked'
            throw "Pipeline blocked: approval not granted for $Environment"
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 9: APPLY — tofu apply
        # ══════════════════════════════════════════════════════════════════
        $ApplyResult = _Stage -Name 'APPLY' -Icon '🚀' -Action {
            if ($DryRun) {
                Write-Host "        (dry-run: skipping apply)" -ForegroundColor DarkGray
                return @{ status = 'dry-run'; output = '' }
            }

            $applyParams = @{
                Action        = 'Apply'
                Provider      = $Provider ?? 'docker'
                Environment   = $Environment
                WorkspacePath = $HCLPath
                AutoApprove   = $true
                PassThru      = $true
            }
            if ($Force) { $applyParams['Force'] = $true }
            $result = Invoke-AitherInfra @applyParams
            return @{ status = $result.Status; output = $result.Output }
        }

        if ($ApplyResult.status -eq 'ApplyFailed' -and -not $DryRun) {
            throw "Apply failed. Infrastructure may be in a partial state."
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 10: DEPLOY — Post-provision via AitherComet
        # ══════════════════════════════════════════════════════════════════
        if (-not $SkipDeploy -and $IntentGraph) {
            _Stage -Name 'DEPLOY' -Icon '🌐' -Action {
                if ($DryRun) {
                    Write-Host "        (dry-run: skipping Comet deployment)" -ForegroundColor DarkGray
                    return @{ status = 'dry-run' }
                }

                $DeployableResources = @($IntentGraph.resources | Where-Object {
                    $_.type -match 'docker:|k8s:|ecs:'
                })

                if ($DeployableResources.Count -eq 0) {
                    Write-Host "        No deployable resources (IaC-only)" -ForegroundColor DarkGray
                    return @{ status = 'skipped'; reason = 'no deployable resources' }
                }

                $deployResults = @()

                foreach ($res in $DeployableResources) {
                    $deploySpec = @{
                        name        = $res.name
                        image       = $res.config.image ?? "ghcr.io/aitherium/$($res.name):latest"
                        environment = $Environment
                        replicas    = $res.quantity ?? 1
                        strategy    = 'rolling'
                        target      = switch -Wildcard ($res.type) {
                            'docker:*' { 'docker' }
                            'k8s:*'    { 'kubernetes' }
                            'ecs:*'    { 'docker-compose' }
                            default    { 'docker' }
                        }
                        ports       = @($res.config.ports ?? @(8080))
                        env         = @{ AITHER_DOCKER_MODE = 'true'; LOG_LEVEL = 'INFO' }
                        labels      = @{ 'aither.pipeline' = $PipelineId; 'aither.env' = $Environment }
                    }

                    try {
                        $resp = Invoke-RestMethod -Uri "$CometUrl/v1/unified" -Method POST `
                            -Body ($deploySpec | ConvertTo-Json -Depth 5) `
                            -ContentType 'application/json' -TimeoutSec 60
                        $deployResults += @{ name = $res.name; status = 'deployed'; deployment_id = $resp.deployment_id }
                        Write-Host "        🚀 $($res.name): deployed" -ForegroundColor Green
                    } catch {
                        $deployResults += @{ name = $res.name; status = 'failed'; error = $_.Exception.Message }
                        Write-Host "        ⚠️  $($res.name): $($_.Exception.Message)" -ForegroundColor DarkYellow
                    }
                }

                return @{ status = 'completed'; deployments = $deployResults }
            }
        } else {
            $StageResults['DEPLOY'] = [PSCustomObject]@{ status = 'skipped' }
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 11: VERIFY — Health checks
        # ══════════════════════════════════════════════════════════════════
        _Stage -Name 'VERIFY' -Icon '✔️' -Action {
            if ($DryRun) {
                Write-Host "        (dry-run: skipping verification)" -ForegroundColor DarkGray
                return @{ status = 'dry-run' }
            }

            # Check infra state
            $stateCheck = Invoke-AitherInfra -Action Status -Provider ($Provider ?? 'docker') `
                -WorkspacePath $HCLPath -PassThru -ErrorAction SilentlyContinue

            $healthy = $stateCheck -and $stateCheck.Status -in @('Active', 'OK')

            # If Comet deployed services, check their health
            if ($StageResults.ContainsKey('DEPLOY') -and $StageResults['DEPLOY'].result.deployments) {
                foreach ($dep in $StageResults['DEPLOY'].result.deployments) {
                    if ($dep.status -eq 'deployed') {
                        try {
                            $healthResp = Invoke-RestMethod -Uri "$CometUrl/v1/deployments/$($dep.deployment_id)/health" `
                                -Method Get -TimeoutSec 10 -ErrorAction SilentlyContinue
                            $dep.healthy = $healthResp.healthy ?? $true
                        } catch {
                            $dep.healthy = $null  # Unknown
                        }
                    }
                }
            }

            return @{ infra_status = $stateCheck.Status; healthy = $healthy }
        }

        # ══════════════════════════════════════════════════════════════════
        # STAGE 12: SYNC — Push state back to repo
        # ══════════════════════════════════════════════════════════════════
        if (-not $DryRun -and -not $SkipCommit -and $InfraRepoPath) {
            _Stage -Name 'SYNC' -Icon '🔄' -Action {
                try {
                    Sync-InfraState -RepoPath $InfraRepoPath -Environment $Environment `
                        -WorkspacePath $HCLPath -PassThru
                } catch {
                    Write-Host "        ⚠️  State sync skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow
                    return @{ status = 'skipped' }
                }
            }
        }

        $PipelineStatus = if ($DryRun) { 'dry-run-complete' } else { 'success' }

    } catch {
        if ($PipelineStatus -eq 'running') { $PipelineStatus = 'failed' }
        Write-Host "`n  ❌ Pipeline failed at stage '$CurrentStage': $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        # ══════════════════════════════════════════════════════════════════
        # STAGE 12: REPORT — Telemetry
        # ══════════════════════════════════════════════════════════════════
        $CompletedTime = [DateTime]::UtcNow
        $TotalDuration = ($CompletedTime - $StartTime).TotalMilliseconds

        $Report = [PSCustomObject]@{
            pipeline_id   = $PipelineId
            status        = $PipelineStatus
            environment   = $Environment
            provider      = $Provider
            intent        = $Intent ?? $IntentGraph.intent ?? 'manual'
            intent_hash   = $IntentGraph.intent_hash ?? ''
            dry_run       = $DryRun.IsPresent
            started_at    = $StartTime.ToString('o')
            completed_at  = $CompletedTime.ToString('o')
            duration_ms   = [math]::Round($TotalDuration)
            stages        = $StageResults
            hcl_path      = $HCLPath
            infra_repo    = $InfraRepoPath
        }

        # Emit to Strata
        try {
            $strataUrl = $env:AITHER_STRATA_URL ?? 'http://localhost:8136'
            $telemetryBody = @{
                event_type  = "infra.pipeline.$PipelineStatus"
                pipeline_id = $PipelineId
                environment = $Environment
                provider    = $Provider
                duration_ms = [math]::Round($TotalDuration)
                stages      = ($StageResults.GetEnumerator() | ForEach-Object {
                    @{ name = $_.Key; status = $_.Value.status; duration_ms = $_.Value.duration_ms }
                })
                timestamp   = $CompletedTime.ToString('o')
                source      = 'aitherzero-infra-pipeline'
            } | ConvertTo-Json -Depth 5

            Invoke-RestMethod -Uri "$strataUrl/api/v1/ingest/ide-session" -Method POST `
                -Body $telemetryBody -ContentType 'application/json' `
                -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-Verbose "Strata telemetry skipped"
        }

        # Emit Flux event
        try {
            $fluxBody = @{
                event  = "infra.pipeline.$PipelineStatus"
                source = 'aitherzero-infra-pipeline'
                data   = @{
                    pipeline_id = $PipelineId
                    environment = $Environment
                    provider    = $Provider
                    duration_ms = [math]::Round($TotalDuration)
                    stages      = @($StageResults.Keys)
                }
            } | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$GenesisUrl/api/v1/flux/emit" -Method POST `
                -Body $fluxBody -ContentType 'application/json' `
                -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-Verbose "Flux event emission skipped"
        }

        # Pipeline summary
        $StatusIcon = switch ($PipelineStatus) {
            'success'          { '✅' }
            'dry-run-complete' { '📋' }
            'failed'           { '❌' }
            'blocked'          { '🔒' }
            default            { '❓' }
        }
        $StatusColor = switch ($PipelineStatus) {
            'success'          { 'Green' }
            'dry-run-complete' { 'Cyan' }
            'failed'           { 'Red' }
            'blocked'          { 'Yellow' }
            default            { 'Gray' }
        }

        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor $StatusColor
        Write-Host "  ║  $StatusIcon Pipeline $($PipelineStatus.ToUpper().PadRight(51))║" -ForegroundColor $StatusColor
        Write-Host "  ╠══════════════════════════════════════════════════════════════╣" -ForegroundColor $StatusColor

        foreach ($stage in $StageResults.GetEnumerator()) {
            $sIcon = switch ($stage.Value.status) { 'success' { '✅' } 'failed' { '❌' } 'skipped' { '⏭️' } default { '⚪' } }
            $sDur = if ($stage.Value.duration_ms) { "$($stage.Value.duration_ms)ms" } else { '-' }
            $Line = "  ║  $sIcon $($stage.Key.PadRight(12)) $($stage.Value.status.PadRight(10)) $($sDur.PadLeft(8))          ║"
            Write-Host $Line -ForegroundColor $StatusColor
        }

        Write-Host "  ╠══════════════════════════════════════════════════════════════╣" -ForegroundColor $StatusColor
        Write-Host "  ║  Duration: $([math]::Round($TotalDuration / 1000, 1))s                                           ║" -ForegroundColor $StatusColor
        Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor $StatusColor
    }

    if ($PassThru) { return $Report }
}


# ══════════════════════════════════════════════════════════════════════════════
# Internal: Find infrastructure repository
# ══════════════════════════════════════════════════════════════════════════════

function _Find-InfraRepo {
    # Check environment variable
    if ($env:AITHER_INFRA_REPO -and (Test-Path $env:AITHER_INFRA_REPO)) {
        return $env:AITHER_INFRA_REPO
    }

    # Check library/infrastructure
    $LibInfra = Join-Path $PSScriptRoot '..\..\..\..\library\infrastructure' -Resolve -ErrorAction SilentlyContinue
    if ($LibInfra -and (Test-Path (Join-Path $LibInfra '.aither-infra.json'))) {
        return $LibInfra
    }

    # Check for .aither-infra.json in current directory
    if (Test-Path '.aither-infra.json') {
        return (Get-Location).Path
    }

    # Check library/infrastructure itself has modules/
    if ($LibInfra -and (Test-Path (Join-Path $LibInfra 'modules'))) {
        return $LibInfra
    }

    return $null
}

Export-ModuleMember -Function Invoke-AitherInfraPipeline
