#Requires -Version 7.0
<#
.SYNOPSIS
    Enforce Cloudflare SSL/TLS hardening for aitherium.com.

.DESCRIPTION
    Applies and verifies recommended SSL/TLS settings via the Cloudflare API:
    - HSTS: max-age=31536000, includeSubDomains, preload, nosniff
    - SSL mode: Full (Strict)
    - TLS 1.3 with 0-RTT
    - Minimum TLS 1.2
    - Always Use HTTPS
    - Automatic HTTPS Rewrites
    - Opportunistic Encryption

    Token resolution order:
    1. -ApiToken parameter
    2. CF_ZONE_SETTINGS_TOKEN environment variable
    3. .env file (CF_ZONE_SETTINGS_TOKEN=...)
    4. AitherZero credential vault (CF-ZoneSettings-Token)
    5. AitherSecrets service (localhost:8111)

    Designed to be idempotent — safe to run repeatedly (e.g., post-deploy,
    scheduled health checks, ring promotions).

.PARAMETER Action
    What to do:
    - "enforce"  : Apply all hardening settings (default)
    - "verify"   : Check current state, report drift, return exit code
    - "report"   : Output current settings as JSON

.PARAMETER ApiToken
    Cloudflare API token with Zone Settings:Edit permission.
    If omitted, resolved from env/vault/secrets (see description).

.PARAMETER DryRun
    Show what would be changed without calling the CF API.

.PARAMETER ZoneId
    Override zone ID (default: aitherium.com zone).

.EXAMPLE
    # Enforce hardening (auto-resolves token)
    .\3042_Enforce-CloudflareSSL.ps1

.EXAMPLE
    # Verify settings without changing anything
    .\3042_Enforce-CloudflareSSL.ps1 -Action verify

.EXAMPLE
    # Dry run with explicit token
    .\3042_Enforce-CloudflareSSL.ps1 -DryRun -ApiToken "my-token"

.EXAMPLE
    # JSON report for ingestion by Strata/monitoring
    .\3042_Enforce-CloudflareSSL.ps1 -Action report
