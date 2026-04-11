#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys and manages full inference stacks on cloud GPU pools.

.DESCRIPTION
    Provides functions to deploy the complete LLM inference stack (orchestrator,
    reasoning, vision, coding) to cloud GPUs, tear down all cloud deployments,
    and inspect the unified compute pool.

    Functions:
      Deploy-CloudStack  — Deploy full inference stack to N cloud GPUs
      Remove-CloudStack  — Tear down all cloud stack deployments
      Get-ComputePool    — Show unified pool status (local + cloud + sovereign)

    A "stack" deploys one GPU per profile per replica. With replicas=2 and
    3 profiles (orchestrator, reasoning, vision), this provisions 6 GPUs.
    All backends register with the local LLMQueue for unified routing.

.EXAMPLE
    Deploy-CloudStack
    Deploys 1 replica of all inference profiles.

.EXAMPLE
    Deploy-CloudStack -Replicas 2 -Profiles orchestrator,reasoning -MaxPrice 0.50
    Deploys 2 replicas of the orchestrator and reasoning profiles.

.EXAMPLE
    Remove-CloudStack
    Tears down all cloud deployments. Local backends are NOT affected.

.EXAMPLE
    Get-ComputePool
    Shows every registered backend across local, cloud, and sovereign nodes.

.NOTES
    Stage: Deploy
    Order: 3071
    Dependencies: Genesis (port 8001), 3070
    Tags: cloud, gpu, stack, compute-pool, scaling
    AllowParallel: false
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
# Deploy-CloudStack
# ═══════════════════════════════════════════════════════════════════════════════

function Deploy-CloudStack {
    <#
    .SYNOPSIS
        Deploys the full LLM inference stack to cloud GPU instances.

    .DESCRIPTION
        Calls Genesis POST /deploy/cloud-model/stack to provision N replicas
        of the complete model stack across separate cloud GPUs. Each profile
        (orchestrator, reasoning, vision, etc.) gets its own GPU instance per
        replica.

        All provisioned backends auto-register with LLMQueue and join the
        unified compute pool alongside local and sovereign nodes.

    .PARAMETER Replicas
        Number of full-stack copies to deploy. Default: 1.

    .PARAMETER Profiles
        Comma-separated profile names to deploy. If omitted, Genesis deploys
        all inference profiles from cloud_node_profiles.yaml.

    .PARAMETER MaxPrice
        Maximum price per GPU per hour in USD. 0 = auto from profile defaults.

    .PARAMETER PoolName
        Label for this compute pool group (for tracking and billing).

    .EXAMPLE
        Deploy-CloudStack

    .EXAMPLE
        Deploy-CloudStack -Replicas 2 -Profiles orchestrator,reasoning

    .EXAMPLE
        Deploy-CloudStack -Replicas 3 -MaxPrice 0.40 -PoolName "prod-burst"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$Replicas = 1,

        [string[]]$Profiles,

        [double]$MaxPrice = 0.0,

        [string]$PoolName = ""
    )

    Write-Title "Deploy Cloud Stack"
    Write-Step "Replicas: $Replicas"
    if ($Profiles) { Write-Info "Profiles: $($Profiles -join ', ')" }
    if ($MaxPrice -gt 0) { Write-Info "Max price: `$$MaxPrice/hr per GPU" }
    if ($PoolName) { Write-Info "Pool name: $PoolName" }

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    # Convert comma-separated string values into proper array
    $profileList = @()
    if ($Profiles) {
        foreach ($p in $Profiles) {
            $profileList += ($p -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
    }

    $totalGpus = if ($profileList.Count -gt 0) { $profileList.Count * $Replicas } else { "N x $Replicas" }
    Write-Step "This will provision approximately $totalGpus GPU instance(s)."

    if (-not $PSCmdlet.ShouldProcess("Deploy $Replicas replica(s) to cloud GPUs", "Stack Deployment")) {
        return
    }

    $body = @{
        replicas           = $Replicas
        max_price_per_hour = $MaxPrice
        pool_name          = $PoolName
    }

    if ($profileList.Count -gt 0) {
        $body.profiles = $profileList
    }

    $jsonBody = $body | ConvertTo-Json -Depth 4

    try {
        Write-Step "Calling stack deploy endpoint (this may take several minutes)..."

        $response = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/stack" `
            -Method POST -Body $jsonBody -ContentType "application/json" `
            -TimeoutSec 600

        if ($response.ok) {
            Write-Good "Stack deployment initiated."

            if ($response.sessions) {
                Write-Host ""
                Write-Host "  Deployed sessions:" -ForegroundColor White

                foreach ($s in $response.sessions) {
                    $name = if ($s.served_name) { $s.served_name } else { $s.model }
                    $gpu = if ($s.gpu_model) { "$($s.gpu_model) ($($s.vram_gb) GB)" } else { "pending" }
                    $price = if ($s.price_per_hour) { "`$$($s.price_per_hour)/hr" } else { "tbd" }

                    Write-Host "    $name" -ForegroundColor Cyan -NoNewline
                    Write-Host " - GPU: $gpu, Price: $price" -ForegroundColor DarkGray
                }
            }

            if ($response.pool_name) {
                Write-Host ""
                Write-Host "  Pool: $($response.pool_name)" -ForegroundColor Yellow
            }

            Write-Host ""
            return $response
        } else {
            Write-Bad "Stack deploy failed: $($response.error)"
            return $response
        }
    } catch {
        $detail = ""
        if ($_.ErrorDetails.Message) {
            try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).detail } catch { }
        }
        Write-Bad "Failed to deploy stack: $($_.Exception.Message)"
        if ($detail) { Write-Bad "Detail: $detail" }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Remove-CloudStack
