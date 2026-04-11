#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys AI models to cloud GPU instances via Genesis REST API.

.DESCRIPTION
    Provides functions to deploy, list, and tear down cloud-hosted models
    through the Genesis /deploy/cloud-model endpoints. Supports both
    synchronous (blocking) and asynchronous deployment modes.

    Functions:
      Deploy-CloudModel    — Deploy a single model to a cloud GPU
      Get-CloudProfile     — List available deployment profiles
      Get-CloudDeployment  — List active cloud deployments
      Remove-CloudDeployment — Tear down a deployed model

    All API calls target Genesis at $env:AITHER_GENESIS_URL or localhost:8001.

.EXAMPLE
    Deploy-CloudModel -Model "reasoning"
    Deploys the reasoning model using its default profile.

.EXAMPLE
    Deploy-CloudModel -Model "deepseek-r1:14b" -MaxPrice 0.25 -Sync
    Deploys a specific model with a price cap, blocking until ready.

.EXAMPLE
    Get-CloudDeployment
    Lists all running cloud deployments with cost tracking.

.EXAMPLE
    Remove-CloudDeployment -SessionId "abc-123"
    Tears down a specific deployment by session ID.

.NOTES
    Stage: Deploy
    Order: 3070
    Dependencies: Genesis (port 8001)
    Tags: cloud, gpu, deployment, model, vast.ai
    AllowParallel: true
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$GenesisUrl = $env:AITHER_GENESIS_URL
if (-not $GenesisUrl) { $GenesisUrl = "http://localhost:8001" }

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

function Write-Step  { param([string]$Msg) Write-Host "  > $Msg" -ForegroundColor Cyan }
function Write-Good  { param([string]$Msg) Write-Host "  + $Msg" -ForegroundColor Green }
function Write-Bad   { param([string]$Msg) Write-Host "  x $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  i $Msg" -ForegroundColor DarkGray }
function Write-Title { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Yellow }

