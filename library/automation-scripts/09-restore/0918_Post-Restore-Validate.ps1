#Requires -Version 7.0
<#
.SYNOPSIS
    Validates a restored AitherOS instance before full service startup.

.DESCRIPTION
    Runs post-restore integrity checks:
    1. Critical files exist (vault.enc, .env, signing keys, CA chain)
    2. Docker volumes are populated
    3. Vault can be decrypted with the master key in .env
    4. Postgres responds and has expected databases
    5. Directory structure is complete

    Returns a structured report. Intended to run AFTER 0914-0917 and BEFORE
    starting all services (0000_Bootstrap-AitherOS.ps1 -SkipCleanup -SkipBuild).

.PARAMETER TargetDir
    Project root directory. Defaults to detected project root.

.PARAMETER PythonPath
    Path to Python executable. Defaults to "python".

.PARAMETER SkipPostgres
    Skip Postgres connectivity check (if Postgres is not yet running).

.EXAMPLE
    .\0918_Post-Restore-Validate.ps1
    .\0918_Post-Restore-Validate.ps1 -TargetDir D:\AitherOS-Fresh -SkipPostgres
#>

[CmdletBinding()]
param(
    [string]$TargetDir,
    [string]$PythonPath = "python",
    [switch]$SkipPostgres
)

$ErrorActionPreference = 'Continue'  # Don't stop on first failure — collect all issues

# ── Init ────────────────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

if (-not $TargetDir) {
    $TargetDir = if ($projectRoot) { $projectRoot } else { $PWD.Path }
}

$checks = @()
$pass = 0
$fail = 0
$warn = 0

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail)

    $color = switch ($Status) {
        'PASS' { 'Green';  script:pass++ }
        'FAIL' { 'Red';    script:fail++ }
        'WARN' { 'Yellow'; script:warn++ }
    }

    $icon = switch ($Status) { 'PASS' { 'OK' } 'FAIL' { 'FAIL' } 'WARN' { 'WARN' } }
    Write-Host "  [$icon]  $Name $(if ($Detail) { "- $Detail" })" -ForegroundColor $color

    $script:checks += [PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    }
}

# ═══════════════════════════════════════════════════════════════════════════
Write-Host "Post-Restore Validation" -ForegroundColor Cyan
Write-Host "Target: $TargetDir" -ForegroundColor Gray
Write-Host ""

# ── 1. Critical files ────────────────────────────────────────────────────
Write-Host "[1/5] Critical files..." -ForegroundColor Cyan

$criticalFiles = @{
    ".env"                                          = "Environment configuration"
    "AitherOS/Library/Data/secrets/vault.enc"        = "Encrypted secrets vault"
    "AitherOS/config/services.yaml"                  = "Service registry"
    "docker-compose.aitheros.yml"                    = "Docker Compose file"
}

foreach ($rel in $criticalFiles.Keys) {
    $full = Join-Path $TargetDir $rel
    if (Test-Path $full) {
        $size = (Get-Item $full).Length
        Add-Check $criticalFiles[$rel] "PASS" "$rel (${size} bytes)"
    } else {
        Add-Check $criticalFiles[$rel] "FAIL" "$rel MISSING"
    }
}

# Check signing keys
$keysDir = Join-Path $TargetDir "AitherOS/Library/Data/secrets/keys"
if (Test-Path $keysDir) {
    $keyCount = (Get-ChildItem -Path $keysDir -Filter "*.key" -ErrorAction SilentlyContinue).Count
    if ($keyCount -gt 0) {
        Add-Check "Service signing keys" "PASS" "$keyCount keys in keys/"
    } else {
        Add-Check "Service signing keys" "WARN" "keys/ directory exists but empty"
    }
} else {
    Add-Check "Service signing keys" "WARN" "keys/ directory missing (services will generate fresh keys)"
}

# Check CA chain
$caDir = Join-Path $TargetDir "AitherOS/Library/Data/secrets/ca"
if (Test-Path $caDir) {
    $rootCrt = Test-Path (Join-Path $caDir "root.crt")
    $intCrt = Test-Path (Join-Path $caDir "intermediate.crt")
    if ($rootCrt -and $intCrt) {
        Add-Check "CA chain" "PASS" "root + intermediate CA present"
    } else {
        Add-Check "CA chain" "WARN" "Partial CA chain (root=$rootCrt, intermediate=$intCrt)"
    }
} else {
    Add-Check "CA chain" "WARN" "CA directory missing (AitherCert will create new CA)"
}

# ── 2. .env integrity ───────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/5] Environment configuration..." -ForegroundColor Cyan

$envFile = Join-Path $TargetDir ".env"
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile -Raw
    $requiredKeys = @(
        'AITHER_MASTER_KEY'
        'POSTGRES_PASSWORD'
        'REDIS_PASSWORD'
        'AITHER_INTERNAL_SECRET'
    )
    foreach ($key in $requiredKeys) {
        if ($envContent -match "^\s*$key\s*=\s*\S+") {
            Add-Check "$key" "PASS" "set in .env"
        } else {
            Add-Check "$key" "FAIL" "missing or empty in .env"
        }
    }
} else {
    Add-Check ".env file" "FAIL" "File does not exist"
}

# ── 3. Vault decryption test ────────────────────────────────────────────
Write-Host ""
Write-Host "[3/5] Vault decryption test..." -ForegroundColor Cyan

$vaultFile = Join-Path $TargetDir "AitherOS/Library/Data/secrets/vault.enc"
$masterKey = $null
if (Test-Path $envFile) {
    $envLines = Get-Content $envFile
    foreach ($line in $envLines) {
        if ($line -match '^\s*AITHER_MASTER_KEY\s*=\s*(.+)$') {
            $masterKey = $Matches[1].Trim('"', "'", ' ')
            break
        }
    }
}