#>
[CmdletBinding()]
param(
    [ValidateSet("enforce", "verify", "report")]
    [string]$Action = "enforce",

    [string]$ApiToken = "",
    [string]$ZoneId = "80609e8d25ddd5e44f2735977e0e58bf",

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Paths ─────────────────────────────────────────────────────────────────
$ProjectRoot = (Resolve-Path "$PSScriptRoot/../../../../").Path
$EnvFile     = Join-Path $ProjectRoot ".env"

# ── Helpers ───────────────────────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "  ▸ $Msg" -ForegroundColor Cyan }
function Write-Good  { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Bad   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  ℹ $Msg" -ForegroundColor DarkGray }
function Write-Title { param([string]$Msg) Write-Host "`n═══ $Msg ═══" -ForegroundColor Yellow }

# ── Token Resolution ──────────────────────────────────────────────────────
function Resolve-CfZoneToken {
    <#
    .SYNOPSIS
        Resolve CF Zone Settings token from multiple sources.
    #>

    # 1. Parameter
    if ($script:ApiToken) { return $script:ApiToken }

    # 2. Environment variable
    if ($env:CF_ZONE_SETTINGS_TOKEN) { return $env:CF_ZONE_SETTINGS_TOKEN }

    # 3. .env file
    if (Test-Path $EnvFile) {
        $envContent = Get-Content $EnvFile -Raw
        if ($envContent -match 'CF_ZONE_SETTINGS_TOKEN=(.+)') {
            $val = $Matches[1].Trim()
            if ($val) { return $val }
        }
    }

    # 4. AitherZero credential vault (DPAPI encrypted)
    try {
        if (Get-Command Get-AitherCredential -ErrorAction SilentlyContinue) {
            $credBase = if ($IsWindows) { Join-Path $env:USERPROFILE ".aitherzero" "credentials" } else { Join-Path $env:HOME ".aitherzero" "credentials" }
            $credFile = Join-Path $credBase "CF-ZoneSettings-Token.cred"

            if (Test-Path $credFile) {
                $credData = Import-Clixml -Path $credFile
                if ($credData.Type -eq 'ApiKey' -and $credData.Key) {
                    $secStr = $credData.Key | ConvertTo-SecureString
                    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secStr)
                    try {
                        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                    } finally {
                        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                    }
                }
            }
        }
    } catch {
        Write-Info "Vault lookup failed: $_"
    }

    # 5. AitherSecrets service
    try {
        $resp = Invoke-RestMethod -Uri "http://localhost:8111/secrets/CF_ZONE_SETTINGS_TOKEN" -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($resp.value) { return $resp.value }
    } catch { }

    return $null
}

# ── Desired State ─────────────────────────────────────────────────────────
$DesiredSettings = [ordered]@{
    security_header = @{
        Label = "HSTS"
        Body  = @{
            value = @{
                strict_transport_security = @{
                    enabled            = $true
                    max_age            = 31536000
                    include_subdomains = $true
                    preload            = $true
                    nosniff            = $true
                }
            }
        }
        Verify = {
            param($result)
            $s = $result.result.value.strict_transport_security
            ($s.enabled -eq $true) -and ($s.max_age -ge 31536000) -and
            ($s.include_subdomains -eq $true) -and ($s.preload -eq $true)
        }
        Describe = {
            param($result)
            $s = $result.result.value.strict_transport_security
            "max-age=$($s.max_age), includeSubDomains=$($s.include_subdomains), preload=$($s.preload)"
        }
    }
    ssl = @{
        Label = "SSL Mode"
        Body  = @{ value = "strict" }
        Verify = { param($r) $r.result.value -eq "strict" }
        Describe = { param($r) $r.result.value }
    }
    always_use_https = @{
        Label = "Always Use HTTPS"
        Body  = @{ value = "on" }
        Verify = { param($r) $r.result.value -eq "on" }
        Describe = { param($r) $r.result.value }
    }
    tls_1_3 = @{
        Label = "TLS 1.3"
        Body  = @{ value = "zrt" }
        Verify = { param($r) $r.result.value -in @("on", "zrt") }
        Describe = { param($r) $r.result.value }
    }
    min_tls_version = @{
        Label = "Minimum TLS Version"
        Body  = @{ value = "1.2" }
        Verify = { param($r) $r.result.value -eq "1.2" }
        Describe = { param($r) $r.result.value }
    }
    automatic_https_rewrites = @{
        Label = "Auto HTTPS Rewrites"
        Body  = @{ value = "on" }
        Verify = { param($r) $r.result.value -eq "on" }
        Describe = { param($r) $r.result.value }
    }
    opportunistic_encryption = @{
        Label = "Opportunistic Encryption"
        Body  = @{ value = "on" }
        Verify = { param($r) $r.result.value -eq "on" }
        Describe = { param($r) $r.result.value }
    }
}

# ── Main ──────────────────────────────────────────────────────────────────
Write-Title "Cloudflare SSL/TLS Hardening — aitherium.com"

# Resolve token
$token = Resolve-CfZoneToken
if (-not $token) {
    Write-Bad "No API token found. Provide via -ApiToken, CF_ZONE_SETTINGS_TOKEN env var, .env, or vault."
    Write-Host @"

  Create a token at: https://dash.cloudflare.com/profile/api-tokens
    Permissions: Zone → Zone Settings → Edit
    Zone: aitherium.com

  Then store it:
    `$ss = Read-Host -AsSecureString 'Token'
    Set-AitherCredential -Name 'CF-ZoneSettings-Token' -ApiKey `$ss

"@ -ForegroundColor Yellow
    exit 1
}

$tokenPreview = $token.Substring(0, [Math]::Min(8, $token.Length)) + "..."
Write-Info "Token resolved: $tokenPreview"

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}
$base = "https://api.cloudflare.com/client/v4/zones/$ZoneId/settings"

# Verify token access
try {
    $verify = Invoke-RestMethod "https://api.cloudflare.com/client/v4/user/tokens/verify" -Headers $headers
    if ($verify.result.status -ne "active") { throw "Token not active" }
    Write-Good "Token valid"
} catch {
    Write-Bad "Token verification failed: $($_.Exception.Message)"
    exit 1
}

# ── Read current state ────────────────────────────────────────────────────
$currentState = @{}
$driftCount = 0

Write-Title "Current State"
foreach ($setting in $DesiredSettings.GetEnumerator()) {
    $key = $setting.Key
    $cfg = $setting.Value
    try {
        $result = Invoke-RestMethod "$base/$key" -Headers $headers
        $currentState[$key] = $result
        $ok = & $cfg.Verify $result
        $desc = & $cfg.Describe $result
        if ($ok) {
            Write-Good "$($cfg.Label): $desc"
        } else {
            Write-Bad "$($cfg.Label): $desc (DRIFT)"
            $driftCount++
        }
    } catch {
        Write-Bad "$($cfg.Label): (could not read — $($_.Exception.Message))"
        $driftCount++
    }
}

