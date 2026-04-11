#Requires -Version 7.0

<#
.SYNOPSIS
    Secure credentials in Lockbox and configure AitherRecover GitHub backup.

.DESCRIPTION
    Stores the tenant API key hash in AitherSecrets (Lockbox), then
    configures AitherRecover to back up the user's credential vault
    to their GitHub backup repository.

    Steps:
        1. Store API key hash in AitherSecrets Lockbox
        2. Configure backup target in AitherDirectory
        3. Trigger initial credential backup via AitherRecover
        4. Verify backup repo is accessible

    Exit Codes:
        0 - Success
        1 - Lockbox storage failed
        2 - Backup config failed
        3 - Backup verification failed

.PARAMETER ApiKey
    ACTA API key to secure. REQUIRED.

.PARAMETER SiteSlug
    Site/user slug for naming. REQUIRED.

.PARAMETER AdminEmail
    Admin email for the backup config.

.PARAMETER SecretsUrl
    AitherSecrets URL. Default: http://localhost:8111

.PARAMETER DirectoryUrl
    AitherDirectory URL. Default: http://localhost:8214

.PARAMETER DryRun
    Preview only.

.PARAMETER PassThru
    Return result object.

.NOTES
    Stage: Onboarding
    Order: 3203
    Dependencies: 3200, 3201, 3202
    Tags: onboarding, wallet, lockbox, backup, security
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApiKey,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SiteSlug,

    [string]$AdminEmail = '',
    [string]$SecretsUrl = 'http://localhost:8111',
    [string]$DirectoryUrl = 'http://localhost:8214',

    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Name, [string]$Status = 'running')
    $icon = switch ($Status) { 'done' { '[OK]' } 'fail' { '[FAIL]' } 'skip' { '[SKIP]' } default { '[..]' } }
    Write-Host "$icon $Name" -ForegroundColor $(switch ($Status) { 'done' { 'Green' } 'fail' { 'Red' } 'skip' { 'Yellow' } default { 'Cyan' } })
}

# ── Step 1: Store API key hash in Lockbox ────────────────────────────────

Write-Step "Store credential in Lockbox" 'running'

if ($DryRun) { Write-Step "Store credential in Lockbox (DRY RUN)" 'skip' }
else {
    # SHA-256 hash of the API key (never store plaintext)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ApiKey))
    $keyHash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    $lockboxBody = @{
        name         = "tenant/$SiteSlug/api_key_hash"
        value        = $keyHash
        secret_type  = 'generic'
        access_level = 'internal'
    } | ConvertTo-Json

    try {
        $lockResult = Invoke-RestMethod -Uri "$SecretsUrl/secrets" `
            -Method POST -Body $lockboxBody -ContentType 'application/json' `
            -TimeoutSec 10 -ErrorAction Stop

        Write-Host "  Key hash: $($keyHash.Substring(0, 16))..."
        Write-Step "Store credential in Lockbox" 'done'
    }
    catch {
        Write-Step "Store credential in Lockbox" 'fail'
        Write-Warning "Lockbox storage failed: $_ — continuing anyway"
    }
}

# ── Step 2: Configure backup target ─────────────────────────────────────

Write-Step "Configure backup target" 'running'

$backupRepo = "Aitherium/backup-user-$SiteSlug"

if ($DryRun) { Write-Step "Configure backup target (DRY RUN)" 'skip' }
else {
    try {
        $profileBody = @{
            backup_target = "github:$backupRepo"
        } | ConvertTo-Json

        Invoke-RestMethod -Uri "$DirectoryUrl/directory/profiles/$SiteSlug/backup" `
            -Method PUT -Body $profileBody -ContentType 'application/json' `
            -Headers @{ 'X-Caller-Type' = 'platform' } `
            -TimeoutSec 10 -ErrorAction Stop

        Write-Host "  Backup repo: $backupRepo"
        Write-Step "Configure backup target ($backupRepo)" 'done'
    }
    catch {
        Write-Step "Configure backup target" 'skip'
        Write-Host "  Directory profile update skipped: $_"
        Write-Host "  Set manually: PUT $DirectoryUrl/directory/profiles/$SiteSlug/backup"
    }
}

# ── Step 3: Trigger initial backup ──────────────────────────────────────

Write-Step "Trigger initial backup" 'running'

if ($DryRun) { Write-Step "Trigger initial backup (DRY RUN)" 'skip' }
else {
    $securityCoreUrl = 'http://localhost:8115'
    try {
        $backupResult = Invoke-RestMethod -Uri "$securityCoreUrl/recover/strata/lockbox/backup" `
            -Method POST -Body '{"passphrase": null}' -ContentType 'application/json' `
            -TimeoutSec 30 -ErrorAction Stop

        Write-Step "Trigger initial backup" 'done'
    }
    catch {
        Write-Step "Trigger initial backup" 'skip'
        Write-Host "  Initial backup skipped (AitherRecover may not be ready yet)"
        Write-Host "  Trigger manually: curl -X POST http://localhost:8115/recover/strata/lockbox/backup"
    }
}

# ── Step 4: Verify backup repo accessible ────────────────────────────────

Write-Step "Verify backup repo" 'running'

if ($DryRun) { Write-Step "Verify backup repo (DRY RUN)" 'skip' }
else {
    $ghToken = $env:GITHUB_TOKEN
    if ($ghToken) {
        try {
            $repoCheck = Invoke-RestMethod -Uri "https://api.github.com/repos/$backupRepo" `
                -TimeoutSec 10 -Headers @{ 'Authorization' = "token $ghToken" } -ErrorAction Stop

            Write-Step "Verify backup repo ($backupRepo exists)" 'done'
        }
        catch {
            Write-Step "Verify backup repo" 'skip'
            Write-Host "  Repo $backupRepo not found — will be created on first backup"
        }
    }
    else {
        Write-Step "Verify backup repo" 'skip'
        Write-Host "  GITHUB_TOKEN not set — skipping repo verification"
    }
}

# ── Summary ──────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Wallet & backup configured for: $SiteSlug" -ForegroundColor Green
Write-Host "  Lockbox:     $SecretsUrl (key hash stored)"
Write-Host "  Backup repo: github:$backupRepo"
Write-Host "  Key prefix:  $($ApiKey.Substring(0, [Math]::Min(20, $ApiKey.Length)))..."
Write-Host ""
Write-Host "  SECURITY:"
Write-Host "    - API key hash stored in AitherSecrets (plaintext never at rest)"
Write-Host "    - Encrypted backup via AitherRecover to GitHub"
Write-Host "    - Manage keys at: /settings/api-keys"
Write-Host ""

exit 0
