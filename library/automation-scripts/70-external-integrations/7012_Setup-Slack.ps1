#Requires -Version 7.0
<#
.SYNOPSIS
    Fully automated Slack bot integration setup for AitherOS.
.DESCRIPTION
    Validates Slack API credentials, stores them in AitherSecrets and .env.slack,
    starts the AitherSlack Docker service, and verifies health.
    Idempotent -- safe to run multiple times.
.PARAMETER SlackBotToken
    Slack Bot User OAuth Token (xoxb-...). Required.
    Found at: https://api.slack.com/apps -> OAuth & Permissions -> Bot User OAuth Token
.PARAMETER SlackAppToken
    Slack App-Level Token (xapp-...). Required for Socket Mode.
    Found at: https://api.slack.com/apps -> Basic Information -> App-Level Tokens
.PARAMETER SlackSigningSecret
    Slack Signing Secret for request verification. Required.
    Found at: https://api.slack.com/apps -> Basic Information -> Signing Secret
.PARAMETER SkipValidation
    Skip Slack API validation (useful for offline or air-gapped environments)
.PARAMETER SkipDocker
    Skip Docker service start (credentials-only mode)
.PARAMETER HealthCheckAttempts
    Number of health check polling attempts (default 30)
.EXAMPLE
    .\7012_Setup-Slack.ps1 -SlackBotToken "xoxb-..." -SlackAppToken "xapp-..." -SlackSigningSecret "abc123"
.EXAMPLE
    .\7012_Setup-Slack.ps1 -SlackBotToken "xoxb-..." -SlackAppToken "xapp-..." -SlackSigningSecret "abc123" -SkipDocker
.NOTES
    Author: AitherZero Automation
    Service: AitherSlack (port 8221)
    Layer: Communication
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SlackBotToken,
    [Parameter(Mandatory)][string]$SlackAppToken,
    [Parameter(Mandatory)][string]$SlackSigningSecret,
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

$EnvFile      = Join-Path $WorkspaceRoot '.env.slack'
$MainEnvFile  = Join-Path $WorkspaceRoot '.env'
$SecretsUrl   = 'http://localhost:8111'
$SlackApiUrl  = 'https://slack.com/api'
$ServicePort  = 8221

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
# Step 2: Validate token formats
# ============================================================================
Write-Step "Validating credential formats..."

if ($SlackBotToken -notmatch '^xoxb-') {
    Write-Err "SLACK_BOT_TOKEN must start with 'xoxb-'. Got: $($SlackBotToken.Substring(0, [Math]::Min(10, $SlackBotToken.Length)))..."
    exit 1
}
Write-OK "Bot token format valid (xoxb-...)"

if ($SlackAppToken -notmatch '^xapp-') {
    Write-Err "SLACK_APP_TOKEN must start with 'xapp-'. Got: $($SlackAppToken.Substring(0, [Math]::Min(10, $SlackAppToken.Length)))..."
    exit 1
}
Write-OK "App token format valid (xapp-...)"

if ($SlackSigningSecret.Length -lt 16) {
    Write-Err "SLACK_SIGNING_SECRET appears too short (got $($SlackSigningSecret.Length) chars, expected 32+)."
    exit 1
}
Write-OK "Signing secret format valid ($($SlackSigningSecret.Length) chars)"

# ============================================================================
# Step 3: Validate credentials via Slack API
# ============================================================================
if (-not $SkipValidation) {
    Write-Step "Validating credentials against Slack API..."

    try {
        $headers = @{ 'Authorization' = "Bearer $SlackBotToken" }
        $authResult = Invoke-RestMethod -Uri "$SlackApiUrl/auth.test" `
                                        -Method POST -Headers $headers `
                                        -TimeoutSec 15 -ErrorAction Stop

        if ($authResult.ok -eq $true) {
            Write-OK "Bot authenticated as '$($authResult.user)' in workspace '$($authResult.team)'"
            Write-Host "    Bot ID:      $($authResult.user_id)" -ForegroundColor Gray
            Write-Host "    Team ID:     $($authResult.team_id)" -ForegroundColor Gray
            Write-Host "    Workspace:   $($authResult.url)" -ForegroundColor Gray
        } else {
            Write-Err "Slack API auth.test failed: $($authResult.error)"
            Write-Host "    Common causes:" -ForegroundColor Yellow
            Write-Host "      - Token revoked or expired" -ForegroundColor Yellow
            Write-Host "      - Bot not installed to workspace" -ForegroundColor Yellow
            Write-Host "      - Missing required OAuth scopes" -ForegroundColor Yellow
            exit 1
        }
    } catch {
        Write-Err "Could not reach Slack API: $($_.Exception.Message)"
        Write-Host "    Retry with -SkipValidation to bypass this check." -ForegroundColor Yellow
        exit 1
    }

    # Check bot scopes
    try {
        $headers = @{ 'Authorization' = "Bearer $SlackBotToken" }
        $scopeCheck = Invoke-WebRequest -Uri "$SlackApiUrl/auth.test" `
                                        -Method POST -Headers $headers `
                                        -TimeoutSec 15 -ErrorAction Stop

        $scopeHeader = $scopeCheck.Headers['x-oauth-scopes']
        if ($scopeHeader) {
            $scopes = ($scopeHeader -join ',').Split(',') | ForEach-Object { $_.Trim() }
            $requiredScopes = @('chat:write', 'channels:read', 'app_mentions:read')
            $missingScopes = $requiredScopes | Where-Object { $_ -notin $scopes }

            if ($missingScopes.Count -gt 0) {
                Write-Warn "Missing recommended scopes: $($missingScopes -join ', ')"
                Write-Host "    Add them at: https://api.slack.com/apps -> OAuth & Permissions" -ForegroundColor Yellow
            } else {
                Write-OK "Required bot scopes present: $($requiredScopes -join ', ')"
            }
        }
    } catch {
        Write-Warn "Could not check bot scopes (non-fatal)."
    }
} else {
    Write-Warn "Skipping Slack API validation (-SkipValidation)."
}

