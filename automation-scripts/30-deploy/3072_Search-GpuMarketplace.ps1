#Requires -Version 7.0
<#
.SYNOPSIS
    Searches the GPU marketplace, estimates deployment costs, and shows billing.

.DESCRIPTION
    Provides functions to browse available cloud GPUs, get cost estimates
    before deploying, and review billing summaries. All queries route through
    Genesis to the configured cloud GPU providers (Vast.ai, RunPod, etc.).

    Functions:
      Search-GpuMarketplace   — Browse available GPU offers with filtering
      Get-DeploymentEstimate  — Cost estimate for a model before deploying
      Get-GpuBilling          — Billing summary with active costs and history

.EXAMPLE
    Search-GpuMarketplace
    Lists up to 20 GPUs with 24+ GB VRAM under $1.00/hr.

.EXAMPLE
    Search-GpuMarketplace -MinVram 48 -MaxPrice 0.80 -GpuModel "A6000"
    Searches for A6000 GPUs with 48+ GB VRAM.

.EXAMPLE
    Get-DeploymentEstimate -Model "reasoning"
    Shows estimated cost and matching GPU offers for the reasoning profile.

.EXAMPLE
    Get-GpuBilling
    Shows billing summary with active costs and daily budget.

.NOTES
    Stage: Deploy
    Order: 3072
    Dependencies: Genesis (port 8001), 3070
    Tags: cloud, gpu, marketplace, billing, cost, search
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
# Search-GpuMarketplace
# ═══════════════════════════════════════════════════════════════════════════════

