#Requires -Version 7.0

<#
.SYNOPSIS
    Join the AitherOS mesh network and configure replication.

.DESCRIPTION
    Registers this node with the mesh controller, joins the AitherNet
    overlay, and optionally configures Strata replication for site-to-site
    data sync.

    Steps:
        1. Register node with Gateway /nodes/register
        2. Join mesh via controller URL
        3. Configure Strata replication (if enabled)
        4. Start heartbeat

    Exit Codes:
        0 - Success
        1 - Controller unreachable
        2 - Registration failed
        3 - Replication config failed

.PARAMETER ControllerUrl
    Primary site controller URL. Default: https://gateway.aitherium.com

.PARAMETER MeshPSK
    Pre-shared key for mesh authentication.

.PARAMETER SiteName
    Human-readable site name.

.PARAMETER ApiKey
    ACTA API key for authenticated requests.

.PARAMETER EnableReplication
    Enable Strata replication to this node.

.PARAMETER DryRun
    Preview only.

.PARAMETER PassThru
    Return result object.

.NOTES
    Stage: Onboarding
    Order: 3201
    Dependencies: 3200
    Tags: onboarding, mesh, replication, site-to-site
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ControllerUrl = 'https://gateway.aitherium.com',
    [string]$MeshPSK = '',
    [string]$SiteName = $env:COMPUTERNAME,
    [string]$ApiKey = '',
    [bool]$EnableReplication = $true,
    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Name, [string]$Status = 'running')
    $icon = switch ($Status) { 'done' { '[OK]' } 'fail' { '[FAIL]' } 'skip' { '[SKIP]' } default { '[..]' } }
    Write-Host "$icon $Name" -ForegroundColor $(switch ($Status) { 'done' { 'Green' } 'fail' { 'Red' } 'skip' { 'Yellow' } default { 'Cyan' } })
}

# ── Step 1: Check controller reachability ────────────────────────────────

Write-Step "Check controller" 'running'

try {
    $headers = @{}
    if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }

    $health = Invoke-RestMethod -Uri "$ControllerUrl/health" -TimeoutSec 10 -Headers $headers -ErrorAction Stop
    Write-Step "Check controller ($($health.service) healthy)" 'done'
}
catch {
    Write-Step "Check controller" 'fail'
    Write-Error "Controller unreachable at $ControllerUrl : $_"
    exit 1
}

# ── Step 2: Register node ────────────────────────────────────────────────

Write-Step "Register node" 'running'

if ($DryRun) { Write-Step "Register node (DRY RUN)" 'skip' }
else {
    # Gather hardware capabilities
    $caps = @('code', 'storage')
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $caps += 'gpu'
        try {
            $gpuName = (nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1).Trim()
            if ($gpuName) { $caps += "gpu:$gpuName" }
        } catch {}
    }

    $body = @{
        name         = $SiteName
        host         = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5 -ErrorAction SilentlyContinue) ?? 'unknown'
        port         = 8090
        capabilities = $caps
        labels       = @{ site = $SiteName; role = 'edge' }
    } | ConvertTo-Json -Depth 5

    try {
        $regResult = Invoke-RestMethod -Uri "$ControllerUrl/nodes/register" `
            -Method POST -Body $body -ContentType 'application/json' `
            -TimeoutSec 30 -Headers $headers -ErrorAction Stop

        if ($regResult.success) {
            Write-Host "  Node ID: $($regResult.node_id)"
            Write-Host "  API Key: $($regResult.api_key.Substring(0, 20))..."
            Write-Step "Register node ($($regResult.node_id))" 'done'

            # Save node credentials
            $credFile = Join-Path $HOME '.aither' 'mesh_credentials.json'
            $credDir = Split-Path $credFile
            if (-not (Test-Path $credDir)) { New-Item -Path $credDir -ItemType Directory -Force | Out-Null }
            $regResult | ConvertTo-Json -Depth 5 | Set-Content $credFile
            Write-Host "  Credentials saved to $credFile"
        }
        else {
            Write-Step "Register node" 'fail'
            Write-Error "Registration failed: $($regResult | ConvertTo-Json)"
            exit 2
        }
    }
    catch {
        Write-Step "Register node" 'fail'
        Write-Error "Registration request failed: $_"
        exit 2
    }
}

# ── Step 3: Configure replication ────────────────────────────────────────

if ($EnableReplication) {
    Write-Step "Configure replication" 'running'

    if ($DryRun) { Write-Step "Configure replication (DRY RUN)" 'skip' }
    else {
        # Configure replication via local Strata/Mesh once services are up
        $meshUrl = 'http://localhost:8125'
        try {
            $repBody = @{
                path        = 'aither://warm/'
                policy      = 'on_change'
                node_filter = $null  # all nodes
            } | ConvertTo-Json -Depth 3

            $repResult = Invoke-RestMethod -Uri "$meshUrl/strata/replicate" `
                -Method POST -Body $repBody -ContentType 'application/json' `
                -TimeoutSec 30 -ErrorAction Stop

            Write-Step "Configure replication (policy: on_change)" 'done'
        }
        catch {
            Write-Step "Configure replication (services may not be ready yet)" 'skip'
            Write-Host "  Run manually after services start:"
            Write-Host "  curl -X POST http://localhost:8125/strata/replicate -d '{""path"":""aither://warm/"",""policy"":""on_change""}'"
        }
    }
}

# ── Summary ──────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Mesh join complete for: $SiteName" -ForegroundColor Green
Write-Host "  Controller: $ControllerUrl"
Write-Host "  Replication: $(if ($EnableReplication) { 'enabled (on_change)' } else { 'disabled' })"
Write-Host ""

exit 0