if ($masterKey -and (Test-Path $vaultFile)) {
    $pyScript = Join-Path ([System.IO.Path]::GetTempPath()) "aither_vault_test_$(Get-Random).py"
    $pyCode = @'
import sys, json, base64
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

vault_path, master_key = sys.argv[1], sys.argv[2]
with open(vault_path, "r") as f:
    blob = f.read().strip()

if ":" in blob:
    salt_hex, ct = blob.split(":", 1)
    salt = bytes.fromhex(salt_hex)
else:
    import os
    sp = os.path.join(os.path.dirname(vault_path), ".vault_salt")
    with open(sp, "rb") as f: salt = f.read()
    ct = blob

kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=600_000)
key = base64.urlsafe_b64encode(kdf.derive(master_key.encode()))
try:
    vault = json.loads(Fernet(key).decrypt(ct.encode()).decode())
    count = len(vault.get("secrets", {}))
    print(f"OK:{count}")
except InvalidToken:
    print("FAIL:decrypt")
except Exception as e:
    print(f"FAIL:{e}")
'@
    try {
        Set-Content -Path $pyScript -Value $pyCode -Encoding UTF8
        $result = (& $PythonPath $pyScript $vaultFile $masterKey 2>&1) -join ''
        if ($result -match '^OK:(\d+)') {
            Add-Check "Vault decryption" "PASS" "$($Matches[1]) secrets accessible"
        } else {
            Add-Check "Vault decryption" "FAIL" "Cannot decrypt vault ($result)"
        }
    } catch {
        Add-Check "Vault decryption" "WARN" "Python test failed: $_"
    } finally {
        Remove-Item $pyScript -Force -ErrorAction SilentlyContinue
    }
} elseif (-not (Test-Path $vaultFile)) {
    Add-Check "Vault decryption" "FAIL" "vault.enc not found"
} else {
    Add-Check "Vault decryption" "WARN" "No master key to test with"
}

# ── 4. Docker volumes ──────────────────────────────────────────────────
Write-Host ""
Write-Host "[4/5] Docker volumes..." -ForegroundColor Cyan

$dockerOk = $false
try {
    docker info 2>&1 | Out-Null
    $dockerOk = ($LASTEXITCODE -eq 0)
} catch {}

if ($dockerOk) {
    $externalVols = @("aither-hf-cache", "aither-vllm-cache", "aither-optimized-models")
    foreach ($vol in $externalVols) {
        $exists = docker volume ls -q --filter "name=^${vol}$" 2>&1
        if ($exists -eq $vol) {
            Add-Check "Volume: $vol" "PASS" "exists"
        } else {
            Add-Check "Volume: $vol" "WARN" "missing (will be created on first use)"
        }
    }

    # Check important data volumes
    $dataVols = @("aither-redis", "aither-memory", "aither-strata-data")
    foreach ($vol in $dataVols) {
        $exists = docker volume ls -q --filter "name=^${vol}$" 2>&1
        if ($exists -eq $vol) {
            Add-Check "Volume: $vol" "PASS" "exists"
        } else {
            Add-Check "Volume: $vol" "WARN" "missing (docker compose will create)"
        }
    }
} else {
    Add-Check "Docker volumes" "WARN" "Docker not running — cannot verify volumes"
}

# ── 5. Postgres ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[5/5] PostgreSQL..." -ForegroundColor Cyan

if ($SkipPostgres) {
    Add-Check "PostgreSQL" "WARN" "skipped (-SkipPostgres)"
} elseif (-not $dockerOk) {
    Add-Check "PostgreSQL" "WARN" "Docker not running"
} else {
    $pgRunning = docker ps --filter "name=aitheros-postgres" --format "{{.Status}}" 2>&1
    if ($pgRunning -match 'Up') {
        $pgPassword = "aither_secret"
        if (Test-Path $envFile) {
            foreach ($line in (Get-Content $envFile)) {
                if ($line -match '^\s*POSTGRES_PASSWORD\s*=\s*(.+)$') {
                    $pgPassword = $Matches[1].Trim('"', "'", ' ')
                    break
                }
            }
        }
        $dbList = docker exec -e PGPASSWORD=$pgPassword aitheros-postgres `
            psql -U aither -d postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>&1
        $dbs = ($dbList | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $_ -notmatch 'ERROR' })
        if ($dbs.Count -gt 0) {
            Add-Check "PostgreSQL" "PASS" "Running, databases: $($dbs -join ', ')"
        } else {
            Add-Check "PostgreSQL" "WARN" "Running but no databases found"
        }
    } else {
        Add-Check "PostgreSQL" "WARN" "Container not running (expected — will start during boot)"
    }
}

# ── Summary ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
Write-Host "  PASS: $pass  |  WARN: $warn  |  FAIL: $fail" -ForegroundColor $(if ($fail -gt 0) { 'Red' } elseif ($warn -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray

if ($fail -gt 0) {
    Write-Host ""
    Write-Host "RESTORE INCOMPLETE. Fix FAIL items before starting services." -ForegroundColor Red
} elseif ($warn -gt 0) {
    Write-Host ""
    Write-Host "Restore looks good with minor warnings. Safe to proceed with bootstrap." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "All checks passed. Ready for service startup." -ForegroundColor Green
}

return [PSCustomObject]@{
    Pass   = $pass
    Warn   = $warn
    Fail   = $fail
    Checks = $checks
    Ok     = ($fail -eq 0)
}
