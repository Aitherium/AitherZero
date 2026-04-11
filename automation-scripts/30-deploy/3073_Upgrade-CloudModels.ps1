#Requires -Version 7.0
<#
.SYNOPSIS
    Upgrades running cloud model deployments with fresh config from cloud_node_profiles.yaml.

.DESCRIPTION
    Provides functions to upgrade cloud-hosted models through the Genesis
    /deploy/cloud-model/upgrade endpoints. An upgrade atomically tears down the
    running instance and redeploys with the latest profile config, picking up
    changes like kv_cache_dtype, new vllm_args, context limits, or GPU tier.

    Functions:
      Upgrade-CloudModel     — Upgrade a single deployment by session ID
      Upgrade-AllCloudModels — Upgrade all running deployments (optional profile filter)
      Get-CloudUpgradePreview — Dry run: show what would change without deploying

    All API calls target Genesis at $env:AITHER_GENESIS_URL or localhost:8001.

.EXAMPLE
    .\3073_Upgrade-CloudModels.ps1 -All
    Upgrades all running cloud models with latest config.

.EXAMPLE
    .\3073_Upgrade-CloudModels.ps1 -All -Profiles reasoning
    Upgrades only the reasoning profile.

.EXAMPLE
    .\3073_Upgrade-CloudModels.ps1 -SessionId abc123
    Upgrades a specific session.

.EXAMPLE
    .\3073_Upgrade-CloudModels.ps1 -All -WhatIf
    Preview what would change without deploying.

.NOTES
    Stage: Deploy
    Order: 3073
    Dependencies: Genesis (port 8001)
    Tags: cloud, gpu, deployment, upgrade, model, vast.ai
    AllowParallel: false
#>

param(
    [string]$SessionId = "",
    [switch]$All,
    [string[]]$Profiles = @(),
    [switch]$WhatIf
)

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
# Upgrade-CloudModel
# ═══════════════════════════════════════════════════════════════════════════════

function Upgrade-CloudModel {
    <#
    .SYNOPSIS
        Upgrades a single cloud model deployment.

    .DESCRIPTION
        Calls Genesis POST /deploy/cloud-model/upgrade/{session_id} to atomically
        tear down the running instance and redeploy with the latest config from
        cloud_node_profiles.yaml. Blocks until the new deployment completes.

    .PARAMETER SessionId
        The deployment session ID to upgrade. Required.

    .EXAMPLE
        Upgrade-CloudModel -SessionId "abc123"
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

        if (-not $PSCmdlet.ShouldProcess($SessionId, "Upgrade cloud deployment")) {
            return
        }

        Write-Step "Upgrading deployment: $SessionId"

        try {
            $response = Invoke-RestMethod `
                -Uri "$GenesisUrl/deploy/cloud-model/upgrade/$SessionId" `
                -Method POST -ContentType "application/json" `
                -TimeoutSec 600

            if ($response.ok -and $response.session) {
                $s = $response.session
                Write-Good "Upgraded: $($s.served_name)"
                Write-Host ""
                Write-Host "  New Session:  $($s.session_id)" -ForegroundColor White
                Write-Host "  Model:        $($s.model)" -ForegroundColor White
                Write-Host "  Profile:      $($s.profile)" -ForegroundColor White
                Write-Host "  GPU:          $($s.gpu_model)" -ForegroundColor White
                Write-Host "  VRAM:         $($s.gpu_vram_gb) GB" -ForegroundColor White
                Write-Host "  Price:        `$$($s.price_per_hour)/hr" -ForegroundColor White
                Write-Host "  vLLM URL:     $($s.vllm_url)" -ForegroundColor Cyan
                Write-Host ""
                return $response.session
            } else {
                Write-Bad "Upgrade failed: $($response.error)"
                return $response
            }
        } catch {
            $detail = ""
            if ($_.ErrorDetails.Message) {
                try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).detail } catch { }
            }
            Write-Bad "Failed to upgrade: $($_.Exception.Message)"
            if ($detail) { Write-Bad "Detail: $detail" }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Upgrade-AllCloudModels
# ═══════════════════════════════════════════════════════════════════════════════

