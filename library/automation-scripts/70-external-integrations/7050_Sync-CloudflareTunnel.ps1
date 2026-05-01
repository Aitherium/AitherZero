#Requires -Version 7.0
<#
.SYNOPSIS
    Sync Cloudflare Named Tunnel ingress from source-of-truth YAML.

.DESCRIPTION
    Reads AitherOS/config/cloudflare/tunnel-ingress.yaml and applies it to
    the live tunnel via Cloudflare API. Supports -DryRun for diff preview.

    The Cloudflare API tunnel-config schema differs from cloudflared YAML:
      - Uses camelCase (originRequest already matches)
      - `service` is a string at the same level as hostname/path
      - Wraps the ingress array in { config: { ingress: [...] } }

.PARAMETER ConfigPath
    Path to tunnel-ingress.yaml. Defaults to repo source-of-truth.

.PARAMETER DryRun
    Print the diff between current and desired config without applying.

.EXAMPLE
    pwsh -File ./AitherZero/library/automation-scripts/70-external-integrations/7050_Sync-CloudflareTunnel.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../../../../AitherOS/config/cloudflare/tunnel-ingress.yaml'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  ✓ $msg"  -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  ! $msg"  -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "  ✗ $msg"  -ForegroundColor Red }

# --- Validate env -----------------------------------------------------------
$token   = $env:CLOUDFLARE_API_TOKEN
$account = $env:CLOUDFLARE_ACCOUNT_ID
if (-not $token)   { throw 'CLOUDFLARE_API_TOKEN env var is required' }
if (-not $account) { throw 'CLOUDFLARE_ACCOUNT_ID env var is required' }

# --- Load source-of-truth ---------------------------------------------------
$ConfigPath = (Resolve-Path -Path $ConfigPath).Path
Write-Step "Loading $ConfigPath"

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Step 'Installing powershell-yaml module'
    Install-Module powershell-yaml -Scope CurrentUser -Force -AllowClobber | Out-Null
}
Import-Module powershell-yaml -Force

$desired = ConvertFrom-Yaml (Get-Content -Raw -Path $ConfigPath)
$tunnelId = $desired.tunnel_id
if (-not $tunnelId) { throw "tunnel_id missing from $ConfigPath" }
if ($env:CLOUDFLARE_TUNNEL_ID -and $env:CLOUDFLARE_TUNNEL_ID -ne $tunnelId) {
    Write-Warn2 "env CLOUDFLARE_TUNNEL_ID ($env:CLOUDFLARE_TUNNEL_ID) overrides yaml ($tunnelId)"
    $tunnelId = $env:CLOUDFLARE_TUNNEL_ID
}
Write-Ok "Tunnel: $tunnelId  Ingress rules: $($desired.ingress.Count)"

# --- Build CF API payload ---------------------------------------------------
$payload = @{
    config = @{
        ingress      = $desired.ingress
        warp_routing = $desired.warp_routing
    }
}
$body = $payload | ConvertTo-Json -Depth 12

$apiBase = "https://api.cloudflare.com/client/v4/accounts/$account/cfd_tunnel/$tunnelId/configurations"
$headers = @{
    Authorization  = "Bearer $token"
    'Content-Type' = 'application/json'
}

# --- Fetch current ----------------------------------------------------------
Write-Step 'Fetching current tunnel configuration'
$current = Invoke-RestMethod -Uri $apiBase -Headers $headers -Method Get
if (-not $current.success) {
    Write-Err2 "Cloudflare API error: $($current.errors | ConvertTo-Json -Depth 5)"
    throw 'Failed to fetch current config'
}
$currentJson = $current.result.config | ConvertTo-Json -Depth 12
$desiredJson = $payload.config       | ConvertTo-Json -Depth 12

if ($currentJson -eq $desiredJson) {
    Write-Ok 'Tunnel config already matches source of truth — no changes needed'
    return
}

Write-Warn2 'Config drift detected:'
Write-Host '--- CURRENT ---' -ForegroundColor DarkGray
Write-Host $currentJson
Write-Host '--- DESIRED ---' -ForegroundColor DarkGray
Write-Host $desiredJson

if ($DryRun) {
    Write-Ok 'DryRun — not applying changes'
    return
}

# --- Apply ------------------------------------------------------------------
Write-Step 'Applying desired configuration'
$resp = Invoke-RestMethod -Uri $apiBase -Headers $headers -Method Put -Body $body
if (-not $resp.success) {
    Write-Err2 "Cloudflare API rejected update: $($resp.errors | ConvertTo-Json -Depth 5)"
    throw 'Apply failed'
}
Write-Ok 'Tunnel configuration updated successfully'
