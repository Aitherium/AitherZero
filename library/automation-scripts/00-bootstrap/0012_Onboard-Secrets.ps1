#Requires -Version 7.0
<#
.SYNOPSIS
    Onboards all required secrets to the AitherSecrets vault.

.DESCRIPTION
    Ensures critical secrets are present in the AitherSecrets vault (port 8111).
    Reads from environment variables, .env files, config files, and interactive
    prompts as fallback. Designed to be idempotent — never overwrites existing
    secrets unless -Force is specified.

    Secret categories:
    - SMTP/Email (ProtonMail Bridge credentials)
    - GitHub tokens
    - Cloudflare tokens
    - Admin credentials

.PARAMETER SecretsUrl
    URL of the AitherSecrets service. Default: http://localhost:8111

.PARAMETER Force
    Overwrite existing secrets in the vault.

.PARAMETER NonInteractive
    Skip prompts — only use env vars and config files.

.PARAMETER SmtpOnly
    Only onboard SMTP/email secrets.

.EXAMPLE
    .\0012_Onboard-Secrets.ps1
    # Interactive mode — prompts for missing secrets

.EXAMPLE
    .\0012_Onboard-Secrets.ps1 -NonInteractive
    # Only reads from env vars and .env files

.EXAMPLE
    .\0012_Onboard-Secrets.ps1 -SmtpOnly -Force
    # Re-provision SMTP credentials even if they exist

.NOTES
    Category: bootstrap
    Dependencies: AitherSecrets service must be running
    Platform: Windows, Linux, macOS
    Exit Codes:
        0 - All secrets onboarded
        1 - Some secrets missing (non-interactive mode)
        2 - AitherSecrets unreachable
#>

