#Requires -Version 7.0
<#
.SYNOPSIS
    Reconstructs the .env file for a restored AitherOS instance.

.DESCRIPTION
    Given the decrypted AITHER_MASTER_KEY, this script:
    1. Generates fresh random secrets for required fields (JWT, PG, Redis, etc.)
    2. Sets the master key from the backup
    3. Optionally decrypts the vault to recover API keys and integration secrets
    4. Writes a complete .env file ready for service startup

    The master key is preserved from backup so the restored vault.enc can be
    decrypted. All other secrets (JWT, Postgres password, etc.) are regenerated
    fresh — services will work because they read from the vault at runtime,
    not from .env directly.

.PARAMETER MasterKey
    The decrypted AITHER_MASTER_KEY (from 0911).

.PARAMETER TargetDir
    Directory to write .env to. Defaults to project root.

.PARAMETER VaultPath
    Path to vault.enc to attempt extracting integration secrets (optional).

.PARAMETER PythonPath
    Path to Python executable. Defaults to "python".

.PARAMETER Force
    Overwrite existing .env file without prompting.

.EXAMPLE
    .\0912_Reconstruct-Env.ps1 -MasterKey "abc123..." -TargetDir D:\AitherOS-Fresh
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MasterKey,

    [string]$TargetDir,
    [string]$VaultPath,
    [string]$PythonPath = "python",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ── Init ────────────────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

if (-not $TargetDir) {
    $TargetDir = if ($projectRoot) { $projectRoot } else { $PWD.Path }
}

$envFile = Join-Path $TargetDir ".env"

if ((Test-Path $envFile) -and -not $Force) {
    Write-Warning ".env already exists at $envFile"
    $response = Read-Host "Overwrite? (y/N)"
    if ($response -ne 'y') {
        Write-Host "Skipped .env reconstruction. Using existing file." -ForegroundColor Yellow
        return [PSCustomObject]@{ EnvFile = $envFile; Skipped = $true }
    }
}

# ── Helper: generate random hex ────────────────────────────────────────────
function New-RandomHex([int]$Bytes = 32) {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = [byte[]]::new($Bytes)
    $rng.GetBytes($buf)
    return ($buf | ForEach-Object { $_.ToString("x2") }) -join ''
}

# ── Generate required secrets ──────────────────────────────────────────────
Write-Host "[1/3] Generating required secrets..." -ForegroundColor Cyan

$secrets = @{
    AITHER_MASTER_KEY      = $MasterKey  # PRESERVED from backup — must match vault.enc
    JWT_SECRET_KEY         = New-RandomHex 32
    POSTGRES_PASSWORD      = New-RandomHex 32
    REDIS_PASSWORD         = New-RandomHex 16
    AITHER_INTERNAL_SECRET = New-RandomHex 32
    MOLTBOOK_JWT_SECRET    = New-RandomHex 32
}

# ── Try to extract integration secrets from vault ──────────────────────────
$vaultSecrets = @{}

if ($VaultPath -and (Test-Path $VaultPath)) {
    Write-Host "[2/3] Attempting vault decryption to recover integration secrets..." -ForegroundColor Cyan

    $pyScript = Join-Path ([System.IO.Path]::GetTempPath()) "aither_vault_extract_$(Get-Random).py"
    $pyCode = @'
import sys, json, base64
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

vault_path = sys.argv[1]
master_key = sys.argv[2]

with open(vault_path, "r", encoding="utf-8") as f:
    blob = f.read().strip()

# Try embedded-salt format first (salt_hex:ciphertext)
if ":" in blob:
    salt_hex, ciphertext = blob.split(":", 1)
    try:
        salt = bytes.fromhex(salt_hex)
    except ValueError:
        salt = None
        ciphertext = blob
else:
    salt = None
    ciphertext = blob

if salt is None:
    # Legacy: try .vault_salt file next to vault.enc
    import os
    salt_path = os.path.join(os.path.dirname(vault_path), ".vault_salt")
    if os.path.exists(salt_path):
        with open(salt_path, "rb") as f:
            salt = f.read()
    else:
        print(json.dumps({"error": "No salt found"}))
        sys.exit(1)

kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=600_000)
key = base64.urlsafe_b64encode(kdf.derive(master_key.encode("utf-8")))
fernet = Fernet(key)

try:
    vault_json = json.loads(fernet.decrypt(ciphertext.encode("utf-8")).decode("utf-8"))
except InvalidToken:
    print(json.dumps({"error": "Vault decryption failed"}))
    sys.exit(2)

# Extract env-mappable secrets (name → try to decrypt value)
extracted = {}
for key_name, entry in vault_json.get("secrets", {}).items():
    val = entry.get("value", "")
    # Values are double-encrypted; try to decrypt with same fernet
    try:
        decrypted = fernet.decrypt(val.encode("utf-8")).decode("utf-8")
        extracted[key_name] = decrypted
    except Exception:
        # Value might be plaintext or use a different key
        extracted[key_name] = val