function Test-GenesisAvailable {
    try {
        $null = Invoke-RestMethod -Uri "$GenesisUrl/health" -Method GET -TimeoutSec 5
        return $true
    } catch {
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Deploy-CloudModel
# ═══════════════════════════════════════════════════════════════════════════════

function Deploy-CloudModel {
    <#
    .SYNOPSIS
        Deploys a single AI model to a cloud GPU instance.

    .DESCRIPTION
        Calls Genesis POST /deploy/cloud-model (async) or
        POST /deploy/cloud-model/sync (blocking) to provision a cloud GPU,
        deploy vLLM with the specified model, and register it with the
        local LLM queue.

    .PARAMETER Model
        Profile name, model registry name, or HuggingFace model ID.
        Required.

    .PARAMETER Profile
        Force a specific cloud_node_profiles.yaml profile.
        If empty, Genesis auto-selects based on VRAM requirements.

    .PARAMETER MaxPrice
        Maximum price per hour in USD. 0 = auto from profile or $0.20 default.

    .PARAMETER OfferId
        Specific GPU marketplace offer ID. Skips marketplace search.

    .PARAMETER Sync
        Block until deployment completes (up to 10 minutes).
        Without this flag, returns immediately with a session ID.

    .PARAMETER MinVram
        Minimum VRAM in GB. 0 = auto from model requirements.

    .PARAMETER MaxModelLen
        Maximum context length. 0 = 32768 default.

    .PARAMETER BackendName
        Override the backend identifier registered with LLM queue.

    .EXAMPLE
        Deploy-CloudModel -Model "reasoning"

    .EXAMPLE
        Deploy-CloudModel -Model "deepseek-r1:14b" -MaxPrice 0.25 -Sync

    .EXAMPLE
        Deploy-CloudModel -Model "meta-llama/Llama-3.1-8B-Instruct" -Profile "orchestrator" -Sync
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Model,

        [string]$Profile = "",

        [double]$MaxPrice = 0.0,

        [string]$OfferId = "",

        [switch]$Sync,

        [double]$MinVram = 0.0,

        [int]$MaxModelLen = 0,

        [string]$BackendName = ""
    )

    Write-Title "Deploy Cloud Model"
    Write-Step "Model: $Model"
    if ($Profile) { Write-Info "Profile: $Profile" }
    if ($MaxPrice -gt 0) { Write-Info "Max price: `$$MaxPrice/hr" }

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    $body = @{
        model              = $Model
        profile            = $Profile
        max_price_per_hour = $MaxPrice
        min_vram_gb        = $MinVram
        max_model_len      = $MaxModelLen
        register_with_queue = $true
    }

    if ($OfferId) { $body.offer_id = $OfferId }
    if ($BackendName) { $body.backend_name = $BackendName }

    $jsonBody = $body | ConvertTo-Json -Depth 4
    $endpoint = if ($Sync) { "$GenesisUrl/deploy/cloud-model/sync" } else { "$GenesisUrl/deploy/cloud-model" }
    $timeoutSec = if ($Sync) { 600 } else { 30 }

    try {
        Write-Step "Calling $(if ($Sync) { 'sync' } else { 'async' }) deploy endpoint..."

        $response = Invoke-RestMethod -Uri $endpoint `
            -Method POST -Body $jsonBody -ContentType "application/json" `
            -TimeoutSec $timeoutSec

        if ($response.ok) {
            if ($Sync -and $response.session) {
                $s = $response.session
                Write-Good "Deployed: $($s.served_name)"
                Write-Host ""
                Write-Host "  Session ID:   $($s.session_id)" -ForegroundColor White
                Write-Host "  Model:        $($s.model)" -ForegroundColor White
                Write-Host "  GPU:          $($s.gpu_model)" -ForegroundColor White
                Write-Host "  VRAM:         $($s.vram_gb) GB" -ForegroundColor White
                Write-Host "  Price:        `$$($s.price_per_hour)/hr" -ForegroundColor White
                Write-Host "  vLLM URL:     $($s.vllm_url)" -ForegroundColor Cyan
                Write-Host ""
                return $response.session
            } else {
                Write-Good "Deployment queued"
                Write-Host "  Session ID:   $($response.session_id)" -ForegroundColor White
                Write-Host "  Stream URL:   $($response.stream_url)" -ForegroundColor Cyan
                Write-Host "  Status URL:   $($response.status_url)" -ForegroundColor Cyan
                Write-Host ""
                Write-Info "Poll status: Get-CloudDeploymentStatus -SessionId '$($response.session_id)'"
                return $response
            }
        } else {
            Write-Bad "Deploy failed: $($response.error)"
            return $response
        }
    } catch {
        $detail = ""
        if ($_.ErrorDetails.Message) {
            try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).detail } catch { }
        }
        Write-Bad "Failed to deploy: $($_.Exception.Message)"
        if ($detail) { Write-Bad "Detail: $detail" }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-CloudProfile
# ═══════════════════════════════════════════════════════════════════════════════

function Get-CloudProfile {
    <#
    .SYNOPSIS
        Lists available cloud deployment profiles.

    .DESCRIPTION
        Calls Genesis GET /deploy/cloud-model/profiles to retrieve the
        configured profiles from cloud_node_profiles.yaml. Each profile
        specifies GPU requirements, model parameters, and pricing caps.

    .EXAMPLE
        Get-CloudProfile
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    try {
        $response = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/profiles" `
            -Method GET -TimeoutSec 15

        if ($response.ok -and $response.profiles) {
            Write-Title "Cloud Deployment Profiles"

            foreach ($p in $response.profiles) {
                $name = if ($p.name) { $p.name } elseif ($p -is [string]) { $p } else { "$p" }
                $vram = if ($p.min_vram_gb) { "$($p.min_vram_gb) GB" } else { "auto" }
                $price = if ($p.max_price_per_hour) { "`$$($p.max_price_per_hour)/hr" } else { "auto" }
                $model = if ($p.model) { $p.model } else { "default" }

                Write-Host "  $name" -ForegroundColor Cyan -NoNewline
                Write-Host " - VRAM: $vram, Price: $price, Model: $model" -ForegroundColor DarkGray
            }

            Write-Host ""
            return $response.profiles
        } else {
            Write-Info "No profiles found."
        }
    } catch {
        Write-Bad "Failed to list profiles: $($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-CloudDeployment
# ═══════════════════════════════════════════════════════════════════════════════

function Get-CloudDeployment {
    <#
    .SYNOPSIS
        Lists active cloud model deployments.

    .DESCRIPTION
        Calls Genesis GET /deploy/cloud-model/running to retrieve all
        running cloud-hosted models with GPU info and cost tracking.

    .EXAMPLE
        Get-CloudDeployment
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    try {
        $response = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/running" `
            -Method GET -TimeoutSec 15

        if ($response.ok) {
            Write-Title "Running Cloud Deployments"

            if ($response.deployments -and $response.deployments.Count -gt 0) {
                $response.deployments | ForEach-Object {
                    $s = $_
                    $uptime = ""
                    if ($s.started_at) {
                        try {
                            $started = [datetime]::Parse($s.started_at)
                            $dur = (Get-Date) - $started
                            $uptime = "{0:0}h {1:0}m" -f $dur.TotalHours, $dur.Minutes
                        } catch { }
                    }

                    Write-Host "  $($s.served_name)" -ForegroundColor Cyan -NoNewline
                    Write-Host " [$($s.session_id)]" -ForegroundColor DarkGray
                    Write-Host "    Model:  $($s.model)" -ForegroundColor White
                    Write-Host "    GPU:    $($s.gpu_model) ($($s.vram_gb) GB)" -ForegroundColor White
                    Write-Host "    Price:  `$$($s.price_per_hour)/hr" -ForegroundColor White
                    if ($uptime) { Write-Host "    Uptime: $uptime" -ForegroundColor White }
                    Write-Host "    URL:    $($s.vllm_url)" -ForegroundColor Cyan
                    Write-Host ""
                }

                Write-Host "  Total: $($response.deployments.Count) deployment(s)" -ForegroundColor DarkGray
            } else {
                Write-Info "No active cloud deployments."
            }

            if ($response.budget) {
                Write-Host ""
                Write-Host "  Budget: `$$($response.budget.spent_today_usd) / `$$($response.budget.daily_cap_usd) daily" -ForegroundColor Yellow
            }

            Write-Host ""
            return $response
        }
    } catch {
        Write-Bad "Failed to list deployments: $($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Remove-CloudDeployment
# ═══════════════════════════════════════════════════════════════════════════════

function Remove-CloudDeployment {
    <#
    .SYNOPSIS
        Tears down a cloud model deployment.

    .DESCRIPTION
        Calls Genesis POST /deploy/cloud-model/teardown/{session_id} to
        destroy the GPU instance and unregister the backend from the LLM queue.

    .PARAMETER SessionId
        The deployment session ID to tear down. Required.

    .EXAMPLE
        Remove-CloudDeployment -SessionId "abc-123"

    .EXAMPLE
        Get-CloudDeployment | ForEach-Object { Remove-CloudDeployment -SessionId $_.session_id }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias("session_id")]
        [string]$SessionId
    )

    process {
        if (-not (Test-GenesisAvailable)) {
            Write-Bad "Genesis is not reachable at $GenesisUrl"
            return
        }

        if (-not $PSCmdlet.ShouldProcess($SessionId, "Tear down cloud deployment")) {
            return
        }

        Write-Step "Tearing down deployment: $SessionId"

        try {
            $response = Invoke-RestMethod `
                -Uri "$GenesisUrl/deploy/cloud-model/teardown/$SessionId" `
                -Method POST -ContentType "application/json" `
                -TimeoutSec 60

            if ($response.ok) {
                Write-Good "Deployment $SessionId torn down successfully."
                return $response
            } else {
                Write-Bad "Teardown failed: $($response.error)"
                return $response
            }
        } catch {
            $detail = ""
            if ($_.ErrorDetails.Message) {
                try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).detail } catch { }
            }
            Write-Bad "Failed to tear down: $($_.Exception.Message)"
            if ($detail) { Write-Bad "Detail: $detail" }
        }
    }
}