# ── Action: report ────────────────────────────────────────────────────────
if ($Action -eq "report") {
    $report = [ordered]@{
        zone       = "aitherium.com"
        zone_id    = $ZoneId
        timestamp  = (Get-Date).ToString('o')
        drift      = $driftCount -gt 0
        settings   = [ordered]@{}
    }
    foreach ($setting in $DesiredSettings.GetEnumerator()) {
        $key = $setting.Key
        $cfg = $setting.Value
        if ($currentState.ContainsKey($key)) {
            $ok = & $cfg.Verify $currentState[$key]
            $report.settings[$key] = [ordered]@{
                label    = $cfg.Label
                compliant = $ok
                value     = & $cfg.Describe $currentState[$key]
            }
        }
    }
    $report | ConvertTo-Json -Depth 10
    exit $(if ($driftCount -gt 0) { 1 } else { 0 })
}

# ── Action: verify ────────────────────────────────────────────────────────
if ($Action -eq "verify") {
    if ($driftCount -eq 0) {
        Write-Title "Result"
        Write-Good "All $($DesiredSettings.Count) settings compliant — no drift detected."
        exit 0
    } else {
        Write-Title "Result"
        Write-Bad "$driftCount of $($DesiredSettings.Count) settings drifted from desired state."
        Write-Host "  Run without -Action verify to enforce." -ForegroundColor Yellow
        exit 1
    }
}

# ── Action: enforce ───────────────────────────────────────────────────────
if ($driftCount -eq 0) {
    Write-Title "Result"
    Write-Good "All settings already compliant — nothing to do."
    exit 0
}

Write-Title "Enforcing $driftCount Setting(s)"

$applied = 0
$failed = 0

foreach ($setting in $DesiredSettings.GetEnumerator()) {
    $key = $setting.Key
    $cfg = $setting.Value

    # Skip if already compliant
    if ($currentState.ContainsKey($key)) {
        $ok = & $cfg.Verify $currentState[$key]
        if ($ok) { continue }
    }

    Write-Step "$($cfg.Label)"
    if ($DryRun) {
        Write-Info "DRY RUN — would PATCH $key"
        Write-Info "  Body: $($cfg.Body | ConvertTo-Json -Compress -Depth 10)"
        $applied++
        continue
    }

    try {
        $r = Invoke-RestMethod -Method PATCH -Uri "$base/$key" `
            -Headers $headers -Body ($cfg.Body | ConvertTo-Json -Depth 10)
        if ($r.success) {
            Write-Good "Applied"
            $applied++
        } else {
            Write-Bad "Failed: $($r.errors | ConvertTo-Json -Compress)"
            $failed++
        }
    } catch {
        $err = $null
        try { $err = $_.ErrorDetails.Message | ConvertFrom-Json } catch { }
        if ($err) {
            Write-Bad "Error: $($err.errors[0].message)"
        } else {
            Write-Bad "Error: $($_.Exception.Message)"
        }
        $failed++
    }
}

# ── Final verification ────────────────────────────────────────────────────
if (-not $DryRun -and $applied -gt 0) {
    Write-Title "Verification"
    Start-Sleep -Seconds 2
    $finalDrift = 0
    foreach ($setting in $DesiredSettings.GetEnumerator()) {
        $key = $setting.Key
        $cfg = $setting.Value
        try {
            $result = Invoke-RestMethod "$base/$key" -Headers $headers
            $ok = & $cfg.Verify $result
            $desc = & $cfg.Describe $result
            if ($ok) {
                Write-Good "$($cfg.Label): $desc"
            } else {
                Write-Bad "$($cfg.Label): $desc (STILL DRIFTED)"
                $finalDrift++
            }
        } catch {
            Write-Bad "$($cfg.Label): verification failed"
            $finalDrift++
        }
    }

    if ($finalDrift -gt 0) {
        Write-Bad "$finalDrift setting(s) still non-compliant after enforcement."
        exit 1
    }
}

# ── Summary ───────────────────────────────────────────────────────────────
Write-Title "Summary"
$prefix = if ($DryRun) { "Would apply" } else { "Applied" }
Write-Good "$prefix $applied fix(es), $failed failure(s)."

if (-not $DryRun -and $applied -gt 0) {
    Write-Info "Changes propagate in ~60 seconds."
    Write-Info "HSTS preload submission: https://hstspreload.org"

    # Report to Pulse if available
    try {
        $pulsePayload = @{
            type      = "cloudflare_ssl_enforcement"
            source    = "3042_Enforce-CloudflareSSL"
            timestamp = (Get-Date).ToString('o')
            data      = @{ applied = $applied; failed = $failed; dryRun = [bool]$DryRun }
        } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri "http://localhost:8081/pulse/events" -Method POST `
            -Body $pulsePayload -ContentType "application/json" -TimeoutSec 3 -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

exit $(if ($failed -gt 0) { 1 } else { 0 })
