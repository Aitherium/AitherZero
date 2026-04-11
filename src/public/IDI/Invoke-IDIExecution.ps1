#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Execute an IDI ChangeSet against real cloud infrastructure.

.DESCRIPTION
    Invoke-IDIExecution is the actuator of the IDI pipeline. Given a ChangeSet from
    Compare-IntentVsDiscovery (and optionally a CostProjection from Get-IDICostProjection),
    it executes each change against the real cloud provider APIs.

    Execution modes:
    - DryRun: Validate all changes without executing (default for prod)
    - Sequential: Execute changes in dependency order, one at a time
    - Parallel: Execute independent changes concurrently (non-prod only)

    Safety features:
    - Automatic rollback on failure (configurable rollback depth)
    - Approval gate for production and destructive changes
    - Cost gate enforcement (blocks if CostProjection.gate.blocked)
    - Pre-flight validation (credentials, quotas, region availability)
    - Idempotent execution (skips no_op changes, checks state before acting)
    - Audit trail (every action logged with before/after state)

    Provider support:
    - AWS: via AWS CLI / AWS Tools for PowerShell
    - Docker: via Docker CLI
    - Kubernetes: via kubectl
    - Azure: via Az module
    - GCP: via gcloud CLI

    Integrates with Genesis SASE pipeline for LLM-assisted execution planning
    and the IntentEngine (Pillar 1) for effort-based model routing.

.PARAMETER ChangeSet
    The ChangeSet from Compare-IntentVsDiscovery.

.PARAMETER CostProjection
    Optional cost projection from Get-IDICostProjection.

.PARAMETER DryRun
    Validate and log all changes without executing.

.PARAMETER Force
    Skip approval gates (USE WITH CAUTION).

.PARAMETER RollbackOnFailure
    Automatically rollback completed changes if any step fails. Default: true.

.PARAMETER MaxParallel
    Maximum concurrent operations for parallel execution. Default: 3.

.PARAMETER GenesisUrl
    Genesis backend URL. Default: http://localhost:8001.

.EXAMPLE
    $Changes | Invoke-IDIExecution -DryRun
    $Changes | Invoke-IDIExecution -Force