print(json.dumps(extracted))
'@

    try {
        Set-Content -Path $pyScript -Value $pyCode -Encoding UTF8
        $vaultResult = & $PythonPath $pyScript $VaultPath $MasterKey 2>&1
        if ($LASTEXITCODE -eq 0) {
            $rawJson = ($vaultResult | Where-Object { $_ -is [string] }) -join ''
            $vaultSecrets = $rawJson | ConvertFrom-Json -AsHashtable
            if ($vaultSecrets.error) {
                Write-Warning "Vault extraction: $($vaultSecrets.error)"
                $vaultSecrets = @{}
            } else {
                Write-Host "  Recovered $($vaultSecrets.Count) secrets from vault." -ForegroundColor Green
            }
        } else {
            Write-Warning "Vault decryption failed (exit $LASTEXITCODE). Integration secrets will need manual re-entry."
        }
    } catch {
        Write-Warning "Vault extraction error: $_"
    } finally {
        if (Test-Path $pyScript) { Remove-Item $pyScript -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host "[2/3] No vault path provided. Integration secrets will need manual re-entry." -ForegroundColor Yellow
}

# ── Map vault secrets to .env keys ─────────────────────────────────────────
# AitherSecrets stores keys in various naming conventions; map to .env format
$envMapping = @{
    'github_token'           = 'GITHUB_TOKEN'
    'github_org_token'       = 'GITHUB_ORG_TOKEN'
    'openai_api_key'         = 'OPENAI_API_KEY'
    'anthropic_api_key'      = 'ANTHROPIC_API_KEY'
    'google_api_key'         = 'GEMINI_API_KEY'
    'gemini_api_key'         = 'GEMINI_API_KEY'
    'hf_token'               = 'HF_TOKEN'
    'cloudflare_tunnel_token'= 'CLOUDFLARE_TUNNEL_TOKEN'
    'vastai_api_key'         = 'VASTAI_API_KEY'
    'runpod_api_key'         = 'RUNPOD_API_KEY'
    'civitai_api_token'      = 'CIVITAI_API_TOKEN'
    'smtp_password'          = 'AITHER_SMTP_PASS'
    'smtp_user'              = 'AITHER_SMTP_USER'
    'discord_bot_token'      = 'DISCORD_BOT_TOKEN'
    'telegram_bot_token'     = 'TELEGRAM_BOT_TOKEN'
    'minio_access_key'       = 'MINIO_ACCESS_KEY'
    'minio_secret_key'       = 'MINIO_SECRET_KEY'
}

$integrationSecrets = @{}
foreach ($vaultKey in $vaultSecrets.Keys) {
    $envKey = $envMapping[$vaultKey.ToLower()]
    if ($envKey -and $vaultSecrets[$vaultKey]) {
        $integrationSecrets[$envKey] = $vaultSecrets[$vaultKey]
    }
}

# ── Write .env ─────────────────────────────────────────────────────────────
Write-Host "[3/3] Writing .env to $envFile" -ForegroundColor Cyan

$tz = try { (Get-TimeZone).Id } catch { "UTC" }

$envContent = @"
# ============================================================================
# AitherOS Environment — Reconstructed from backup $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# ============================================================================

# ── Required Secrets (preserved master key, fresh generated others) ──
AITHER_MASTER_KEY=$($secrets.AITHER_MASTER_KEY)
JWT_SECRET_KEY=$($secrets.JWT_SECRET_KEY)
POSTGRES_PASSWORD=$($secrets.POSTGRES_PASSWORD)
REDIS_PASSWORD=$($secrets.REDIS_PASSWORD)
AITHER_INTERNAL_SECRET=$($secrets.AITHER_INTERNAL_SECRET)
MOLTBOOK_JWT_SECRET=$($secrets.MOLTBOOK_JWT_SECRET)

# ── Deployment Context ──
AITHER_DOCKER_MODE=true
AITHER_ENVIRONMENT=development
AITHER_RING=dev
AITHER_RING_ID=0
AITHER_INFERENCE_MODE=hybrid
TZ=$tz

# ── ComfyUI ──
COMFYUI_PATH=$${env:COMFYUI_PATH:-./data/comfyui}

"@

# Add integration secrets recovered from vault
if ($integrationSecrets.Count -gt 0) {
    $envContent += "# ── Integration Secrets (recovered from vault) ──`n"
    foreach ($key in ($integrationSecrets.Keys | Sort-Object)) {
        $envContent += "$key=$($integrationSecrets[$key])`n"
    }
    $envContent += "`n"
}

# Add placeholders for common optional secrets not in vault
$envContent += @"
# ── Optional (uncomment and fill if needed) ──
# AITHER_MASTER_KEY_BACKUP_PASSPHRASE=
# AITHER_ADMIN_EMAIL=
# AITHER_SMTP_HOST=host.docker.internal
# AITHER_SMTP_PORT=1025
"@

Set-Content -Path $envFile -Value $envContent -Encoding UTF8

Write-Host ".env written with $($secrets.Count) required + $($integrationSecrets.Count) recovered secrets." -ForegroundColor Green

return [PSCustomObject]@{
    EnvFile            = $envFile
    Skipped            = $false
    RequiredSecrets    = $secrets.Count
    RecoveredSecrets   = $integrationSecrets.Count
}
