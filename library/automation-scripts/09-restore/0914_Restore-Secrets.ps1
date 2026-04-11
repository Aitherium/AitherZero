#Requires -Version 7.0
<#
.SYNOPSIS
    Restores secrets, certificates, and identity files from a backup.

.DESCRIPTION
    Copies the critical security artifacts from backup to their expected locations.
    This MUST run before any AitherOS service starts, because:
    - Genesis needs the vault to decrypt service secrets
    - Services need Ed25519 signing keys for inter-service auth
    - The CA chain is needed for mTLS verification

    Restores:
    - vault.enc + .vault_salt (encrypted secrets vault)
    - keys/ (Ed25519 service signing keys)
    - ca/ (root CA, intermediate CA, issued certs, CRL)
    - vault_box/ (Lockbox storage)
    - identity files
    - RBAC data (users.json, roles.json, groups.json)
    - master_key.enc (backup copy)

.PARAMETER BackupDataDir
    Path to the backup data directory (e.g., data/backups/data/20260331_100425).

.PARAMETER TargetDir
    Project root directory. Defaults to detected project root.

.PARAMETER Force
    Overwrite existing files without prompting.

.EXAMPLE
    .\0914_Restore-Secrets.ps1 -BackupDataDir D:\backup\data\20260331_100425
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupDataDir,

    [string]$TargetDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ── Init ────────────────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

if (-not $TargetDir) {
    $TargetDir = if ($projectRoot) { $projectRoot } else { $PWD.Path }
}

if (-not (Test-Path $BackupDataDir)) {
    Write-Error "Backup data directory not found: $BackupDataDir"
    exit 1
}

$restored = 0
$skipped = 0
$missing = 0

function Restore-Path {
    param(
        [string]$RelativePath,
        [string]$Label,
        [switch]$Required
    )

    $src = Join-Path $BackupDataDir $RelativePath
    $dst = Join-Path $TargetDir $RelativePath

    if (-not (Test-Path $src)) {
        if ($Required) {
            Write-Host "  MISSING  $Label ($RelativePath)" -ForegroundColor Red
            script:missing++
        } else {
            Write-Host "  skip     $Label (not in backup)" -ForegroundColor Gray
            script:skipped++
        }
        return $false
    }

    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path $dstDir)) {
        New-Item -Path $dstDir -ItemType Directory -Force | Out-Null
    }

    $isDir = (Get-Item $src).PSIsContainer

    if ($isDir) {
        # Check if destination has files and we're not forcing
        if ((Test-Path $dst) -and -not $Force) {
            $existingFiles = Get-ChildItem -Path $dst -Recurse -File -ErrorAction SilentlyContinue
            if ($existingFiles.Count -gt 0) {
                Write-Host "  EXISTS   $Label ($($existingFiles.Count) files, use -Force to overwrite)" -ForegroundColor Yellow
                script:skipped++
                return $true
            }
        }
        # Copy directory recursively
        Copy-Item -Path "$src/*" -Destination $dst -Recurse -Force
        $count = (Get-ChildItem -Path $src -Recurse -File).Count
        Write-Host "  OK       $Label ($count files)" -ForegroundColor Green
    } else {
        if ((Test-Path $dst) -and -not $Force) {
            Write-Host "  EXISTS   $Label (use -Force to overwrite)" -ForegroundColor Yellow
            script:skipped++
            return $true
        }
        Copy-Item -Path $src -Destination $dst -Force
        Write-Host "  OK       $Label" -ForegroundColor Green
    }

    script:restored++
    return $true
}

# ── Restore secrets vault ─────────────────────────────────────────────────
Write-Host "[1/5] Restoring secrets vault..." -ForegroundColor Cyan

Restore-Path "AitherOS/Library/Data/secrets/vault.enc" "Encrypted vault" -Required
Restore-Path "AitherOS/Library/Data/secrets/.vault_salt" "Vault salt"
Restore-Path "AitherOS/Library/Data/secrets/audit.log" "Audit log"
Restore-Path "AitherOS/Library/Data/secrets/identities.json" "Service identities"

# ── Restore signing keys ─────────────────────────────────────────────────
Write-Host "[2/5] Restoring service signing keys..." -ForegroundColor Cyan

Restore-Path "AitherOS/Library/Data/secrets/keys" "Ed25519 signing keys" -Required

# ── Restore CA and certificates ───────────────────────────────────────────
Write-Host "[3/5] Restoring CA chain and certificates..." -ForegroundColor Cyan

Restore-Path "AitherOS/Library/Data/secrets/ca" "CA chain + issued certs"
Restore-Path "AitherOS/Library/Data/secrets/vault_box" "Lockbox storage"
Restore-Path "AitherOS/Library/Data/private-ca" "Private CA backup"

# ── Restore identity and RBAC ────────────────────────────────────────────
Write-Host "[4/5] Restoring identity and RBAC..." -ForegroundColor Cyan

Restore-Path "AitherOS/Library/Data/identity" "Agent identities"
Restore-Path "AitherOS/lib/security/data/rbac" "RBAC data (users/roles/groups)"

# ── Restore master key backup ────────────────────────────────────────────
Write-Host "[5/5] Restoring master key backup..." -ForegroundColor Cyan

Restore-Path "AitherOS/Library/Data/backups/master_key.enc" "Master key backup"

# ── User credential files ────────────────────────────────────────────────
Restore-Path "AitherOS/Library/Data/secrets/user_credentials" "User credentials"

# ── Summary ──────────────────────────────────────────────────────────────
Write-Host ""
if ($missing -gt 0) {
    Write-Host "Secrets restore completed with $missing MISSING required items." -ForegroundColor Red
    Write-Host "Services may fail to start. Check backup integrity." -ForegroundColor Red
} else {
    Write-Host "Secrets restore complete: $restored restored, $skipped skipped." -ForegroundColor Green
}

return [PSCustomObject]@{
    Restored = $restored
    Skipped  = $skipped
    Missing  = $missing
    Ok       = ($missing -eq 0)
}