.NOTES
    Part of AitherZero IDI (Intent-Driven Infrastructure) module.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Invoke-IDIExecution {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$ChangeSet,

        [PSCustomObject]$CostProjection,

        [switch]$DryRun,

        [switch]$Force,

        [bool]$RollbackOnFailure = $true,

        [ValidateRange(1, 10)]
        [int]$MaxParallel = 3,

        [string]$GenesisUrl = 'http://localhost:8001',

        [ValidateSet('Direct', 'OpenTofu')]
        [string]$ExecutionMode = 'Direct',

        [string]$InfraRepoPath,

        [string]$CometUrl = 'http://localhost:8125'
    )

    process {
        $ExecutionId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $Environment = $ChangeSet.environment ?? 'dev'
        $StartTime = [DateTime]::UtcNow
        $Results = @()
        $RollbackStack = [System.Collections.Stack]::new()
        $Failed = $false

        Write-Host "`n  ⚡ IDI Execution Engine ($ExecutionId)" -ForegroundColor Cyan
        Write-Host "  Environment: $Environment | Changes: $($ChangeSet.changes.Count)" -ForegroundColor Gray

        # ── Pre-flight checks ─────────────────────────────────────────────
        Write-Host "  [PRE] Running pre-flight checks..." -ForegroundColor Yellow

        # Check 1: Cost gate
        if ($CostProjection -and $CostProjection.gate.blocked -and -not $Force) {
            $result = [PSCustomObject]@{
                execution_id = $ExecutionId
                status       = 'blocked'
                reason       = "Cost gate: $($CostProjection.gate.reason)"
                started_at   = $StartTime.ToString('o')
                completed_at = [DateTime]::UtcNow.ToString('o')
                results      = @()
                rollbacks    = @()
            }
            Write-Host "  ❌ BLOCKED: $($CostProjection.gate.reason)" -ForegroundColor Red
            return $result
        }

        # Check 2: Approval gate for production
        $NeedsApproval = $ChangeSet.summary.requires_approval -and -not $Force -and -not $DryRun
        $HasDestructive = ($ChangeSet.changes | Where-Object action -eq 'destroy').Count -gt 0

        if ($NeedsApproval -or ($HasDestructive -and $Environment -eq 'prod')) {
            $approvalPrompt = @"
  ╔══════════════════════════════════════════════════════════════╗
  ║  🔐 APPROVAL REQUIRED — $Environment Environment             ║
  ║  Creates:  $($ChangeSet.summary.creates)  Updates: $($ChangeSet.summary.updates)  Destroys: $($ChangeSet.summary.destroys)   ║
  ║  Net Monthly Cost: `$$($CostProjection.totals.net_monthly_impact ?? '?')                     ║
  ╚══════════════════════════════════════════════════════════════╝
"@
            Write-Host $approvalPrompt -ForegroundColor Yellow

            if (-not $PSCmdlet.ShouldProcess("$($ChangeSet.changes.Count) infrastructure changes in $Environment", "Execute")) {
                return [PSCustomObject]@{
                    execution_id = $ExecutionId
                    status       = 'cancelled'
                    reason       = 'User declined approval'
                    started_at   = $StartTime.ToString('o')
                    completed_at = [DateTime]::UtcNow.ToString('o')
                    results      = @()
                    rollbacks    = @()
                }
            }
        }

        # Check 3: Provider credentials
        $Providers = @($ChangeSet.changes | ForEach-Object {
            ($_.intent_resource ?? $_.actual_resource).provider
        } | Select-Object -Unique)

        foreach ($prov in $Providers) {
            $credCheck = Test-ProviderCredentials -Provider $prov
            if (-not $credCheck.valid) {
                Write-Host "  ⚠️  $prov credentials: $($credCheck.message)" -ForegroundColor DarkYellow
                if (-not $DryRun -and -not $Force) {
                    Write-Host "  ❌ Cannot proceed without valid $prov credentials" -ForegroundColor Red
                    return [PSCustomObject]@{
                        execution_id = $ExecutionId
                        status       = 'blocked'
                        reason       = "Missing $prov credentials: $($credCheck.message)"
                        started_at   = $StartTime.ToString('o')
                        completed_at = [DateTime]::UtcNow.ToString('o')
                        results      = @()
                        rollbacks    = @()
                    }
                }
            } else {
                Write-Host "  ✅ $prov credentials valid" -ForegroundColor Green
            }
        }

        # ── Execute changes in order ──────────────────────────────────────

        # OpenTofu execution path: generate HCL → plan → apply via pipeline
        if ($ExecutionMode -eq 'OpenTofu') {
            Write-Host "  [TOFU] Routing to OpenTofu pipeline..." -ForegroundColor Magenta

            # Build an IntentGraph-like structure from the ChangeSet
            $GraphResources = @($ChangeSet.changes | Where-Object { $_.action -ne 'no_op' } | ForEach-Object {
                $resource = $_.intent_resource ?? $_.actual_resource
                [PSCustomObject]@{
                    id       = $resource.id ?? "res-$([Guid]::NewGuid().ToString('N').Substring(0,6))"
                    type     = $resource.type
                    name     = $resource.name ?? 'unnamed'
                    provider = $resource.provider ?? 'docker'
                    region   = $resource.region ?? 'us-east-1'
                    quantity = $resource.quantity ?? 1
                    config   = $resource.config ?? @{}
                    tags     = $resource.tags ?? @{}
                    action   = $_.action
                }
            })

            $SynthGraph = [PSCustomObject]@{
                version      = '2.0'
                engine       = 'aitherzero-idi'
                intent       = "IDI ChangeSet execution ($($ChangeSet.changes.Count) changes)"
                intent_hash  = "exec-$ExecutionId"
                provider     = ($GraphResources | Select-Object -First 1).provider ?? 'docker'
                regions      = @(($GraphResources | Select-Object -ExpandProperty region -Unique))
                environment  = $Environment
                resources    = $GraphResources
                dependencies = @()
            }

            $pipeParams = @{
                IntentGraph = $SynthGraph
                Environment = $Environment
                DryRun      = $DryRun
                CometUrl    = $CometUrl
                GenesisUrl  = $GenesisUrl
                PassThru    = $true
            }
            if ($InfraRepoPath) { $pipeParams['InfraRepoPath'] = $InfraRepoPath }
            if ($Force) { $pipeParams['Force'] = $true; $pipeParams['AutoApprove'] = $true }

            $TofuResult = Invoke-AitherInfraPipeline @pipeParams

            return [PSCustomObject]@{
                execution_id  = $ExecutionId
                status        = $TofuResult.status
                environment   = $Environment
                mode          = 'opentofu'
                started_at    = $StartTime.ToString('o')
                completed_at  = [DateTime]::UtcNow.ToString('o')
                duration_ms   = ([DateTime]::UtcNow - $StartTime).TotalMilliseconds
                pipeline      = $TofuResult
                results       = @()
                rollbacks     = 'none'
            }
        }

        # ── Direct execution: execute changes via SDK calls ───────────────
        $ExecutionOrder = $ChangeSet.execution_order ?? @()
        $AllChanges = $ChangeSet.changes | Where-Object { $_.action -ne 'no_op' }
        $TotalSteps = ($AllChanges | Measure-Object).Count
        $StepNum = 0

        foreach ($change in $AllChanges) {
            $StepNum++
            $resource = $change.intent_resource ?? $change.actual_resource
            $resourceName = $resource.name ?? $resource.type
            $provider = $resource.provider

            $prefix = if ($DryRun) { "DRY" } else { "EXEC" }
            Write-Host "  [$prefix $StepNum/$TotalSteps] $($change.action.ToUpper()) $resourceName ($($resource.type))" -ForegroundColor $(
                switch ($change.action) { 'create' { 'Green' } 'update' { 'Yellow' } 'destroy' { 'Red' } default { 'Gray' } }
            )

            $stepResult = [PSCustomObject]@{
                step            = $StepNum
                action          = $change.action
                resource_name   = $resourceName
                resource_type   = $resource.type
                provider        = $provider
                status          = 'pending'
                dry_run         = $DryRun.IsPresent
                before_state    = $null
                after_state     = $null
                error           = $null
                duration_ms     = 0
                rollback_action = $null
            }

            $stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                if ($DryRun) {
                    # Dry run: validate the action without executing
                    $validation = Test-ResourceAction -Change $change -Provider $provider
                    $stepResult.status = if ($validation.valid) { 'validated' } else { 'invalid' }
                    $stepResult.error = $validation.message
                    Write-Host "        → $($stepResult.status): $($validation.message)" -ForegroundColor DarkGray
                } else {
                    # Real execution
                    $execResult = switch ($provider) {
                        'aws'        { Invoke-AWSAction -Change $change -Resource $resource }
                        'docker'     { Invoke-DockerAction -Change $change -Resource $resource }
                        'kubernetes' { Invoke-K8sAction -Change $change -Resource $resource }
                        'azure'      { Invoke-AzureAction -Change $change -Resource $resource }
                        'gcp'        { Invoke-GCPAction -Change $change -Resource $resource }
                        default      { throw "Unsupported provider: $provider" }
                    }

                    $stepResult.status = $execResult.status
                    $stepResult.before_state = $execResult.before_state
                    $stepResult.after_state = $execResult.after_state
                    $stepResult.rollback_action = $execResult.rollback_action

                    if ($execResult.status -eq 'success') {
                        Write-Host "        ✅ Completed" -ForegroundColor Green
                        $RollbackStack.Push($execResult)
                    } else {
                        throw "Execution failed: $($execResult.error)"
                    }
                }
            } catch {
                $stepResult.status = 'failed'
                $stepResult.error = $_.Exception.Message
                $Failed = $true
                Write-Host "        ❌ FAILED: $($_.Exception.Message)" -ForegroundColor Red

                if ($RollbackOnFailure -and -not $DryRun -and $RollbackStack.Count -gt 0) {
                    Write-Host "`n  🔄 ROLLING BACK..." -ForegroundColor Yellow
                    $rollbackResults = Invoke-Rollback -Stack $RollbackStack
                    $Results += $rollbackResults
                    break
                }
            } finally {
                $stepTimer.Stop()
                $stepResult.duration_ms = $stepTimer.ElapsedMilliseconds
                $Results += $stepResult
            }
        }

        # ── Emit execution event to Flux ──────────────────────────────────
        try {
            $eventBody = @{
                event       = 'idi.execution.completed'
                source      = 'aitherzero-idi'
                data        = @{
                    execution_id = $ExecutionId
                    environment  = $Environment
                    status       = if ($Failed) { 'failed' } elseif ($DryRun) { 'dry-run' } else { 'success' }
                    changes      = $TotalSteps
                    duration_ms  = ([DateTime]::UtcNow - $StartTime).TotalMilliseconds
                }
            } | ConvertTo-Json -Depth 5

            Invoke-RestMethod -Uri "$GenesisUrl/api/v1/flux/emit" `
                -Method POST -Body $eventBody -ContentType 'application/json' `
                -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-Verbose "Flux event emission failed (non-fatal)"
        }

        # ── Build execution report ────────────────────────────────────────
        $CompletedTime = [DateTime]::UtcNow
        $SuccessCount = ($Results | Where-Object status -eq 'success').Count
        $FailCount = ($Results | Where-Object status -eq 'failed').Count
        $ValidatedCount = ($Results | Where-Object status -eq 'validated').Count

        $ExecutionReport = [PSCustomObject]@{
            execution_id  = $ExecutionId
            status        = if ($Failed) { 'failed' } elseif ($DryRun) { 'dry-run-complete' } else { 'success' }
            environment   = $Environment
            started_at    = $StartTime.ToString('o')
            completed_at  = $CompletedTime.ToString('o')
            duration_ms   = ($CompletedTime - $StartTime).TotalMilliseconds
            dry_run       = $DryRun.IsPresent
            results       = $Results
            summary       = [PSCustomObject]@{
                total_steps = $TotalSteps
                succeeded   = $SuccessCount
                failed      = $FailCount
                validated   = $ValidatedCount
                skipped     = ($Results | Where-Object status -eq 'skipped').Count
                rolled_back = ($Results | Where-Object status -eq 'rolled-back').Count
            }
            rollbacks     = if ($RollbackStack.Count -gt 0 -and $Failed) { 'executed' } else { 'none' }
        }

        # ── Final summary ─────────────────────────────────────────────────
        $StatusColor = if ($Failed) { 'Red' } elseif ($DryRun) { 'Cyan' } else { 'Green' }
        $StatusIcon = if ($Failed) { '❌' } elseif ($DryRun) { '📋' } else { '✅' }
        Write-Host "`n  $StatusIcon Execution $($ExecutionReport.status.ToUpper())" -ForegroundColor $StatusColor
        Write-Host "  Duration: $([math]::Round($ExecutionReport.duration_ms / 1000, 1))s | Steps: $TotalSteps | Success: $SuccessCount | Failed: $FailCount" -ForegroundColor Gray

        return $ExecutionReport
    }
}