function Search-GpuMarketplace {
    <#
    .SYNOPSIS
        Searches the GPU marketplace for available cloud instances.

    .DESCRIPTION
        Calls Genesis GET /deploy/cloud-model/marketplace to browse available
        GPU offers from configured cloud providers. Results are sorted by
        price and displayed as a formatted table.

    .PARAMETER MinVram
        Minimum VRAM in GB. Default: 24.

    .PARAMETER MaxPrice
        Maximum price per hour in USD. Default: 1.00.

    .PARAMETER GpuModel
        Filter by GPU model name (e.g. "RTX_4090", "A100", "A6000").
        Empty string returns all models.

    .PARAMETER Limit
        Maximum number of results to return. Default: 20.

    .EXAMPLE
        Search-GpuMarketplace

    .EXAMPLE
        Search-GpuMarketplace -MinVram 48 -MaxPrice 0.80

    .EXAMPLE
        Search-GpuMarketplace -GpuModel "A6000" -Limit 10

    .EXAMPLE
        Search-GpuMarketplace -MinVram 80 -MaxPrice 2.00 -GpuModel "A100"
    #>
    [CmdletBinding()]
    param(
        [int]$MinVram = 24,

        [double]$MaxPrice = 1.0,

        [string]$GpuModel = "",

        [int]$Limit = 20
    )

    Write-Title "GPU Marketplace Search"
    Write-Step "VRAM >= ${MinVram} GB, Price <= `$$MaxPrice/hr"
    if ($GpuModel) { Write-Info "GPU filter: $GpuModel" }

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    # Build query string
    $qs = "min_vram_gb=$MinVram&max_price_per_hour=$MaxPrice&limit=$Limit"
    if ($GpuModel) { $qs += "&gpu_model=$GpuModel" }

    try {
        $response = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/marketplace?$qs" `
            -Method GET -TimeoutSec 30

        if ($response.ok -and $response.offers) {
            $offers = $response.offers
            Write-Host ""
            Write-Host "  Found $($response.count) offer(s):" -ForegroundColor Green
            Write-Host ""

            # Table header
            $fmt = "  {0,-6} {1,-16} {2,-8} {3,-10} {4,-16} {5,-10}"
            Write-Host ($fmt -f "ID", "GPU", "VRAM", "PRICE", "LOCATION", "RELIABLE") -ForegroundColor DarkGray
            Write-Host ("  " + ("-" * 70)) -ForegroundColor DarkGray

            foreach ($o in $offers) {
                $id       = if ($o.id) { "$($o.id)" } else { "-" }
                $gpu      = if ($o.gpu_name) { $o.gpu_name } else { "-" }
                $vram     = if ($o.gpu_ram) { "$([int]$o.gpu_ram) GB" } else { "-" }
                $price    = if ($o.dph_total -ne $null) { "`${0:F3}/hr" -f $o.dph_total } else { "-" }
                $location = if ($o.geolocation) { $o.geolocation } else { "-" }
                $reliable = if ($o.reliability -ne $null) { "{0:P0}" -f $o.reliability } else { "-" }

                # Color by price tier
                $priceVal = if ($o.dph_total) { [double]$o.dph_total } else { 0 }
                $color = if ($priceVal -le 0.20) { "Green" }
                         elseif ($priceVal -le 0.50) { "Yellow" }
                         else { "White" }

                Write-Host ($fmt -f $id, $gpu, $vram, $price, $location, $reliable) -ForegroundColor $color
            }

            Write-Host ""
            Write-Info "Use: Deploy-CloudModel -Model <name> -OfferId <id> -Sync"
            Write-Host ""
            return $offers
        } else {
            Write-Info "No GPU offers found matching criteria."
            Write-Info "Try increasing -MaxPrice or lowering -MinVram."
        }
    } catch {
        Write-Bad "Marketplace search failed: $($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-DeploymentEstimate
# ═══════════════════════════════════════════════════════════════════════════════

function Get-DeploymentEstimate {
    <#
    .SYNOPSIS
        Gets a cost estimate for deploying a model to the cloud.

    .DESCRIPTION
        Calls Genesis POST /deploy/cloud-model/estimate with the model name
        and optional profile to calculate expected costs and show matching
        GPU offers. Use this before Deploy-CloudModel to preview costs.

    .PARAMETER Model
        Profile name, registry name, or HuggingFace model ID. Required.

    .PARAMETER Profile
        Force a cloud_node_profiles.yaml profile for estimation.

    .PARAMETER MinVram
        Override minimum VRAM requirement in GB.

    .PARAMETER MaxModelLen
        Override maximum context length.

    .EXAMPLE
        Get-DeploymentEstimate -Model "reasoning"

    .EXAMPLE
        Get-DeploymentEstimate -Model "meta-llama/Llama-3.1-70B-Instruct" -Profile "reasoning"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Model,

        [string]$Profile = "",

        [double]$MinVram = 0.0,

        [int]$MaxModelLen = 0
    )

    Write-Title "Deployment Cost Estimate"
    Write-Step "Model: $Model"
    if ($Profile) { Write-Info "Profile: $Profile" }

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    $body = @{
        model         = $Model
        profile       = $Profile
        served_name   = ""
        min_vram_gb   = $MinVram
        max_model_len = $MaxModelLen
    } | ConvertTo-Json -Depth 4

    try {
        $response = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/estimate" `
            -Method POST -Body $body -ContentType "application/json" `
            -TimeoutSec 30

        if ($response.ok) {
            Write-Host ""

            # Show estimate details
            if ($response.model) {
                Write-Host "  Model:       $($response.model)" -ForegroundColor White
            }
            if ($response.profile) {
                Write-Host "  Profile:     $($response.profile)" -ForegroundColor White
            }
            if ($response.min_vram_gb) {
                Write-Host "  VRAM needed: $($response.min_vram_gb) GB" -ForegroundColor White
            }
            if ($response.estimated_cost_per_hour) {
                Write-Host "  Est. cost:   `$$($response.estimated_cost_per_hour)/hr" -ForegroundColor Yellow
            }
            if ($response.estimated_cost_per_day) {
                Write-Host "  Est. daily:  `$$($response.estimated_cost_per_day)/day" -ForegroundColor Yellow
            }

            # Show matching offers
            if ($response.offers -and $response.offers.Count -gt 0) {
                Write-Host ""
                Write-Host "  Matching GPU offers:" -ForegroundColor Green

                $fmt = "    {0,-6} {1,-16} {2,-8} {3,-10} {4,-16}"
                Write-Host ($fmt -f "ID", "GPU", "VRAM", "PRICE", "LOCATION") -ForegroundColor DarkGray

                $topOffers = $response.offers | Select-Object -First 5
                foreach ($o in $topOffers) {
                    $id       = if ($o.id) { "$($o.id)" } else { "-" }
                    $gpu      = if ($o.gpu_name) { $o.gpu_name } else { "-" }
                    $vram     = if ($o.gpu_ram) { "$([int]$o.gpu_ram) GB" } else { "-" }
                    $price    = if ($o.dph_total -ne $null) { "`${0:F3}/hr" -f $o.dph_total } else { "-" }
                    $location = if ($o.geolocation) { $o.geolocation } else { "-" }

                    Write-Host ($fmt -f $id, $gpu, $vram, $price, $location) -ForegroundColor White
                }

                if ($response.offers.Count -gt 5) {
                    Write-Info "    ... and $($response.offers.Count - 5) more"
                }
            }

            Write-Host ""
            Write-Info "Deploy with: Deploy-CloudModel -Model '$Model' -Sync"
            Write-Host ""
            return $response
        } else {
            Write-Bad "Estimation failed: $($response.error)"
            return $response
        }
    } catch {
        Write-Bad "Failed to estimate cost: $($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-GpuBilling
# ═══════════════════════════════════════════════════════════════════════════════

function Get-GpuBilling {
    <#
    .SYNOPSIS
        Shows GPU cloud billing summary.

    .DESCRIPTION
        Calls Genesis GET /deploy/cloud-model/billing to display active
        deployment costs, total hourly burn rate, session history, budget
        status, and ACTA token spend.

    .EXAMPLE
        Get-GpuBilling
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    try {
        $response = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/billing" `
            -Method GET -TimeoutSec 15

        if ($response.ok) {
            Write-Title "GPU Billing Summary"

            # Active deployments
            if ($response.active_deployments -and $response.active_deployments.Count -gt 0) {
                Write-Host "  Active deployments:" -ForegroundColor White
                Write-Host ""

                $fmt = "    {0,-20} {1,-16} {2,-10} {3,-12} {4}"
                Write-Host ($fmt -f "MODEL", "GPU", "PRICE", "UPTIME", "COST SO FAR") -ForegroundColor DarkGray
                Write-Host ("    " + ("-" * 70)) -ForegroundColor DarkGray

                foreach ($d in $response.active_deployments) {
                    $name   = if ($d.served_name) { $d.served_name } else { $d.model }
                    $gpu    = if ($d.gpu_model) { $d.gpu_model } else { "-" }
                    $price  = if ($d.price_per_hour -ne $null) { "`${0:F3}/hr" -f $d.price_per_hour } else { "-" }
                    $uptime = if ($d.uptime_hours -ne $null) { "{0:F1}h" -f $d.uptime_hours } else { "-" }
                    $cost   = if ($d.total_cost -ne $null) { "`${0:F2}" -f $d.total_cost } else { "-" }

                    Write-Host ($fmt -f $name, $gpu, $price, $uptime, $cost) -ForegroundColor White
                }
                Write-Host ""
            } else {
                Write-Info "No active deployments."
                Write-Host ""
            }

            # Totals
            if ($response.total_hourly_burn -ne $null) {
                Write-Host ("  Hourly burn:   `${0:F3}/hr" -f $response.total_hourly_burn) -ForegroundColor Yellow
            }
            if ($response.total_daily_cost -ne $null) {
                Write-Host ("  Daily cost:    `${0:F2}/day" -f $response.total_daily_cost) -ForegroundColor Yellow
            }
            if ($response.total_spent -ne $null) {
                Write-Host ("  Total spent:   `${0:F2}" -f $response.total_spent) -ForegroundColor Yellow
            }

            # Budget
            if ($response.budget) {
                $b = $response.budget
                Write-Host ""
                if ($b.daily_cap_usd -ne $null -and $b.spent_today_usd -ne $null) {
                    $pct = if ($b.daily_cap_usd -gt 0) { $b.spent_today_usd / $b.daily_cap_usd * 100 } else { 0 }
                    $budgetColor = if ($pct -ge 90) { "Red" } elseif ($pct -ge 70) { "Yellow" } else { "Green" }
                    Write-Host ("  Budget:        `$$($b.spent_today_usd) / `$$($b.daily_cap_usd) daily ({0:F0}%)" -f $pct) -ForegroundColor $budgetColor
                }
            }

            # ACTA tokens
            if ($response.acta_tokens_spent -ne $null) {
                Write-Host "  ACTA tokens:   $($response.acta_tokens_spent) spent" -ForegroundColor DarkGray
            }

            # Session history
            if ($response.session_history -and $response.session_history.Count -gt 0) {
                Write-Host ""
                Write-Host "  Recent sessions:" -ForegroundColor DarkGray

                $recent = $response.session_history | Select-Object -Last 5
                foreach ($s in $recent) {
                    $name = if ($s.served_name) { $s.served_name } else { $s.model }
                    $cost = if ($s.total_cost -ne $null) { "`${0:F2}" -f $s.total_cost } else { "?" }
                    $dur  = if ($s.duration_hours -ne $null) { "{0:F1}h" -f $s.duration_hours } else { "?" }
                    $status = if ($s.status) { $s.status } else { "unknown" }

                    Write-Host "    $name — $cost ($dur) [$status]" -ForegroundColor DarkGray
                }
            }

            Write-Host ""
            return $response
        }
    } catch {
        Write-Bad "Failed to get billing: $($_.Exception.Message)"
    }
}