# ═══════════════════════════════════════════════════════════════════════════════

function Remove-CloudStack {
    <#
    .SYNOPSIS
        Tears down all cloud stack deployments.

    .DESCRIPTION
        Calls Genesis POST /deploy/cloud-model/stack/teardown to destroy
        all cloud GPU instances. Local backends are NOT affected.

        Optionally filter by profile names to tear down only specific
        model backends (e.g. only reasoning nodes).

    .PARAMETER Profiles
        Optional profile filter. If provided, only deployments matching
        these profiles are torn down. If omitted, tears down everything.

    .EXAMPLE
        Remove-CloudStack

    .EXAMPLE
        Remove-CloudStack -Profiles reasoning,vision
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$Profiles
    )

    Write-Title "Teardown Cloud Stack"

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    # Convert comma-separated string values
    $profileList = @()
    if ($Profiles) {
        foreach ($p in $Profiles) {
            $profileList += ($p -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
    }

    $desc = if ($profileList.Count -gt 0) {
        "Tear down cloud deployments for: $($profileList -join ', ')"
    } else {
        "Tear down ALL cloud deployments"
    }

    Write-Step $desc

    if (-not $PSCmdlet.ShouldProcess($desc, "Stack Teardown")) {
        return
    }

    $body = @{}
    if ($profileList.Count -gt 0) {
        $body.profiles = $profileList
    }

    # Stack teardown uses StackDeployRequest shape — replicas is required but unused
    $body.replicas = 0
    $body.max_price_per_hour = 0.0
    $body.pool_name = ""

    $jsonBody = $body | ConvertTo-Json -Depth 4

    try {
        $response = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/stack/teardown" `
            -Method POST -Body $jsonBody -ContentType "application/json" `
            -TimeoutSec 120

        if ($response.ok) {
            Write-Good "Cloud stack teardown complete."

            if ($response.torn_down) {
                Write-Host "  Torn down: $($response.torn_down) deployment(s)" -ForegroundColor White
            }

            Write-Host ""
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
        Write-Bad "Failed to tear down stack: $($_.Exception.Message)"
        if ($detail) { Write-Bad "Detail: $detail" }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-ComputePool
# ═══════════════════════════════════════════════════════════════════════════════

function Get-ComputePool {
    <#
    .SYNOPSIS
        Shows the unified compute pool status.

    .DESCRIPTION
        Calls Genesis GET /deploy/cloud-model/pool to display every backend
        registered with LLMQueue, regardless of location: local GPU, rented
        cloud GPU, sovereign edge node, or mesh peer.

    .EXAMPLE
        Get-ComputePool
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    try {
        $response = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/pool" `
            -Method GET -TimeoutSec 15

        if ($response.ok) {
            Write-Title "Unified Compute Pool"

            if ($response.backends -and $response.backends.Count -gt 0) {
                # Header
                $fmt = "{0,-20} {1,-12} {2,-16} {3,-8} {4,-10} {5}"
                Write-Host ($fmt -f "NAME", "LOCATION", "GPU", "VRAM", "STATUS", "URL") -ForegroundColor DarkGray
                Write-Host ("  " + ("-" * 80)) -ForegroundColor DarkGray

                foreach ($b in $response.backends) {
                    $name     = if ($b.name) { $b.name } else { "unknown" }
                    $location = if ($b.location) { $b.location } else { "local" }
                    $gpu      = if ($b.gpu_model) { $b.gpu_model } else { "-" }
                    $vram     = if ($b.vram_gb) { "$($b.vram_gb) GB" } else { "-" }
                    $status   = if ($b.status) { $b.status } else { "unknown" }
                    $url      = if ($b.url) { $b.url } else { "-" }

                    $color = switch ($status) {
                        "healthy"  { "Green" }
                        "active"   { "Green" }
                        "degraded" { "Yellow" }
                        "offline"  { "Red" }
                        default    { "White" }
                    }

                    Write-Host ($fmt -f $name, $location, $gpu, $vram, $status, $url) -ForegroundColor $color
                }

                Write-Host ""
                Write-Host "  Total: $($response.backends.Count) backend(s)" -ForegroundColor DarkGray
            } else {
                Write-Info "No backends registered in compute pool."
            }

            if ($response.summary) {
                Write-Host ""
                $s = $response.summary
                if ($s.total_vram_gb) {
                    Write-Host "  Total VRAM:  $($s.total_vram_gb) GB" -ForegroundColor Yellow
                }
                if ($s.cloud_count -ne $null) {
                    Write-Host "  Cloud nodes: $($s.cloud_count)" -ForegroundColor Yellow
                }
                if ($s.local_count -ne $null) {
                    Write-Host "  Local nodes: $($s.local_count)" -ForegroundColor Yellow
                }
            }

            Write-Host ""
            return $response
        }
    } catch {
        Write-Bad "Failed to get pool status: $($_.Exception.Message)"
    }
}