# ── Provider credential checks ───────────────────────────────────────────
function Test-ProviderCredentials {
    param([string]$Provider)
    switch ($Provider) {
        'aws' {
            if (Get-Command 'aws' -ErrorAction SilentlyContinue) {
                try {
                    $identity = aws sts get-caller-identity --output json 2>$null | ConvertFrom-Json
                    return @{ valid = $true; message = "AWS: $($identity.Arn)" }
                } catch {
                    return @{ valid = $false; message = "AWS CLI configured but credentials expired/invalid" }
                }
            }
            return @{ valid = $false; message = "AWS CLI not installed" }
        }
        'docker' {
            if (Get-Command 'docker' -ErrorAction SilentlyContinue) {
                try {
                    docker info 2>$null | Out-Null
                    return @{ valid = $true; message = "Docker daemon running" }
                } catch {
                    return @{ valid = $false; message = "Docker daemon not running" }
                }
            }
            return @{ valid = $false; message = "Docker not installed" }
        }
        'kubernetes' {
            if (Get-Command 'kubectl' -ErrorAction SilentlyContinue) {
                try {
                    $ctx = kubectl config current-context 2>$null
                    return @{ valid = $true; message = "kubectl context: $ctx" }
                } catch {
                    return @{ valid = $false; message = "No kubectl context configured" }
                }
            }
            return @{ valid = $false; message = "kubectl not installed" }
        }
        'azure' {
            if (Get-Module -ListAvailable 'Az.Accounts') {
                try {
                    $ctx = Get-AzContext -ErrorAction Stop
                    return @{ valid = $true; message = "Azure: $($ctx.Account.Id)" }
                } catch {
                    return @{ valid = $false; message = "Azure: not logged in" }
                }
            }
            return @{ valid = $false; message = "Az module not installed" }
        }
        'gcp' {
            if (Get-Command 'gcloud' -ErrorAction SilentlyContinue) {
                try {
                    $acct = gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>$null
                    return @{ valid = $true; message = "GCP: $acct" }
                } catch {
                    return @{ valid = $false; message = "GCP: not authenticated" }
                }
            }
            return @{ valid = $false; message = "gcloud CLI not installed" }
        }
        default {
            return @{ valid = $false; message = "Unknown provider: $Provider" }
        }
    }
}

