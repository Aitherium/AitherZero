#Requires -Version 7.0
<#
.SYNOPSIS
    Patch a SINGLE Cloudflare tunnel ingress rule's service, in place.

.DESCRIPTION
    Unlike 7050 (which replaces the WHOLE ingress from the source-of-truth YAML),
    this fetches the LIVE tunnel config and changes ONLY the one ingress rule whose
    hostname matches -Hostname, leaving every other rule byte-for-byte as it is live.
    Use this when the YAML has diverged from live and a full sync would cause
    collateral changes (e.g. idp/garg/smtp drift) — it deploys exactly one rule with
    zero blast radius.

    Guardrails: refuses if the hostname isn't found; no-ops if already set; asserts
    the ingress length is unchanged and that EXACTLY one rule differs before PUT.

.PARAMETER Hostname
    The ingress hostname to patch (default '*.aitherium.com').

.PARAMETER Service
    The new service URL (default 'http://aitheros-veil-lb:3000').

.PARAMETER DryRun
    Show the before/after for the matched rule and exit without applying.

.EXAMPLE
    pwsh -File ./7051_Patch-CloudflareTunnelRule.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Hostname = '*.aitherium.com',
    [string]$Service  = 'http://aitheros-veil-lb:3000',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "  $([char]0x2713) $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }

$token = $env:CLOUDFLARE_API_TOKEN
$acct  = $env:CLOUDFLARE_ACCOUNT_ID
$tun   = $env:CLOUDFLARE_TUNNEL_ID
if (-not $token) { throw 'CLOUDFLARE_API_TOKEN env var is required' }
if (-not $acct)  { throw 'CLOUDFLARE_ACCOUNT_ID env var is required' }
if (-not $tun)   { throw 'CLOUDFLARE_TUNNEL_ID env var is required' }

$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$uri = "https://api.cloudflare.com/client/v4/accounts/$acct/cfd_tunnel/$tun/configurations"

Write-Step "Fetching live tunnel configuration"
$resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
if (-not $resp.success) { throw "Cloudflare GET failed: $($resp.errors | ConvertTo-Json -Compress)" }
$config = $resp.result.config
$ingress = @($config.ingress)
$beforeCount = $ingress.Count
Write-Ok "Tunnel $tun  ingress rules: $beforeCount"

# Locate the rule by exact hostname.
$match = $ingress | Where-Object { $_.hostname -eq $Hostname }
if (-not $match) { throw "No ingress rule with hostname '$Hostname' found in live config — refusing to add/remove." }
if ($match.Count -gt 1) { throw "Multiple ($($match.Count)) rules match '$Hostname' — refusing (ambiguous)." }

$oldService = $match.service
if ($oldService -eq $Service) {
    Write-Ok "Already set: $Hostname -> $Service  (no-op)"
    return
}

Write-Host ""
Write-Host "  PATCH  $Hostname" -ForegroundColor White
Write-Host "    current: $oldService" -ForegroundColor Red
Write-Host "    desired: $Service"    -ForegroundColor Green
Write-Host ""

# Snapshot every OTHER rule so we can prove only this one changes.
$beforeJson = $ingress | ForEach-Object { ($_ | ConvertTo-Json -Depth 20 -Compress) }

# Apply the change in place.
$match.service = $Service

$afterJson = $ingress | ForEach-Object { ($_ | ConvertTo-Json -Depth 20 -Compress) }

# Guardrail: length unchanged + exactly one rule differs.
if ($ingress.Count -ne $beforeCount) { throw "Ingress length changed ($beforeCount -> $($ingress.Count)) — aborting." }
$changed = 0
for ($i = 0; $i -lt $beforeJson.Count; $i++) { if ($beforeJson[$i] -ne $afterJson[$i]) { $changed++ } }
if ($changed -ne 1) { throw "Expected exactly 1 changed rule, got $changed — aborting (refusing to risk collateral)." }
Write-Ok "Verified: exactly 1 rule changes, $beforeCount rules preserved"

if ($DryRun) { Write-Warn "DryRun — not applying"; return }

Write-Step "Applying targeted patch (PUT)"
$body = @{ config = $config } | ConvertTo-Json -Depth 30
$put = Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body $body
if (-not $put.success) { throw "Cloudflare PUT failed: $($put.errors | ConvertTo-Json -Compress)" }

# Verify by re-reading.
$verify = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
$now = (@($verify.result.config.ingress) | Where-Object { $_.hostname -eq $Hostname }).service
if ($now -eq $Service) { Write-Ok "Applied + verified: $Hostname -> $now" }
else { throw "Post-PUT verify mismatch: $Hostname is '$now', expected '$Service'" }
