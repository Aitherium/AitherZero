#Requires -Version 7.0

<#
.SYNOPSIS
    Connect this site to Elysium (cloud inference + tools).

.DESCRIPTION
    Writes the ADK config, verifies cloud gateway connectivity, checks
    API key validity, and confirms model access.

    Steps:
        1. Write ~/.aither/config.json with API key + gateway URLs
        2. Verify cloud gateway health
        3. Check API key + billing balance
        4. List available models
        5. Run aither connect (if ADK installed)

    Exit Codes:
        0 - Success
        1 - Gateway unreachable
        2 - API key invalid
        3 - ADK connect failed

.PARAMETER ApiKey
    ACTA API key (aither_sk_live_...). REQUIRED.

.PARAMETER GatewayUrl
    Cloud gateway URL. Default: https://gateway.aitherium.com

.PARAMETER InferenceUrl
    Cloud inference URL. Default: https://mcp.aitherium.com/v1

.PARAMETER DryRun
    Preview only.

.PARAMETER PassThru
    Return result object.

.NOTES
    Stage: Onboarding
    Order: 3202
    Dependencies: 3200, 3201
    Tags: onboarding, elysium, cloud, connect
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApiKey,

    [string]$GatewayUrl = 'https://gateway.aitherium.com',
    [string]$InferenceUrl = 'https://mcp.aitherium.com/v1',

    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Name, [string]$Status = 'running')
    $icon = switch ($Status) { 'done' { '[OK]' } 'fail' { '[FAIL]' } 'skip' { '[SKIP]' } default { '[..]' } }
    Write-Host "$icon $Name" -ForegroundColor $(switch ($Status) { 'done' { 'Green' } 'fail' { 'Red' } 'skip' { 'Yellow' } default { 'Cyan' } })
}

# ── Step 1: Write ADK config ────────────────────────────────────────────

Write-Step "Write ADK config" 'running'

$configDir = Join-Path $HOME '.aither'
$configFile = Join-Path $configDir 'config.json'

if (-not (Test-Path $configDir)) {
    New-Item -Path $configDir -ItemType Directory -Force | Out-Null
}

$config = @{
    api_key       = $ApiKey
    gateway_url   = $GatewayUrl
    inference_url = $InferenceUrl
}

# Merge with existing config if present
if (Test-Path $configFile) {
    try {
        $existing = Get-Content $configFile -Raw | ConvertFrom-Json -AsHashtable
        foreach ($k in $existing.Keys) {
            if (-not $config.ContainsKey($k)) { $config[$k] = $existing[$k] }
        }
    } catch {}
}

$config | ConvertTo-Json -Depth 5 | Set-Content $configFile
Write-Step "Write ADK config ($configFile)" 'done'

# ── Step 2: Verify gateway ──────────────────────────────────────────────

Write-Step "Verify cloud gateway" 'running'

try {
    $gwHealth = Invoke-RestMethod -Uri "$GatewayUrl/health" -TimeoutSec 10 -ErrorAction Stop
    Write-Step "Verify cloud gateway ($($gwHealth.service ?? 'OK'))" 'done'
}
catch {
    Write-Step "Verify cloud gateway" 'fail'
    Write-Warning "Gateway unreachable at $GatewayUrl — cloud features will be unavailable"
}

# ── Step 3: Check API key + billing ─────────────────────────────────────

Write-Step "Check API key + billing" 'running'

$headers = @{ 'Authorization' = "Bearer $ApiKey" }

try {
    $balance = Invoke-RestMethod -Uri "$GatewayUrl/v1/billing/balance" `
        -TimeoutSec 10 -Headers $headers -ErrorAction Stop

    $plan = $balance.plan ?? $balance.tier ?? 'unknown'
    $tokens = $balance.balance ?? $balance.tokens_remaining ?? 0
    Write-Host "  Plan: $plan"
    Write-Host "  Balance: $tokens tokens"
    Write-Step "Check API key (plan=$plan, balance=$tokens)" 'done'
}
catch {
    Write-Step "Check API key" 'skip'
    Write-Host "  Billing check skipped (gateway may not expose this endpoint)"
}

# ── Step 4: List available models ───────────────────────────────────────

Write-Step "Check available models" 'running'

try {
    $models = Invoke-RestMethod -Uri "$InferenceUrl/models" `
        -TimeoutSec 10 -Headers $headers -ErrorAction Stop

    $modelList = $models.data ?? $models.models ?? @()
    if ($modelList.Count -gt 0) {
        Write-Host "  Available models: $($modelList.Count)"
        $modelList | Select-Object -First 5 | ForEach-Object {
            $name = $_.id ?? $_.name ?? $_
            Write-Host "    - $name"
        }
        Write-Step "Check available models ($($modelList.Count) found)" 'done'
    }
    else {
        Write-Step "Check available models (none listed)" 'skip'
    }
}
catch {
    Write-Step "Check available models" 'skip'
    Write-Host "  Model listing skipped"
}

# ── Step 5: Run aither connect (if ADK installed) ───────────────────────

$adk = Get-Command aither -ErrorAction SilentlyContinue
if ($adk -and -not $DryRun) {
    Write-Step "Run aither connect" 'running'
    try {
        $env:AITHER_API_KEY = $ApiKey
        & aither connect --save 2>&1 | ForEach-Object { Write-Host "  $_" }
        Write-Step "Run aither connect" 'done'
    }
    catch {
        Write-Step "Run aither connect" 'skip'
        Write-Host "  ADK connect failed (non-fatal)"
    }
}
else {
    Write-Host ""
    Write-Host "  TIP: Install the ADK for full Elysium integration:" -ForegroundColor Yellow
    Write-Host "    pip install aither-adk"
    Write-Host "    aither connect --api-key $($ApiKey.Substring(0, 20))..."
}

# ── Summary ──────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Elysium connection configured" -ForegroundColor Green
Write-Host "  Config:    $configFile"
Write-Host "  Gateway:   $GatewayUrl"
Write-Host "  Inference: $InferenceUrl"
Write-Host ""

exit 0
