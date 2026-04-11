#Requires -Version 7.0
<#
.SYNOPSIS
    Decrypts master_key.enc to recover the AITHER_MASTER_KEY.

.DESCRIPTION
    The master key backup file uses Fernet encryption (AES-128-CBC + HMAC-SHA256)
    with PBKDF2-HMAC-SHA256 key derivation (600,000 iterations).

    Format: {salt_hex_32_chars}:{fernet_ciphertext}

    The passphrase is either AITHER_MASTER_KEY_BACKUP_PASSPHRASE (if set during
    backup) or the master key itself (self-encrypting fallback).

    Requires: pip install cryptography (in a Python environment)

.PARAMETER MasterKeyPath
    Path to master_key.enc file.

.PARAMETER Passphrase
    Decryption passphrase. If omitted, prompts interactively.

.PARAMETER PythonPath
    Path to Python executable. Defaults to "python".

.EXAMPLE
    .\0911_Decrypt-MasterKey.ps1 -MasterKeyPath D:\backup\master_key.enc
    .\0911_Decrypt-MasterKey.ps1 -MasterKeyPath D:\backup\master_key.enc -Passphrase "my-backup-passphrase"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MasterKeyPath,

    [string]$Passphrase,
    [string]$PythonPath = "python"
)

$ErrorActionPreference = 'Stop'

# ── Init ────────────────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

# ── Validate inputs ────────────────────────────────────────────────────────
if (-not (Test-Path $MasterKeyPath)) {
    Write-Error "Master key file not found: $MasterKeyPath"
    exit 1
}

# Check Python + cryptography available
try {
    $pyCheck = & $PythonPath -c "from cryptography.fernet import Fernet; print('ok')" 2>&1
    if ($pyCheck -ne 'ok') { throw "cryptography not available" }
} catch {
    Write-Error @"
Python with 'cryptography' package is required.
Install: $PythonPath -m pip install cryptography
"@
    exit 1
}

# ── Get passphrase ─────────────────────────────────────────────────────────
if (-not $Passphrase) {
    if ($env:AITHER_MASTER_KEY_BACKUP_PASSPHRASE) {
        $Passphrase = $env:AITHER_MASTER_KEY_BACKUP_PASSPHRASE
        Write-Host "Using passphrase from AITHER_MASTER_KEY_BACKUP_PASSPHRASE env var." -ForegroundColor Cyan
    }
    elseif ($env:AITHER_MASTER_KEY) {
        $Passphrase = $env:AITHER_MASTER_KEY
        Write-Host "Using AITHER_MASTER_KEY as passphrase (self-encrypting fallback)." -ForegroundColor Cyan
    }
    else {
        Write-Host "Enter the backup passphrase (AITHER_MASTER_KEY_BACKUP_PASSPHRASE or AITHER_MASTER_KEY):" -ForegroundColor Yellow
        $securePass = Read-Host -AsSecureString
        $Passphrase = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
        )
    }
}

if ([string]::IsNullOrWhiteSpace($Passphrase)) {
    Write-Error "Passphrase cannot be empty."
    exit 1
}

# ── Decrypt via Python ─────────────────────────────────────────────────────
Write-Host "Decrypting master key..." -ForegroundColor Cyan

# Write a temp Python script (avoids shell escaping issues with the passphrase)
$pyScript = Join-Path ([System.IO.Path]::GetTempPath()) "aither_decrypt_mk_$(Get-Random).py"

$pyCode = @'
import sys, base64
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

master_key_path = sys.argv[1]
passphrase = sys.argv[2]

with open(master_key_path, "r", encoding="utf-8") as f:
    blob = f.read().strip()

if ":" not in blob:
    print("ERROR:master_key.enc has no salt:ciphertext separator", file=sys.stderr)
    sys.exit(1)

salt_hex, ciphertext = blob.split(":", 1)

try:
    salt = bytes.fromhex(salt_hex)
except ValueError:
    print(f"ERROR:Invalid salt hex: {salt_hex[:20]}...", file=sys.stderr)
    sys.exit(1)

kdf = PBKDF2HMAC(
    algorithm=hashes.SHA256(),
    length=32,
    salt=salt,
    iterations=600_000,
)
key = base64.urlsafe_b64encode(kdf.derive(passphrase.encode("utf-8")))
fernet = Fernet(key)

try:
    master_key = fernet.decrypt(ciphertext.encode("utf-8")).decode("utf-8")
    print(master_key)
except InvalidToken:
    print("ERROR:Decryption failed. Wrong passphrase or corrupted file.", file=sys.stderr)
    sys.exit(2)
'@

try {
    Set-Content -Path $pyScript -Value $pyCode -Encoding UTF8

    $result = & $PythonPath $pyScript $MasterKeyPath $Passphrase 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 2) {
        Write-Error @"
Decryption failed. The passphrase is incorrect or the file is corrupted.

Try:
  1. Your AITHER_MASTER_KEY_BACKUP_PASSPHRASE (if you set one)
  2. Your AITHER_MASTER_KEY itself (self-encrypting fallback)
  3. Check that master_key.enc is not truncated
"@
        exit 2
    }
    elseif ($exitCode -ne 0) {
        Write-Error "Decryption failed: $result"
        exit 1
    }

    $masterKey = ($result | Where-Object { $_ -is [string] -and $_ -notmatch '^ERROR:' }) | Select-Object -Last 1

    if ([string]::IsNullOrWhiteSpace($masterKey)) {
        Write-Error "Decryption produced empty output."
        exit 1
    }

    # Validate: master key should be 64 hex chars (32 bytes)
    if ($masterKey -match '^[0-9a-fA-F]{64}$') {
        Write-Host "Master key decrypted successfully (64-char hex)." -ForegroundColor Green
    }
    elseif ($masterKey.Length -ge 16) {
        Write-Host "Master key decrypted (non-standard format, ${($masterKey.Length)} chars). Proceeding." -ForegroundColor Yellow
    }
    else {
        Write-Error "Decrypted value too short ($($masterKey.Length) chars). Likely wrong passphrase."
        exit 2
    }

    return [PSCustomObject]@{
        MasterKey = $masterKey
    }
}
finally {
    if (Test-Path $pyScript) { Remove-Item $pyScript -Force -ErrorAction SilentlyContinue }
}