function Upgrade-AllCloudModels {
    <#
    .SYNOPSIS
        Upgrades all running cloud model deployments.

    .DESCRIPTION
        Calls Genesis POST /deploy/cloud-model/upgrade-all to iterate all
        COMPLETE deployments and upgrade each with fresh config. Optionally
        filter by profile names.

    .PARAMETER Profiles
        Only upgrade deployments matching these profile names.
        If empty, upgrades all running deployments.

    .EXAMPLE
        Upgrade-AllCloudModels

    .EXAMPLE
        Upgrade-AllCloudModels -Profiles "reasoning","orchestrator"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$Profiles = @()
    )

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    if (-not $PSCmdlet.ShouldProcess("All running cloud models", "Upgrade")) {
        return
    }

    Write-Title "Upgrade All Cloud Models"

    $body = @{}
    if ($Profiles.Count -gt 0) {
        $body.profiles = $Profiles
        Write-Step "Filtering to profiles: $($Profiles -join ', ')"
    } else {
        Write-Step "Upgrading all running deployments..."
    }

    $jsonBody = $body | ConvertTo-Json -Depth 4
    if ($jsonBody -eq "") { $jsonBody = "{}" }

    try {
        $response = Invoke-RestMethod `
            -Uri "$GenesisUrl/deploy/cloud-model/upgrade-all" `
            -Method POST -Body $jsonBody -ContentType "application/json" `
            -TimeoutSec 1800

        if ($response.ok) {
            # Upgraded
            if ($response.upgraded -and $response.upgraded.Count -gt 0) {
                Write-Host ""
                Write-Good "$($response.upgraded.Count) deployment(s) upgraded:"
                foreach ($u in $response.upgraded) {
                    Write-Host "    $($u.served_name)" -ForegroundColor Cyan -NoNewline
                    Write-Host " [$($u.old_session_id) -> $($u.new_session_id)]" -ForegroundColor DarkGray
                }
            }

            # Failed
            if ($response.failed -and $response.failed.Count -gt 0) {
                Write-Host ""
                Write-Bad "$($response.failed.Count) deployment(s) failed:"
                foreach ($f in $response.failed) {
                    Write-Host "    $($f.served_name)" -ForegroundColor Red -NoNewline
                    Write-Host " [$($f.session_id)]: $($f.error)" -ForegroundColor DarkGray
                }
            }

            # Summary
            Write-Host ""
            $upgraded = if ($response.upgraded) { $response.upgraded.Count } else { 0 }
            $failed = if ($response.failed) { $response.failed.Count } else { 0 }
            Write-Host "  Summary: $upgraded upgraded, $failed failed out of $($response.total) total" -ForegroundColor Yellow
            Write-Host ""

            return $response
        } else {
            Write-Bad "Upgrade-all failed: $($response.error)"
            return $response
        }
    } catch {
        $detail = ""
        if ($_.ErrorDetails.Message) {
            try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).detail } catch { }
        }
        Write-Bad "Failed to upgrade: $($_.Exception.Message)"
        if ($detail) { Write-Bad "Detail: $detail" }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-CloudUpgradePreview
# ═══════════════════════════════════════════════════════════════════════════════

function Get-CloudUpgradePreview {
    <#
    .SYNOPSIS
        Preview what would change if cloud models were upgraded.

    .DESCRIPTION
        Fetches running deployments and current profile configs, then shows
        a diff of what would change for each deployment. Does NOT trigger
        any actual upgrades.

    .PARAMETER Profiles
        Only preview deployments matching these profile names.

    .EXAMPLE
        Get-CloudUpgradePreview

    .EXAMPLE
        Get-CloudUpgradePreview -Profiles "reasoning"
    #>
    [CmdletBinding()]
    param(
        [string[]]$Profiles = @()
    )

    if (-not (Test-GenesisAvailable)) {
        Write-Bad "Genesis is not reachable at $GenesisUrl"
        return
    }

    Write-Title "Cloud Upgrade Preview (dry run)"

    # Fetch running deployments
    try {
        $running = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/running" `
            -Method GET -TimeoutSec 15
    } catch {
        Write-Bad "Failed to fetch running deployments: $($_.Exception.Message)"
        return
    }

    # Fetch profiles
    try {
        $profilesResp = Invoke-RestMethod -Uri "$GenesisUrl/deploy/cloud-model/profiles" `
            -Method GET -TimeoutSec 15
    } catch {
        Write-Bad "Failed to fetch profiles: $($_.Exception.Message)"
        return
    }

    if (-not $running.ok -or -not $running.deployments -or $running.deployments.Count -eq 0) {
        Write-Info "No active cloud deployments to preview."
        return
    }

    # Build profile lookup
    $profileMap = @{}
    if ($profilesResp.ok -and $profilesResp.profiles) {
        foreach ($p in $profilesResp.profiles) {
            $name = if ($p.name) { $p.name } else { "$p" }
            $profileMap[$name] = $p
        }
    }

    $deployments = $running.deployments
    if ($Profiles.Count -gt 0) {
        $profileSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$Profiles,
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $deployments = $deployments | Where-Object { $profileSet.Contains($_.profile) }
    }

    if ($deployments.Count -eq 0) {
        Write-Info "No matching deployments found for the specified profiles."
        return
    }

    foreach ($d in $deployments) {
        Write-Host ""
        Write-Host "  $($d.served_name)" -ForegroundColor Cyan -NoNewline
        Write-Host " [$($d.session_id)]" -ForegroundColor DarkGray

        $profile = $profileMap[$d.profile]
        if (-not $profile) {
            Write-Info "    Profile '$($d.profile)' not found in current config — would use defaults"
            continue
        }

        # Compare key fields
        $changes = @()

        # GPU VRAM
        $profileVram = if ($profile.min_vram_gb) { $profile.min_vram_gb } else { 0 }
        if ($profileVram -gt 0 -and $profileVram -ne $d.gpu_vram_gb) {
            $changes += "    VRAM: $($d.gpu_vram_gb) GB -> $($profileVram) GB (min)"
        }

        # Max price
        $profilePrice = if ($profile.max_price_per_hour) { $profile.max_price_per_hour } else { 0 }
        if ($profilePrice -gt 0 -and $profilePrice -ne $d.price_per_hour) {
            $changes += "    Max price: `$$($d.price_per_hour)/hr -> `$$($profilePrice)/hr"
        }

        # vLLM args (show profile's vllm_args if present)
        if ($profile.vllm_args) {
            $vllmStr = ($profile.vllm_args | ConvertTo-Json -Compress)
            $changes += "    vllm_args (profile): $vllmStr"
        }

        # Model
        if ($profile.model -and $profile.model -ne $d.model) {
            $changes += "    Model: $($d.model) -> $($profile.model)"
        }

        # Max context
        if ($profile.max_model_len -and $profile.max_model_len -gt 0) {
            $changes += "    max_model_len (profile): $($profile.max_model_len)"
        }

        if ($changes.Count -gt 0) {
            Write-Host "    Changes detected:" -ForegroundColor Yellow
            foreach ($c in $changes) {
                Write-Host $c -ForegroundColor White
            }
        } else {
            Write-Info "    No obvious config differences detected"
        }
    }

    Write-Host ""
    Write-Host "  Total: $($deployments.Count) deployment(s) would be upgraded" -ForegroundColor Yellow
    Write-Info "  Run without -WhatIf to apply upgrades"
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# Script Entry Point
# ═══════════════════════════════════════════════════════════════════════════════

if ($SessionId) {
    if ($WhatIf) {
        Get-CloudUpgradePreview -Profiles @()
    } else {
        Upgrade-CloudModel -SessionId $SessionId
    }
} elseif ($All) {
    if ($WhatIf) {
        Get-CloudUpgradePreview -Profiles $Profiles
    } else {
        Upgrade-AllCloudModels -Profiles $Profiles
    }
} else {
    Write-Title "Cloud Model Upgrade"
    Write-Info "Usage:"
    Write-Host "  .\3073_Upgrade-CloudModels.ps1 -SessionId <id>           # Upgrade single" -ForegroundColor White
    Write-Host "  .\3073_Upgrade-CloudModels.ps1 -All                      # Upgrade all" -ForegroundColor White
    Write-Host "  .\3073_Upgrade-CloudModels.ps1 -All -Profiles reasoning  # Upgrade by profile" -ForegroundColor White
    Write-Host "  .\3073_Upgrade-CloudModels.ps1 -All -WhatIf              # Preview changes" -ForegroundColor White
    Write-Host ""
    Write-Info "Functions (dot-source this script first):"
    Write-Host "  Upgrade-CloudModel -SessionId <id>" -ForegroundColor White
    Write-Host "  Upgrade-AllCloudModels [-Profiles <list>]" -ForegroundColor White
    Write-Host "  Get-CloudUpgradePreview [-Profiles <list>]" -ForegroundColor White
    Write-Host ""
}
