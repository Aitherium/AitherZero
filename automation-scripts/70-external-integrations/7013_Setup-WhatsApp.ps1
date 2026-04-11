#Requires -Version 7.0
<#
.SYNOPSIS
    Fully automated WhatsApp Cloud API integration setup for AitherOS.
.DESCRIPTION
    Validates Meta Cloud API credentials, stores them in AitherSecrets and .env.whatsapp,
    starts the AitherWhatsApp Docker service, and verifies health.
    Idempotent -- safe to run multiple times.
.PARAMETER WhatsAppApiToken
    Permanent access token from Meta Developer Console. Required.
    Found at: https://developers.facebook.com -> Your App -> WhatsApp -> API Setup
.PARAMETER WhatsAppPhoneNumberId
    Phone Number ID from Meta Developer Console. Required.
    Found at: https://developers.facebook.com -> Your App -> WhatsApp -> API Setup
.PARAMETER WhatsAppVerifyToken
    Webhook verification token. Optional, defaults to 'aitheros-whatsapp-verify'.
    Must match the value you set in Meta Developer Console webhook configuration.
.PARAMETER WhatsAppBusinessAccountId
    WhatsApp Business Account ID. Optional, used for template management.
.PARAMETER SkipValidation
    Skip Meta API validation (useful for offline or air-gapped environments)
.PARAMETER SkipDocker
    Skip Docker service start (credentials-only mode)
.PARAMETER HealthCheckAttempts
    Number of health check polling attempts (default 30)
.EXAMPLE
    .\7013_Setup-WhatsApp.ps1 -WhatsAppApiToken "EAA..." -WhatsAppPhoneNumberId "123456789"
.EXAMPLE
    .\7013_Setup-WhatsApp.ps1 -WhatsAppApiToken "EAA..." -WhatsAppPhoneNumberId "123456789" -WhatsAppVerifyToken "my-secret"
.NOTES
    Author: AitherZero Automation
    Service: AitherWhatsApp (port 8222)
    Layer: Communication
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WhatsAppApiToken,
    [Parameter(Mandatory)][string]$WhatsAppPhoneNumberId,
    [string]$WhatsAppVerifyToken = 'aitheros-whatsapp-verify',
    [string]$WhatsAppBusinessAccountId,
    [switch]$SkipValidation,
    [switch]$SkipDocker,
    [int]$HealthCheckAttempts = 30
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ── Source _init.ps1 ──────────────────────────────────────────────────────
. (Join-Path $PSScriptRoot '../_init.ps1')

# ── Resolve workspace root ────────────────────────────────────────────────
$WorkspaceRoot = $PSScriptRoot
while ($WorkspaceRoot -and -not (Test-Path (Join-Path $WorkspaceRoot 'docker-compose.aitheros.yml'))) {
    $parent = Split-Path $WorkspaceRoot -Parent
    if ($parent -eq $WorkspaceRoot) { $WorkspaceRoot = $null; break }
    $WorkspaceRoot = $parent
}
if (-not $WorkspaceRoot) {
    throw "Could not locate workspace root (docker-compose.aitheros.yml not found)."
}

$EnvFile       = Join-Path $WorkspaceRoot '.env.whatsapp'
$MainEnvFile   = Join-Path $WorkspaceRoot '.env'
$SecretsUrl    = 'http://localhost:8111'
$MetaApiBase   = 'https://graph.facebook.com/v21.0'
$ServicePort   = 8222

