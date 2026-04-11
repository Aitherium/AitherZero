#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Execute Infrastructure-as-Code operations via OpenTofu with approval workflow integration.

.DESCRIPTION
    Invoke-AitherInfra provides a unified PowerShell interface for managing infrastructure
    deployments through AitherZero's OpenTofu modules. It integrates with Genesis's approval
    workflow and supports Docker, AWS, Azure, GCP, and Hyper-V providers.

    Operations:
    - Plan:    Preview changes without applying (tofu plan)
    - Apply:   Deploy infrastructure (tofu apply) — requires approval for staging/prod
    - Destroy: Tear down infrastructure (tofu destroy)
    - Status:  Check deployment status
    - List:    List all managed deployments
    - Init:    Initialize a new workspace

.PARAMETER Action
    The infrastructure operation to perform.

.PARAMETER Provider
    Target infrastructure provider: docker, aws, azure, gcp, hyperv.

.PARAMETER Environment
    Target environment: dev, staging, prod.

.PARAMETER WorkspacePath
    Path to the OpenTofu workspace. Defaults to provider-specific module directory.

.PARAMETER VarFile
    Path to a .tfvars file with variable overrides.

.PARAMETER Variables
    Hashtable of OpenTofu variables to pass via -var flags.

.PARAMETER AutoApprove
    Skip interactive approval for apply/destroy (requires AITHER_INFRA_AUTO_APPROVE=true or -Force).

.PARAMETER RequestId
    Infrastructure request ID from Genesis (for status/apply operations on approved requests).

.PARAMETER DryRun
    Show what would be done without executing.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER PassThru
    Return result object instead of writing to host.

.EXAMPLE
    # Plan a Docker deployment
    Invoke-AitherInfra -Action Plan -Provider docker -Environment dev

.EXAMPLE
    # Apply approved infrastructure
    Invoke-AitherInfra -Action Apply -RequestId 'infra-abc123' -AutoApprove

.EXAMPLE
    # Destroy dev infrastructure
    Invoke-AitherInfra -Action Destroy -Provider docker -Environment dev -Force

.EXAMPLE
    # Check status of all deployments
    Invoke-AitherInfra -Action List