# ============================================================================
# Step 4: Save credentials to .env.slack
# ============================================================================
Write-Step "Saving credentials to $EnvFile..."

$envContent = @(
    "# AitherSlack configuration",
    "# Generated by 7012_Setup-Slack.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "# DO NOT commit this file to source control.",
    "",
    "SLACK_BOT_TOKEN=$SlackBotToken",
    "SLACK_APP_TOKEN=$SlackAppToken",
    "SLACK_SIGNING_SECRET=$SlackSigningSecret"
) -join "`n"

Set-Content -Path $EnvFile -Value $envContent -NoNewline
Write-OK "Saved to $EnvFile"

# Verify .gitignore includes .env.slack
$gitignorePath = Join-Path $WorkspaceRoot '.gitignore'
if (Test-Path $gitignorePath) {
    $gitignoreContent = Get-Content $gitignorePath -Raw
    if ($gitignoreContent -notmatch '\.env\.slack') {
        Add-Content -Path $gitignorePath -Value "`n.env.slack"
        Write-OK "Added .env.slack to .gitignore"
    }
} else {
    Write-Warn ".gitignore not found -- ensure .env.slack is not committed."
}

# ============================================================================
# Step 5: Store credentials in AitherSecrets
# ============================================================================
Write-Step "Storing credentials in AitherSecrets..."

$secrets = @{
    'SLACK_BOT_TOKEN'      = $SlackBotToken
    'SLACK_APP_TOKEN'      = $SlackAppToken
    'SLACK_SIGNING_SECRET' = $SlackSigningSecret
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
            Invoke-RestMethod -Uri "$SecretsUrl/secrets?service=AitherSlack" -Method Post `
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
    Write-Step "Starting AitherSlack Docker service..."

    try {
        $composeFile = Join-Path $WorkspaceRoot 'docker-compose.aitheros.yml'
        if (-not (Test-Path $composeFile)) {
            Write-Err "docker-compose.aitheros.yml not found at $composeFile"
            exit 1
        }

        # Pass env file to compose
        Push-Location $WorkspaceRoot
        docker compose -f docker-compose.aitheros.yml --profile communication up -d aither-slack 2>&1 |
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
    Write-Step "Waiting for AitherSlack health (port $ServicePort)..."

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
        Write-OK "AitherSlack is healthy on port $ServicePort."
    } else {
        Write-Err "AitherSlack did not become healthy after $HealthCheckAttempts attempts."
        Write-Host "    Check logs: docker logs -f aitheros-slack" -ForegroundColor Yellow
    }
} else {
    Write-Warn "Skipping Docker service start (-SkipDocker). Credentials stored only."
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  AitherSlack setup complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Service Port:      $ServicePort" -ForegroundColor White
Write-Host "  Env File:          $EnvFile" -ForegroundColor White
Write-Host "  Secrets:           AitherSecrets (port 8111)" -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Go to https://api.slack.com/apps and select your app" -ForegroundColor White
Write-Host "    2. Under 'Slash Commands', add:" -ForegroundColor White
Write-Host "         /aither  -> http://<your-domain>:$ServicePort/slack/commands" -ForegroundColor Gray
Write-Host "         /ask     -> http://<your-domain>:$ServicePort/slack/commands" -ForegroundColor Gray
Write-Host "    3. Under 'Event Subscriptions', set Request URL:" -ForegroundColor White
Write-Host "         http://<your-domain>:$ServicePort/slack/events" -ForegroundColor Gray
Write-Host "    4. Under 'Interactivity', set Request URL:" -ForegroundColor White
Write-Host "         http://<your-domain>:$ServicePort/slack/interactive" -ForegroundColor Gray
Write-Host "    5. Invite the bot to channels: /invite @AitherBot" -ForegroundColor White
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor Yellow
Write-Host "    docker logs -f aitheros-slack     # Follow logs" -ForegroundColor Gray
Write-Host "    docker restart aitheros-slack      # Restart service" -ForegroundColor Gray
Write-Host ""