# ── Output helpers ────────────────────────────────────────────────────────
function Write-Step  { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK    { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red }

function Get-SecretsApiKey {
    param([string]$EnvFilePath)

    foreach ($name in @('AITHER_ADMIN_KEY', 'AITHER_INTERNAL_SECRET', 'AITHER_MASTER_KEY')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }

    if (Test-Path $EnvFilePath) {
        foreach ($name in @('AITHER_ADMIN_KEY', 'AITHER_INTERNAL_SECRET', 'AITHER_MASTER_KEY')) {
            $line = Select-String -Path $EnvFilePath -Pattern "^$name=(.+)$" -CaseSensitive |
                    Select-Object -First 1
            if ($line) {
                return $line.Matches[0].Groups[1].Value.Trim()
            }
        }
    }

    return 'dev-internal-secret-687579a3'
}

# ============================================================================
# Step 1: Check prerequisites
# ============================================================================
Write-Step "Checking prerequisites..."

# Docker
try {
    $dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
    if ($dockerVersion) {
        Write-OK "Docker $dockerVersion"
    } else {
        throw "no version"
    }
} catch {
    Write-Err "Docker is not running or not installed. Please install Docker Desktop."
    exit 1
}

# Python
try {
    $pythonVersion = python --version 2>$null
    Write-OK "$pythonVersion"
} catch {
    Write-Warn "Python not found on PATH (optional, Docker will handle runtime)."
}

# AitherOS running (Genesis health check)
try {
    $genesisHealth = Invoke-RestMethod -Uri 'http://localhost:8001/health' -TimeoutSec 5 -ErrorAction Stop
    Write-OK "AitherOS Genesis is running."
} catch {
    Write-Warn "Genesis (port 8001) is not reachable. Service may need manual start later."
}

# ============================================================================
# Step 2: Validate credential formats
# ============================================================================
Write-Step "Validating credential formats..."

if ($WhatsAppApiToken.Length -lt 20) {
    Write-Err "WHATSAPP_API_TOKEN appears too short ($($WhatsAppApiToken.Length) chars). Expected a long-lived access token."
    exit 1
}
Write-OK "API token format valid ($($WhatsAppApiToken.Length) chars)"

if ($WhatsAppPhoneNumberId -notmatch '^\d+$') {
    Write-Err "WHATSAPP_PHONE_NUMBER_ID must be numeric. Got: '$WhatsAppPhoneNumberId'"
    exit 1
}
Write-OK "Phone Number ID format valid ($WhatsAppPhoneNumberId)"

Write-OK "Verify token: '$WhatsAppVerifyToken'"

if ($WhatsAppBusinessAccountId) {
    if ($WhatsAppBusinessAccountId -notmatch '^\d+$') {
        Write-Err "WHATSAPP_BUSINESS_ACCOUNT_ID must be numeric. Got: '$WhatsAppBusinessAccountId'"
        exit 1
    }
    Write-OK "Business Account ID: $WhatsAppBusinessAccountId"
}

# ============================================================================
# Step 3: Validate credentials via Meta Graph API
# ============================================================================
if (-not $SkipValidation) {
    Write-Step "Validating credentials against Meta Graph API..."

    try {
        $headers = @{ 'Authorization' = "Bearer $WhatsAppApiToken" }
        $phoneInfo = Invoke-RestMethod -Uri "$MetaApiBase/$WhatsAppPhoneNumberId" `
                                       -Headers $headers -TimeoutSec 15 -ErrorAction Stop

        if ($phoneInfo.id) {
            Write-OK "Phone number validated successfully."
            if ($phoneInfo.display_phone_number) {
                Write-Host "    Phone Number: $($phoneInfo.display_phone_number)" -ForegroundColor Gray
            }
            if ($phoneInfo.verified_name) {
                Write-Host "    Verified Name: $($phoneInfo.verified_name)" -ForegroundColor Gray
            }
            if ($phoneInfo.quality_rating) {
                Write-Host "    Quality Rating: $($phoneInfo.quality_rating)" -ForegroundColor Gray
            }
            if ($phoneInfo.platform_type) {
                Write-Host "    Platform: $($phoneInfo.platform_type)" -ForegroundColor Gray
            }
        } else {
            Write-Warn "API returned data but no ID field. Credentials may be partially valid."
        }
    } catch {
        $errMsg = $_.Exception.Message

        # Parse Meta API error if JSON
        try {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
            if ($errBody.error) {
                $errMsg = "$($errBody.error.type): $($errBody.error.message) (code $($errBody.error.code))"
            }
        } catch {}

        Write-Err "Meta API validation failed: $errMsg"
        Write-Host ""
        Write-Host "    Common causes:" -ForegroundColor Yellow
        Write-Host "      - Token expired (temporary tokens last 24h)" -ForegroundColor Yellow
        Write-Host "      - Wrong Phone Number ID" -ForegroundColor Yellow
        Write-Host "      - App not connected to WhatsApp Business Account" -ForegroundColor Yellow
        Write-Host "      - Missing whatsapp_business_messaging permission" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    Generate a permanent token:" -ForegroundColor Yellow
        Write-Host "      1. Create a System User in Meta Business Settings" -ForegroundColor Gray
        Write-Host "      2. Assign assets (WhatsApp Business Account)" -ForegroundColor Gray
        Write-Host "      3. Generate token with whatsapp_business_messaging scope" -ForegroundColor Gray
        Write-Host ""
        Write-Host "    Retry with -SkipValidation to bypass this check." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Warn "Skipping Meta API validation (-SkipValidation)."
}

# ============================================================================
# Step 4: Save credentials to .env.whatsapp
# ============================================================================
Write-Step "Saving credentials to $EnvFile..."

$envLines = @(
    "# AitherWhatsApp configuration",
    "# Generated by 7013_Setup-WhatsApp.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "# DO NOT commit this file to source control.",
    "",
    "WHATSAPP_API_TOKEN=$WhatsAppApiToken",
    "WHATSAPP_PHONE_NUMBER_ID=$WhatsAppPhoneNumberId",
    "WHATSAPP_VERIFY_TOKEN=$WhatsAppVerifyToken"
)

if ($WhatsAppBusinessAccountId) {
    $envLines += "WHATSAPP_BUSINESS_ACCOUNT_ID=$WhatsAppBusinessAccountId"
}

Set-Content -Path $EnvFile -Value ($envLines -join "`n") -NoNewline
Write-OK "Saved to $EnvFile"

# Verify .gitignore includes .env.whatsapp
$gitignorePath = Join-Path $WorkspaceRoot '.gitignore'
if (Test-Path $gitignorePath) {
    $gitignoreContent = Get-Content $gitignorePath -Raw
    if ($gitignoreContent -notmatch '\.env\.whatsapp') {
        Add-Content -Path $gitignorePath -Value "`n.env.whatsapp"
        Write-OK "Added .env.whatsapp to .gitignore"
    }
} else {
    Write-Warn ".gitignore not found -- ensure .env.whatsapp is not committed."
}

# ============================================================================
# Step 5: Store credentials in AitherSecrets
# ============================================================================
Write-Step "Storing credentials in AitherSecrets..."

$secrets = @{
    'WHATSAPP_API_TOKEN'        = $WhatsAppApiToken
    'WHATSAPP_PHONE_NUMBER_ID'  = $WhatsAppPhoneNumberId
    'WHATSAPP_VERIFY_TOKEN'     = $WhatsAppVerifyToken
}

if ($WhatsAppBusinessAccountId) {
    $secrets['WHATSAPP_BUSINESS_ACCOUNT_ID'] = $WhatsAppBusinessAccountId
}

try {
    Invoke-RestMethod -Uri "$SecretsUrl/health" -TimeoutSec 3 -ErrorAction Stop | Out-Null

    $secretsApiKey = Get-SecretsApiKey -EnvFilePath $MainEnvFile
    $headers = @{ 'X-API-Key' = $secretsApiKey }
    $storedCount = 0

    foreach ($kv in $secrets.GetEnumerator()) {
        $body = @{
            name         = $kv.Key
            value        = $kv.Value
            secret_type  = 'api_key'
            access_level = 'internal'
        } | ConvertTo-Json

        try {
            Invoke-RestMethod -Uri "$SecretsUrl/secrets?service=AitherWhatsApp" -Method Post `
                              -Body $body -Headers $headers `
                              -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $storedCount++
        } catch {
            Write-Warn "Failed to store $($kv.Key): $($_.Exception.Message)"
        }
    }

    if ($storedCount -eq $secrets.Count) {
        Write-OK "All $storedCount secrets stored in AitherSecrets."
    } else {
        Write-Warn "$storedCount of $($secrets.Count) secrets stored."
    }
} catch {
    Write-Warn "AitherSecrets (port 8111) not reachable: $($_.Exception.Message)"
    Write-Warn "Credentials saved to $EnvFile only. Store in Secrets when services are running."
}

# ============================================================================
# Step 6: Start Docker service
# ============================================================================
if (-not $SkipDocker) {
    Write-Step "Starting AitherWhatsApp Docker service..."

    try {
        $composeFile = Join-Path $WorkspaceRoot 'docker-compose.aitheros.yml'
        if (-not (Test-Path $composeFile)) {
            Write-Err "docker-compose.aitheros.yml not found at $composeFile"
            exit 1
        }

        Push-Location $WorkspaceRoot
        docker compose -f docker-compose.aitheros.yml --profile communication up -d aither-whatsapp 2>&1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        Pop-Location

        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-OK "Docker service started."
        } else {
            Write-Err "Docker compose exited with code $exitCode"
            exit 1
        }
    } catch {
        Write-Err "Failed to start Docker service: $($_.Exception.Message)"
        exit 1
    }

    # ============================================================================
    # Step 7: Health check loop
    # ============================================================================
    Write-Step "Waiting for AitherWhatsApp health (port $ServicePort)..."

    $healthUrl = "http://localhost:$ServicePort/health"
    $healthy = $false

    for ($i = 1; $i -le $HealthCheckAttempts; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3 -ErrorAction Stop
            if ($resp.status -eq 'healthy' -or $resp -eq 'ok' -or $null -ne $resp) {
                $healthy = $true
                break
            }
        } catch {
            # Expected during startup
        }

        $pct = [math]::Round(($i / $HealthCheckAttempts) * 100)
        Write-Host "`r    Attempt $i/$HealthCheckAttempts ($pct%)..." -NoNewline -ForegroundColor Gray
        Start-Sleep -Seconds 3
    }

    Write-Host ""

    if ($healthy) {
        Write-OK "AitherWhatsApp is healthy on port $ServicePort."
    } else {
        Write-Err "AitherWhatsApp did not become healthy after $HealthCheckAttempts attempts."
        Write-Host "    Check logs: docker logs -f aitheros-whatsapp" -ForegroundColor Yellow
    }
} else {
    Write-Warn "Skipping Docker service start (-SkipDocker). Credentials stored only."
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  AitherWhatsApp setup complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Service Port:      $ServicePort" -ForegroundColor White
Write-Host "  Env File:          $EnvFile" -ForegroundColor White
Write-Host "  Secrets:           AitherSecrets (port 8111)" -ForegroundColor White
Write-Host "  Phone Number ID:   $WhatsAppPhoneNumberId" -ForegroundColor White
Write-Host ""
Write-Host "  Webhook configuration (REQUIRED):" -ForegroundColor Yellow
Write-Host "    You must register the webhook URL in Meta Developer Console:" -ForegroundColor White
Write-Host ""
Write-Host "    1. Go to https://developers.facebook.com -> Your App -> WhatsApp -> Configuration" -ForegroundColor White
Write-Host "    2. Set Callback URL:" -ForegroundColor White
Write-Host "         https://<your-domain>/webhook" -ForegroundColor Gray
Write-Host "       or for development with ngrok/cloudflare tunnel:" -ForegroundColor White
Write-Host "         https://<tunnel-domain>/webhook" -ForegroundColor Gray
Write-Host "    3. Set Verify Token:" -ForegroundColor White
Write-Host "         $WhatsAppVerifyToken" -ForegroundColor Gray
Write-Host "    4. Subscribe to webhook fields:" -ForegroundColor White
Write-Host "         messages, message_deliveries, message_reads" -ForegroundColor Gray
Write-Host ""
Write-Host "  For local development:" -ForegroundColor Yellow
Write-Host "    cloudflared tunnel --url http://localhost:$ServicePort" -ForegroundColor Gray
Write-Host "    # or" -ForegroundColor Gray
Write-Host "    ngrok http $ServicePort" -ForegroundColor Gray
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor Yellow
Write-Host "    docker logs -f aitheros-whatsapp     # Follow logs" -ForegroundColor Gray
Write-Host "    docker restart aitheros-whatsapp      # Restart service" -ForegroundColor Gray
Write-Host ""