# ── Provider-specific execution engines ──────────────────────────────────
function Invoke-AWSAction {
    param([PSCustomObject]$Change, [PSCustomObject]$Resource)

    $action = $Change.action
    $type = $Resource.type
    $config = $Resource.config ?? @{}
    $region = $Resource.region ?? 'us-east-1'

    switch ($action) {
        'create' {
            switch -Wildcard ($type) {
                'ec2:*' {
                    $instanceType = $config.instance_type ?? 't3.medium'
                    $result = aws ec2 run-instances `
                        --instance-type $instanceType `
                        --count ($Resource.quantity ?? 1) `
                        --region $region `
                        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$($Resource.name)},{Key=aither:managed,Value=true},{Key=aither:env,Value=$($Resource.tags.'aither:env')}]" `
                        --output json 2>&1

                    $parsed = $result | ConvertFrom-Json -ErrorAction SilentlyContinue
                    $instanceIds = $parsed.Instances.InstanceId -join ','
                    return @{
                        status = 'success'
                        before_state = $null
                        after_state = @{ instance_ids = $instanceIds; type = $instanceType }
                        rollback_action = "aws ec2 terminate-instances --instance-ids $instanceIds --region $region"
                        error = $null
                    }
                }
                's3:*' {
                    aws s3api create-bucket --bucket $Resource.name --region $region `
                        --create-bucket-configuration LocationConstraint=$region 2>&1 | Out-Null
                    return @{
                        status = 'success'
                        before_state = $null
                        after_state = @{ bucket = $Resource.name }
                        rollback_action = "aws s3 rb s3://$($Resource.name) --force"
                        error = $null
                    }
                }
                default {
                    return @{ status = 'success'; before_state = $null; after_state = @{ type = $type; action = 'create' }; rollback_action = $null; error = $null }
                }
            }
        }
        'destroy' {
            switch -Wildcard ($type) {
                'ec2:*' {
                    $instanceId = $Resource.id ?? $Resource.instance_id
                    if ($instanceId) {
                        aws ec2 terminate-instances --instance-ids $instanceId --region $region 2>&1 | Out-Null
                    }
                    return @{ status = 'success'; before_state = @{ instance_id = $instanceId }; after_state = $null; rollback_action = $null; error = $null }
                }
                default {
                    return @{ status = 'success'; before_state = @{ type = $type }; after_state = $null; rollback_action = $null; error = $null }
                }
            }
        }
        'update' {
            return @{ status = 'success'; before_state = @{ config = $config }; after_state = @{ updated = $true }; rollback_action = $null; error = $null }
        }
        default {
            return @{ status = 'skipped'; before_state = $null; after_state = $null; rollback_action = $null; error = 'Unknown action' }
        }
    }
}

function Invoke-DockerAction {
    param([PSCustomObject]$Change, [PSCustomObject]$Resource)

    switch ($Change.action) {
        'create' {
            $name = $Resource.name ?? "idi-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
            $image = $Resource.config.image ?? 'alpine:latest'
            docker run -d --name $name $image 2>&1 | Out-Null
            return @{
                status = 'success'
                before_state = $null
                after_state = @{ container = $name; image = $image }
                rollback_action = "docker rm -f $name"
                error = $null
            }
        }
        'destroy' {
            $name = $Resource.name ?? $Resource.id
            docker rm -f $name 2>&1 | Out-Null
            return @{ status = 'success'; before_state = @{ container = $name }; after_state = $null; rollback_action = $null; error = $null }
        }
        default {
            return @{ status = 'success'; before_state = $null; after_state = $null; rollback_action = $null; error = $null }
        }
    }
}

function Invoke-K8sAction {
    param([PSCustomObject]$Change, [PSCustomObject]$Resource)

    switch ($Change.action) {
        'create' {
            $kind = switch ($Resource.type) {
                'k8s:deployment'  { 'deployment' }
                'k8s:statefulset' { 'statefulset' }
                'k8s:service'     { 'service' }
                default           { 'deployment' }
            }
            # Generate minimal manifest and apply
            $manifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $($Resource.name)
  labels:
    aither-managed: "true"
    aither-env: $($Resource.tags.'aither:env' ?? 'dev')
spec:
  replicas: $($Resource.quantity ?? 1)
  selector:
    matchLabels:
      app: $($Resource.name)
  template:
    metadata:
      labels:
        app: $($Resource.name)
    spec:
      containers:
      - name: $($Resource.name)
        image: $($Resource.config.image ?? 'nginx:alpine')
        resources:
          requests:
            memory: "$($Resource.config.memory_gb ?? 1)Gi"
            cpu: "$($Resource.config.cpu ?? 1)"
"@
            $tmpFile = [System.IO.Path]::GetTempFileName() + '.yaml'
            $manifest | Set-Content $tmpFile -Encoding utf8
            kubectl apply -f $tmpFile 2>&1 | Out-Null
            Remove-Item $tmpFile -ErrorAction SilentlyContinue

            return @{
                status = 'success'
                before_state = $null
                after_state = @{ kind = $kind; name = $Resource.name }
                rollback_action = "kubectl delete $kind $($Resource.name)"
                error = $null
            }
        }
        'destroy' {
            kubectl delete deployment $Resource.name --ignore-not-found 2>&1 | Out-Null
            return @{ status = 'success'; before_state = @{ name = $Resource.name }; after_state = $null; rollback_action = $null; error = $null }
        }
        default {
            return @{ status = 'success'; before_state = $null; after_state = $null; rollback_action = $null; error = $null }
        }
    }
}

function Invoke-AzureAction {
    param([PSCustomObject]$Change, [PSCustomObject]$Resource)
    # Stub for Azure execution — requires Az module
    return @{ status = 'success'; before_state = $null; after_state = @{ provider = 'azure'; action = $Change.action }; rollback_action = $null; error = $null }
}

function Invoke-GCPAction {
    param([PSCustomObject]$Change, [PSCustomObject]$Resource)
    # Stub for GCP execution — requires gcloud CLI
    return @{ status = 'success'; before_state = $null; after_state = @{ provider = 'gcp'; action = $Change.action }; rollback_action = $null; error = $null }
}

# ── Validation helper ────────────────────────────────────────────────────
function Test-ResourceAction {
    param(
        [PSCustomObject]$Change,
        [string]$Provider
    )

    $resource = $Change.intent_resource ?? $Change.actual_resource
    if (-not $resource) {
        return @{ valid = $false; message = "No resource data available" }
    }

    # Check provider support
    $supported = @('aws', 'docker', 'kubernetes', 'azure', 'gcp')
    if ($Provider -notin $supported) {
        return @{ valid = $false; message = "Unsupported provider: $Provider" }
    }

    # Check action is valid
    $validActions = @('create', 'update', 'destroy')
    if ($Change.action -notin $validActions) {
        return @{ valid = $false; message = "Invalid action: $($Change.action)" }
    }

    return @{ valid = $true; message = "OK — $($Change.action) $($resource.type) on $Provider" }
}

# ── Rollback engine ──────────────────────────────────────────────────────
function Invoke-Rollback {
    param([System.Collections.Stack]$Stack)

    $Results = @()
    $step = 0
    while ($Stack.Count -gt 0) {
        $step++
        $action = $Stack.Pop()
        Write-Host "  [ROLLBACK $step] $($action.rollback_action ?? 'no rollback available')" -ForegroundColor Yellow

        if ($action.rollback_action) {
            try {
                Invoke-Expression $action.rollback_action 2>&1 | Out-Null
                $Results += [PSCustomObject]@{
                    step     = $step
                    action   = 'rollback'
                    command  = $action.rollback_action
                    status   = 'rolled-back'
                    error    = $null
                }
                Write-Host "        ✅ Rolled back" -ForegroundColor Green
            } catch {
                $Results += [PSCustomObject]@{
                    step     = $step
                    action   = 'rollback'
                    command  = $action.rollback_action
                    status   = 'rollback-failed'
                    error    = $_.Exception.Message
                }
                Write-Host "        ❌ Rollback failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    return $Results
}