[CmdletBinding()]
param(
    [string]$SecretsUrl = "http://localhost:8111",
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$SmtpOnly
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-ApiKey {
    # Priority: env var → default dev key
    $key = $env:AITHER_INTERNAL_SECRET
    if (-not $key) { $key = $env:AITHER_MASTER_KEY }
    if (-not $key) { $key = "dev-internal-secret-687579a3" }
    return $key
}

function Test-SecretsService {
    param([string]$Url)
    try {
        $r = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec 5 -ErrorAction Stop
        return $r.status -eq "healthy"
    }
    catch { return $false }
}

function Get-VaultSecret {
    param([string]$Url, [string]$Key, [string]$ApiKey)
    try {
        $r = Invoke-RestMethod -Uri "$Url/secrets/$Key" `
            -Headers @{ "X-API-Key" = $ApiKey } `
            -TimeoutSec 5 -ErrorAction Stop
        return $r.value
    }
    catch { return $null }
}

function Set-VaultSecret {
    param([string]$Url, [string]$Name, [string]$Value, [string]$ApiKey,
          [string]$Type = "generic", [string]$AccessLevel = "internal")
    $body = @{
        name         = $Name
        value        = $Value
        type         = $Type
        access_level = $AccessLevel
    } | ConvertTo-Json

    try {
        $r = Invoke-RestMethod -Uri "$Url/secrets" -Method POST `
            -Headers @{ "X-API-Key" = $ApiKey } `
            -Body $body -ContentType "application/json" `
            -TimeoutSec 10 -ErrorAction Stop
        return $r.success -eq $true
    }
    catch {
        Write-Warning "Failed to set secret '$Name': $_"
        return $false
    }
}

function Read-SecretFromUser {
    param([string]$Prompt, [switch]$AsSecure)
    if ($NonInteractive) { return $null }
    if ($AsSecure) {
        $secure = Read-Host -Prompt $Prompt -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    else {
        return Read-Host -Prompt $Prompt
    }
}

function Read-EnvFile {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
            $parts = $line -split '=', 2
            $key = $parts[0].Trim()
            $val = $parts[1].Trim().Trim('"').Trim("'")
            $result[$key] = $val
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Secret Definitions — the SINGLE SOURCE OF TRUTH for what needs onboarding
# ---------------------------------------------------------------------------
$SmtpSecrets = @(
    @{
        Name        = "AITHER_SMTP_HOST"
        Description = "SMTP server hostname (host.docker.internal for ProtonMail Bridge in Docker)"
        Default     = "host.docker.internal"
        EnvVar      = "AITHER_SMTP_HOST"
        Category    = "smtp"
    },
    @{
        Name        = "AITHER_SMTP_PORT"
        Description = "SMTP server port"
        Default     = "1025"
        EnvVar      = "AITHER_SMTP_PORT"
        Category    = "smtp"
    },
    @{
        Name        = "AITHER_SMTP_USER"
        Description = "SMTP username (email address)"
        EnvVar      = "AITHER_SMTP_USER"
        Prompt      = "SMTP Username (e.g. david@aitherium.com)"
        Category    = "smtp"
    },
    @{
        Name        = "AITHER_SMTP_PASS"
        Description = "SMTP password (ProtonMail Bridge password)"
        EnvVar      = "AITHER_SMTP_PASS"
        Prompt      = "SMTP Password (from ProtonMail Bridge)"
        Secure      = $true
        Category    = "smtp"
    },
    @{
        Name        = "AITHER_SMTP_FROM"
        Description = "Default sender email address"
        EnvVar      = "AITHER_SMTP_FROM"
        FallbackKey = "AITHER_SMTP_USER"
        Category    = "smtp"
    },
    @{
        Name        = "PROTON_BRIDGE_CREDS"
        Description = "ProtonMail Bridge credentials (user:pass format)"
        Computed    = $true  # derived from SMTP_USER:SMTP_PASS
        Category    = "smtp"
    },
    @{
        Name        = "AITHER_ADMIN_EMAIL"
        Description = "Admin email for notifications"
        Default     = "wzns@pm.me"
        EnvVar      = "AITHER_ADMIN_EMAIL"
        Category    = "smtp"
    },
    @{
        Name        = "AITHER_ROUTE_ALL_EMAILS"
        Description = "Route all agent emails to admin (true/false)"
        Default     = "true"
        EnvVar      = "AITHER_ROUTE_ALL_EMAILS"
        Category    = "smtp"
    }
)

$InfraSecrets = @(
    @{
        Name        = "GITHUB_TOKEN"
        Description = "GitHub personal access token"
        EnvVar      = "GITHUB_TOKEN"
        Prompt      = "GitHub Token (PAT)"
        Secure      = $true
        Type        = "api_key"
        Category    = "infra"
    },
    @{
        Name        = "GITHUB_WEBHOOK_SECRET"
        Description = "GitHub webhook secret"
        EnvVar      = "GITHUB_WEBHOOK_SECRET"
        Secure      = $true
        Category    = "infra"
    },
    @{
        Name        = "CLOUDFLARE_API_TOKEN"
        Description = "Cloudflare API token"
        EnvVar      = "CLOUDFLARE_API_TOKEN"
        Prompt      = "Cloudflare API Token"
        Secure      = $true
        Type        = "api_key"
        Category    = "infra"
    }
)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           AitherOS Secrets Onboarding                      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 1. Test vault connectivity
Write-Host "→ Checking AitherSecrets at $SecretsUrl..." -NoNewline
if (-not (Test-SecretsService $SecretsUrl)) {
    Write-Host " UNREACHABLE" -ForegroundColor Red
    Write-Host "  Start AitherSecrets first: docker compose -f docker-compose.aitheros.yml up -d aither-secrets" -ForegroundColor Yellow
    exit 2
}
Write-Host " OK" -ForegroundColor Green

$apiKey = Get-ApiKey

# 2. Load .env files for fallback values
$rootPath = Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot)))
$envFiles = @(
    (Join-Path $rootPath ".env"),
    (Join-Path $rootPath ".env.local"),
    (Join-Path $rootPath ".env.smtp"),
    (Join-Path $rootPath "AitherOS" ".env")
)
$envVars = @{}
foreach ($f in $envFiles) {
    $vars = Read-EnvFile $f
    foreach ($k in $vars.Keys) { $envVars[$k] = $vars[$k] }
}

# 3. Process secrets
$allSecrets = if ($SmtpOnly) { $SmtpSecrets } else { $SmtpSecrets + $InfraSecrets }
$total = $allSecrets.Count
$created = 0
$skipped = 0
$failed = 0
$resolvedValues = @{}  # track resolved values for computed secrets

Write-Host ""
Write-Host "Processing $total secrets..." -ForegroundColor White
Write-Host ""

foreach ($secret in $allSecrets) {
    $name = $secret.Name
    Write-Host "  [$name] " -NoNewline

    # Check if already exists in vault
    $existing = Get-VaultSecret -Url $SecretsUrl -Key $name -ApiKey $apiKey
    if ($existing -and -not $Force) {
        Write-Host "EXISTS (skip)" -ForegroundColor DarkGray
        $skipped++
        $resolvedValues[$name] = $existing
        continue
    }

    # Skip computed secrets (handle after all inputs are resolved)
    if ($secret.Computed) {
        Write-Host "COMPUTED (deferred)" -ForegroundColor DarkYellow
        continue
    }

    # Resolve value: env var → .env file → fallback key → default → prompt
    $value = $null

    # Try env var
    if ($secret.EnvVar) {
        $envVal = [System.Environment]::GetEnvironmentVariable($secret.EnvVar)
        if ($envVal) { $value = $envVal }
    }

    # Try .env file
    if (-not $value -and $secret.EnvVar -and $envVars[$secret.EnvVar]) {
        $value = $envVars[$secret.EnvVar]
    }

    # Try fallback key (e.g. SMTP_FROM falls back to SMTP_USER)
    if (-not $value -and $secret.FallbackKey) {
        $value = $resolvedValues[$secret.FallbackKey]
    }

    # Try default
    if (-not $value -and $secret.Default) {
        $value = $secret.Default
    }

    # Try interactive prompt
    if (-not $value -and $secret.Prompt -and -not $NonInteractive) {
        $promptText = "$($secret.Prompt) [$($secret.Description)]"
        $value = Read-SecretFromUser -Prompt $promptText -AsSecure:($secret.Secure -eq $true)
    }

    if (-not $value) {
        Write-Host "MISSING" -ForegroundColor Yellow
        $failed++
        continue
    }

    # Store in vault
    $type = if ($secret.Type) { $secret.Type } else { "generic" }
    $ok = Set-VaultSecret -Url $SecretsUrl -Name $name -Value $value -ApiKey $apiKey -Type $type
    if ($ok) {
        Write-Host "SET" -ForegroundColor Green
        $created++
        $resolvedValues[$name] = $value
    }
    else {
        Write-Host "FAILED" -ForegroundColor Red
        $failed++
    }
}

# Handle computed secrets
foreach ($secret in ($allSecrets | Where-Object { $_.Computed })) {
    $name = $secret.Name
    Write-Host "  [$name] " -NoNewline

    if ($name -eq "PROTON_BRIDGE_CREDS") {
        $user = $resolvedValues["AITHER_SMTP_USER"]
        $pass = $resolvedValues["AITHER_SMTP_PASS"]
        if ($user -and $pass) {
            $value = "${user}:${pass}"
            $existing = Get-VaultSecret -Url $SecretsUrl -Key $name -ApiKey $apiKey
            if ($existing -and -not $Force) {
                Write-Host "EXISTS (skip)" -ForegroundColor DarkGray
                $skipped++
            }
            else {
                $ok = Set-VaultSecret -Url $SecretsUrl -Name $name -Value $value -ApiKey $apiKey
                if ($ok) { Write-Host "COMPUTED+SET" -ForegroundColor Green; $created++ }
                else { Write-Host "FAILED" -ForegroundColor Red; $failed++ }
            }
        }
        else {
            Write-Host "SKIPPED (missing inputs)" -ForegroundColor Yellow
            $failed++
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Auto-configure CommunicationCore SMTP if secrets were provisioned
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "→ Configuring CommunicationCore SMTP..." -NoNewline

$smtpHost = $resolvedValues["AITHER_SMTP_HOST"]
$smtpUser = $resolvedValues["AITHER_SMTP_USER"]
$smtpPass = $resolvedValues["AITHER_SMTP_PASS"]
$smtpPort = $resolvedValues["AITHER_SMTP_PORT"]
$smtpFrom = $resolvedValues["AITHER_SMTP_FROM"]

if ($smtpHost -and $smtpUser -and $smtpPass) {
    try {
        $configBody = @{
            provider     = "custom"
            host         = $smtpHost
            port         = [int]($smtpPort ?? "1025")
            username     = $smtpUser
            password     = $smtpPass
            from_address = ($smtpFrom ?? $smtpUser)
            use_tls      = $true
        } | ConvertTo-Json

        $r = Invoke-RestMethod -Uri "http://localhost:8205/smtp/config" `
            -Method POST -Body $configBody -ContentType "application/json" `
            -TimeoutSec 10 -ErrorAction Stop
        Write-Host " OK ($($r.host):$($r.port))" -ForegroundColor Green
    }
    catch {
        Write-Host " SKIPPED (CommunicationCore not available)" -ForegroundColor Yellow
    }
}
else {
    Write-Host " SKIPPED (missing SMTP credentials)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Created: $created" -ForegroundColor $(if ($created -gt 0) { "Green" } else { "White" })
Write-Host "  Skipped: $skipped (already existed)" -ForegroundColor DarkGray
Write-Host "  Missing: $failed" -ForegroundColor $(if ($failed -gt 0) { "Yellow" } else { "White" })
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($failed -gt 0 -and $NonInteractive) {
    Write-Warning "$failed secrets could not be resolved. Run interactively or set env vars."
    exit 1
}

exit 0