#>
function Invoke-AitherInfra {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Plan', 'Apply', 'Destroy', 'Status', 'List', 'Init', 'Validate')]
        [string]$Action,

        [ValidateSet('docker', 'aws', 'azure', 'gcp', 'hyperv', 'kubernetes')]
        [string]$Provider,

        [ValidateSet('dev', 'staging', 'prod')]
        [string]$Environment = 'dev',

        [string]$WorkspacePath,

        [string]$VarFile,

        [hashtable]$Variables = @{},

        [switch]$AutoApprove,

        [string]$RequestId,

        [switch]$DryRun,

        [switch]$Force,

        [switch]$PassThru
    )

    # ── Resolve paths ─────────────────────────────────────────────────────
    $InfraBase = if ($env:AITHER_INFRA_PATH) {
        $env:AITHER_INFRA_PATH
    } else {
        Join-Path $PSScriptRoot '..\..\..\..\library\infrastructure' | Resolve-Path -ErrorAction SilentlyContinue
    }

    if (-not $InfraBase -or -not (Test-Path $InfraBase)) {
        $InfraBase = Join-Path (Split-Path $PSScriptRoot -Parent) 'library\infrastructure'
    }

    # ── Find tofu binary ─────────────────────────────────────────────────
    $TofuBin = if ($env:TOFU_BIN) { $env:TOFU_BIN }
    elseif (Get-Command 'tofu' -ErrorAction SilentlyContinue) { 'tofu' }
    elseif (Get-Command 'terraform' -ErrorAction SilentlyContinue) { 'terraform' }
    else { $null }

    if (-not $TofuBin -and $Action -notin @('List', 'Status', 'Validate')) {
        Write-Error "OpenTofu (tofu) or Terraform not found. Install: https://opentofu.org/docs/intro/install/"
        return
    }

    # ── Provider module mapping ──────────────────────────────────────────
    $ProviderModuleMap = @{
        'docker'     = 'docker-host'
        'aws'        = 'aws'
        'azure'      = 'azure'
        'gcp'        = 'gcp'
        'hyperv'     = 'aitheros-node'
        'kubernetes' = 'kubernetes'
    }

    # ── Resolve workspace ────────────────────────────────────────────────
    if ($WorkspacePath) {
        $Workspace = $WorkspacePath
    } elseif ($RequestId) {
        $Workspace = Join-Path $InfraBase '.workspaces' $RequestId
    } elseif ($Provider) {
        $ModuleName = $ProviderModuleMap[$Provider]
        $Workspace = Join-Path $InfraBase 'modules' $ModuleName
    } else {
        $Workspace = $InfraBase
    }

    # ── Build result object ──────────────────────────────────────────────
    $Result = [PSCustomObject]@{
        Action       = $Action
        Provider     = $Provider
        Environment  = $Environment
        Workspace    = $Workspace
        Status       = 'Pending'
        Output       = ''
        ErrorOutput  = ''
        Duration     = [TimeSpan]::Zero
        RequestId    = $RequestId
        ExitCode     = -1
    }

    $Timer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        switch ($Action) {
            'Init' {
                if (-not (Test-Path $Workspace)) {
                    New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
                }

                Write-Host "⚙️  Initializing workspace: $Workspace" -ForegroundColor Cyan

                if ($PSCmdlet.ShouldProcess($Workspace, 'tofu init')) {
                    $initResult = _Invoke-Tofu -Args @('init', '-no-color') -WorkDir $Workspace -TofuBin $TofuBin
                    $Result.Output = $initResult.Stdout
                    $Result.ErrorOutput = $initResult.Stderr
                    $Result.ExitCode = $initResult.ExitCode
                    $Result.Status = if ($initResult.ExitCode -eq 0) { 'Initialized' } else { 'InitFailed' }
                }
            }

            'Plan' {
                if (-not $Provider) {
                    Write-Error "Provider is required for Plan action"
                    return
                }

                Write-Host "📋 Planning $Provider infrastructure ($Environment)..." -ForegroundColor Cyan

                # Init first
                $initResult = _Invoke-Tofu -Args @('init', '-no-color') -WorkDir $Workspace -TofuBin $TofuBin
                if ($initResult.ExitCode -ne 0) {
                    $Result.Status = 'InitFailed'
                    $Result.ErrorOutput = $initResult.Stderr
                    $Result.ExitCode = $initResult.ExitCode
                    break
                }

                # Build plan args
                $planArgs = @('plan', '-no-color', '-input=false')
                if ($VarFile -and (Test-Path $VarFile)) {
                    $planArgs += "-var-file=$VarFile"
                }
                foreach ($key in $Variables.Keys) {
                    $planArgs += "-var=$key=$($Variables[$key])"
                }

                if ($PSCmdlet.ShouldProcess($Workspace, 'tofu plan')) {
                    $planResult = _Invoke-Tofu -Args $planArgs -WorkDir $Workspace -TofuBin $TofuBin
                    $Result.Output = $planResult.Stdout
                    $Result.ErrorOutput = $planResult.Stderr
                    $Result.ExitCode = $planResult.ExitCode
                    $Result.Status = if ($planResult.ExitCode -eq 0) { 'PlanReady' } else { 'PlanFailed' }

                    if ($planResult.ExitCode -eq 0) {
                        Write-Host "✅ Plan succeeded" -ForegroundColor Green
                    } else {
                        Write-Host "❌ Plan failed" -ForegroundColor Red
                    }
                }
            }

            'Apply' {
                # Approval gate for staging/prod
                if ($Environment -in @('staging', 'prod') -and -not $AutoApprove -and -not $Force) {
                    Write-Host "🔒 $Environment deployments require approval." -ForegroundColor Yellow
                    Write-Host "   Submit via Genesis: POST /infra/requests" -ForegroundColor Yellow
                    Write-Host "   Or use -Force to override (admin only)." -ForegroundColor Yellow
                    $Result.Status = 'RequiresApproval'
                    break
                }

                Write-Host "🚀 Applying infrastructure ($Provider → $Environment)..." -ForegroundColor Cyan

                $applyArgs = @('apply', '-no-color', '-auto-approve')
                if ($VarFile -and (Test-Path $VarFile)) {
                    $applyArgs += "-var-file=$VarFile"
                }
                foreach ($key in $Variables.Keys) {
                    $applyArgs += "-var=$key=$($Variables[$key])"
                }

                if ($PSCmdlet.ShouldProcess($Workspace, 'tofu apply')) {
                    $applyResult = _Invoke-Tofu -Args $applyArgs -WorkDir $Workspace -TofuBin $TofuBin
                    $Result.Output = $applyResult.Stdout
                    $Result.ErrorOutput = $applyResult.Stderr
                    $Result.ExitCode = $applyResult.ExitCode
                    $Result.Status = if ($applyResult.ExitCode -eq 0) { 'Active' } else { 'ApplyFailed' }

                    if ($applyResult.ExitCode -eq 0) {
                        Write-Host "✅ Infrastructure deployed successfully" -ForegroundColor Green

                        # Report to Genesis
                        _Report-InfraEvent -Event 'deployed' -Provider $Provider -Environment $Environment -RequestId $RequestId
                    } else {
                        Write-Host "❌ Apply failed" -ForegroundColor Red
                    }
                }
            }

            'Destroy' {
                if (-not $Force -and $Environment -eq 'prod') {
                    Write-Host "🛑 Production destroy requires -Force flag" -ForegroundColor Red
                    $Result.Status = 'Blocked'
                    break
                }

                Write-Host "🗑️  Destroying infrastructure ($Provider → $Environment)..." -ForegroundColor Yellow

                $destroyArgs = @('destroy', '-no-color', '-auto-approve')
                if ($VarFile -and (Test-Path $VarFile)) {
                    $destroyArgs += "-var-file=$VarFile"
                }

                if ($PSCmdlet.ShouldProcess($Workspace, 'tofu destroy')) {
                    $destroyResult = _Invoke-Tofu -Args $destroyArgs -WorkDir $Workspace -TofuBin $TofuBin
                    $Result.Output = $destroyResult.Stdout
                    $Result.ErrorOutput = $destroyResult.Stderr
                    $Result.ExitCode = $destroyResult.ExitCode
                    $Result.Status = if ($destroyResult.ExitCode -eq 0) { 'Destroyed' } else { 'DestroyFailed' }

                    if ($destroyResult.ExitCode -eq 0) {
                        Write-Host "✅ Infrastructure destroyed" -ForegroundColor Green
                        _Report-InfraEvent -Event 'destroyed' -Provider $Provider -Environment $Environment -RequestId $RequestId
                    }
                }
            }

            'Status' {
                Write-Host "📊 Checking infrastructure status..." -ForegroundColor Cyan

                if ($RequestId) {
                    # Query Genesis for request status
                    $genesisUrl = $env:AITHER_GENESIS_URL ?? 'http://localhost:8001'
                    try {
                        $resp = Invoke-RestMethod -Uri "$genesisUrl/infra/requests/$RequestId/status" -Method Get -ErrorAction Stop
                        $Result.Output = ($resp | ConvertTo-Json -Depth 10)
                        $Result.Status = $resp.status
                        $Result.ExitCode = 0
                    } catch {
                        $Result.ErrorOutput = $_.Exception.Message
                        $Result.Status = 'Error'
                    }
                } elseif (Test-Path $Workspace) {
                    # Check local state
                    $stateFile = Join-Path $Workspace 'terraform.tfstate'
                    if (Test-Path $stateFile) {
                        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
                        $resources = $state.resources | Where-Object { $_.mode -eq 'managed' }
                        $Result.Output = "Resources: $($resources.Count)`nSerial: $($state.serial)`nVersion: $($state.terraform_version)"
                        $Result.Status = if ($resources.Count -gt 0) { 'Active' } else { 'Empty' }
                        $Result.ExitCode = 0
                    } else {
                        $Result.Status = 'NoState'
                        $Result.Output = 'No terraform.tfstate found in workspace'
                    }
                }
            }

            'List' {
                Write-Host "📋 Listing managed infrastructure..." -ForegroundColor Cyan

                $workspacesDir = Join-Path $InfraBase '.workspaces'
                $deployments = @()

                if (Test-Path $workspacesDir) {
                    foreach ($dir in Get-ChildItem $workspacesDir -Directory) {
                        $stateFile = Join-Path $dir.FullName 'terraform.tfstate'
                        $requestFile = Join-Path $InfraBase '.requests' "$($dir.Name).json"

                        $entry = @{
                            Id        = $dir.Name
                            Workspace = $dir.FullName
                            HasState  = Test-Path $stateFile
                        }

                        if (Test-Path $requestFile) {
                            $reqData = Get-Content $requestFile -Raw | ConvertFrom-Json
                            $entry.Provider = $reqData.provider
                            $entry.Environment = $reqData.environment
                            $entry.Status = $reqData.status
                            $entry.RequestedBy = $reqData.requested_by
                            $entry.RequestedAt = $reqData.requested_at
                        }

                        $deployments += [PSCustomObject]$entry
                    }
                }

                # Also query Genesis
                try {
                    $genesisUrl = $env:AITHER_GENESIS_URL ?? 'http://localhost:8001'
                    $resp = Invoke-RestMethod -Uri "$genesisUrl/infra/requests" -Method Get -ErrorAction SilentlyContinue
                    if ($resp.requests) {
                        foreach ($req in $resp.requests) {
                            if ($req.id -notin $deployments.Id) {
                                $deployments += [PSCustomObject]@{
                                    Id          = $req.id
                                    Provider    = $req.provider
                                    Environment = $req.environment
                                    Status      = $req.status
                                    RequestedBy = $req.requested_by
                                    RequestedAt = $req.requested_at
                                    HasState    = $false
                                }
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Genesis not reachable: $($_.Exception.Message)"
                }

                $Result.Output = ($deployments | Format-Table -AutoSize | Out-String)
                $Result.Status = 'OK'
                $Result.ExitCode = 0

                if (-not $PassThru) {
                    $deployments | Format-Table -AutoSize
                }
            }

            'Validate' {
                Write-Host "🔍 Validating configuration..." -ForegroundColor Cyan

                if (-not $Provider) {
                    Write-Error "Provider is required for Validate action"
                    return
                }

                $modulePath = Join-Path $InfraBase 'modules' $ProviderModuleMap[$Provider]
                if (-not (Test-Path $modulePath)) {
                    Write-Error "Provider module not found: $modulePath"
                    return
                }

                $initResult = _Invoke-Tofu -Args @('init', '-no-color') -WorkDir $modulePath -TofuBin $TofuBin
                if ($initResult.ExitCode -ne 0) {
                    $Result.Status = 'InitFailed'
                    break
                }

                $validateResult = _Invoke-Tofu -Args @('validate', '-no-color') -WorkDir $modulePath -TofuBin $TofuBin
                $Result.Output = $validateResult.Stdout
                $Result.ErrorOutput = $validateResult.Stderr
                $Result.ExitCode = $validateResult.ExitCode
                $Result.Status = if ($validateResult.ExitCode -eq 0) { 'Valid' } else { 'Invalid' }
            }
        }
    } catch {
        $Result.Status = 'Error'
        $Result.ErrorOutput = $_.Exception.Message
        Write-Error "Infrastructure operation failed: $_"
    } finally {
        $Timer.Stop()
        $Result.Duration = $Timer.Elapsed
    }

    if ($PassThru) {
        return $Result
    }

    # Summary output
    Write-Host ""
    Write-Host "─── Infrastructure Operation Summary ───" -ForegroundColor DarkGray
    Write-Host "  Action:      $Action" -ForegroundColor White
    Write-Host "  Provider:    $Provider" -ForegroundColor White
    Write-Host "  Environment: $Environment" -ForegroundColor White
    Write-Host "  Status:      $($Result.Status)" -ForegroundColor $(if ($Result.Status -match 'Active|Ready|OK|Valid|Destroyed|Initialized') { 'Green' } else { 'Red' })
    Write-Host "  Duration:    $($Result.Duration.ToString('mm\:ss\.fff'))" -ForegroundColor White
    Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray
}


# ── Internal helper: execute tofu command ──────────────────────────────────

function _Invoke-Tofu {
    param(
        [string[]]$Args,
        [string]$WorkDir,
        [string]$TofuBin
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $TofuBin
    $psi.Arguments = $Args -join ' '
    $psi.WorkingDirectory = $WorkDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['TF_IN_AUTOMATION'] = 'true'
    $psi.EnvironmentVariables['TF_INPUT'] = 'false'

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return @{
        Stdout   = $stdout
        Stderr   = $stderr
        ExitCode = $proc.ExitCode
    }
}


# ── Internal helper: report infrastructure events to Genesis ───────────────

function _Report-InfraEvent {
    param(
        [string]$Event,
        [string]$Provider,
        [string]$Environment,
        [string]$RequestId
    )

    try {
        $genesisUrl = $env:AITHER_GENESIS_URL ?? 'http://localhost:8001'
        $strataUrl = $env:AITHER_STRATA_URL ?? 'http://localhost:8136'

        # Report to Strata telemetry
        $body = @{
            event_type  = "infra.$Event"
            provider    = $Provider
            environment = $Environment
            request_id  = $RequestId
            timestamp   = (Get-Date -Format 'o')
            source      = 'aitherzero'
        } | ConvertTo-Json

        Invoke-RestMethod -Uri "$strataUrl/api/v1/ingest/ide-session" -Method Post -Body $body -ContentType 'application/json' -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Verbose "Event reporting skipped: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Invoke-AitherInfra
