#Requires -Version 7.0
<#
.SYNOPSIS
    Validates a backup source and selects a manifest for restore.

.DESCRIPTION
    Scans a local backup directory (or clones a GitHub backup repo) for valid
    AitherRecover manifests. Lists available backups sorted by date, lets the
    user pick one (or auto-selects newest), and validates the manifest integrity.

    Outputs a PSCustomObject with BackupId, ManifestPath, BackupDataDir,
    PostgresDumpPath, and VolumeSnapshotDir for downstream scripts.

.PARAMETER BackupPath
    Path to a local backup directory (e.g., D:\AitherOS-Backup or data/backups).

.PARAMETER GitHubRepo
    GitHub repo URL to clone as backup source (e.g., https://github.com/Aitherium/AitherBackup).
    Cloned to a temp directory; BackupPath is set to the clone root.

.PARAMETER BackupId
    Specific backup ID to restore (e.g., "20260331_100425"). If omitted, newest is used.

.PARAMETER NonInteractive
    Auto-select newest backup without prompting.

.EXAMPLE
    .\0910_Validate-BackupSource.ps1 -BackupPath D:\AitherOS-Backup
    .\0910_Validate-BackupSource.ps1 -GitHubRepo https://github.com/Aitherium/AitherBackup
#>

[CmdletBinding()]
param(
    [string]$BackupPath,
    [string]$GitHubRepo,
    [string]$BackupId,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

# ── Init ────────────────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

# ── Resolve backup source ──────────────────────────────────────────────────
if ($GitHubRepo -and -not $BackupPath) {
    Write-Host "[1/4] Cloning backup repo: $GitHubRepo" -ForegroundColor Cyan
    $cloneDir = Join-Path ([System.IO.Path]::GetTempPath()) "aither-restore-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    git clone --depth 1 $GitHubRepo $cloneDir
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to clone backup repo. Check URL and credentials."
        exit 1
    }
    $BackupPath = $cloneDir
    Write-Host "  Cloned to: $cloneDir" -ForegroundColor Green
}

if (-not $BackupPath) {
    # Default: repo-local backup dir
    if ($projectRoot) {
        $BackupPath = Join-Path $projectRoot "data/backups"
    } else {
        Write-Error "No -BackupPath or -GitHubRepo specified and cannot find project root."
        exit 1
    }
}

$BackupPath = (Resolve-Path $BackupPath -ErrorAction Stop).Path
Write-Host "[1/4] Backup source: $BackupPath" -ForegroundColor Cyan

# ── Locate manifests ───────────────────────────────────────────────────────
Write-Host "[2/4] Scanning for manifests..." -ForegroundColor Cyan

$manifestDir = Join-Path $BackupPath "manifests"
$manifests = @()

if (Test-Path $manifestDir) {
    $manifests = Get-ChildItem -Path $manifestDir -Filter "*.json" |
        Where-Object { $_.Name -notmatch '^(github|host)' } |  # Skip meta manifests
        Sort-Object Name -Descending
}

if ($manifests.Count -eq 0) {
    Write-Error "No backup manifests found in $manifestDir"
    exit 2
}

Write-Host "  Found $($manifests.Count) backup(s):" -ForegroundColor Green
foreach ($m in $manifests | Select-Object -First 10) {
    $json = Get-Content $m.FullName -Raw | ConvertFrom-Json
    $size = if ($json.total_size) { [math]::Round($json.total_size / 1GB, 2) } else { "?" }
    $files = if ($json.total_files) { $json.total_files } else { "?" }
    $date = if ($json.created_at) { $json.created_at } else { $m.BaseName }
    Write-Host "    $($m.BaseName)  |  $files files  |  ${size} GB  |  $date" -ForegroundColor Gray
}

# ── Select backup ──────────────────────────────────────────────────────────
Write-Host "[3/4] Selecting backup..." -ForegroundColor Cyan

$selectedManifest = $null

if ($BackupId) {
    $selectedManifest = $manifests | Where-Object { $_.BaseName -eq $BackupId } | Select-Object -First 1
    if (-not $selectedManifest) {
        Write-Error "Backup ID '$BackupId' not found in manifests."
        exit 3
    }
    Write-Host "  Selected (explicit): $($selectedManifest.BaseName)" -ForegroundColor Green
}
elseif ($NonInteractive -or $manifests.Count -eq 1) {
    $selectedManifest = $manifests[0]
    Write-Host "  Auto-selected newest: $($selectedManifest.BaseName)" -ForegroundColor Green
}
else {
    Write-Host ""
    for ($i = 0; $i -lt [Math]::Min($manifests.Count, 10); $i++) {
        Write-Host "  [$i] $($manifests[$i].BaseName)"
    }
    $choice = Read-Host "Select backup (0-$([Math]::Min($manifests.Count - 1, 9)), default 0)"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "0" }
    $selectedManifest = $manifests[[int]$choice]
    Write-Host "  Selected: $($selectedManifest.BaseName)" -ForegroundColor Green
}

# ── Validate manifest and locate data ──────────────────────────────────────
Write-Host "[4/4] Validating backup structure..." -ForegroundColor Cyan

$manifest = Get-Content $selectedManifest.FullName -Raw | ConvertFrom-Json
$backupId = $selectedManifest.BaseName
$backupDataDir = Join-Path $BackupPath "data/$backupId"

# Check for backup data directory
$hasDataDir = Test-Path $backupDataDir
if (-not $hasDataDir) {
    Write-Warning "Backup data directory not found: $backupDataDir"
    Write-Warning "File restore (0915) will be limited. Secrets and Postgres may still be available."
}

# Check for Postgres dump
$pgDumpDir = Join-Path $BackupPath "postgres"
$pgDumpFile = $null
if (Test-Path $pgDumpDir) {
    $latestDump = Join-Path $pgDumpDir "latest.sql"
    if (Test-Path $latestDump) {
        $pgDumpFile = $latestDump
    } else {
        # Find newest .sql file
        $pgDumpFile = Get-ChildItem -Path $pgDumpDir -Filter "*.sql" |
            Where-Object { $_.Name -notmatch '\.tmp$' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
}
$hasPgDump = [bool]$pgDumpFile
Write-Host "  Postgres dump: $(if ($hasPgDump) { $pgDumpFile } else { 'NOT FOUND' })" -ForegroundColor $(if ($hasPgDump) { 'Green' } else { 'Yellow' })

# Check for Docker volume snapshots
$volumeSnapshotDir = Join-Path $BackupPath "recover-runtime"
$volumeSnapshots = @()
if (Test-Path $volumeSnapshotDir) {
    # Find the newest runtime snapshot that has docker-volumes/
    $runtimeDirs = Get-ChildItem -Path $volumeSnapshotDir -Directory | Sort-Object Name -Descending
    foreach ($rd in $runtimeDirs) {
        $dvDir = Join-Path $rd.FullName "docker-volumes"
        if (Test-Path $dvDir) {
            $volumeSnapshotDir = $dvDir
            $volumeSnapshots = Get-ChildItem -Path $dvDir -Filter "*.tgz"
            break
        }
    }
}
$hasVolumes = $volumeSnapshots.Count -gt 0
Write-Host "  Volume snapshots: $(if ($hasVolumes) { "$($volumeSnapshots.Count) archives in $volumeSnapshotDir" } else { 'NOT FOUND' })" -ForegroundColor $(if ($hasVolumes) { 'Green' } else { 'Yellow' })

# Check for master_key.enc
$masterKeyPath = Join-Path $BackupPath "master_key.enc"
if (-not (Test-Path $masterKeyPath)) {
    # Check inside data dir
    $masterKeyPath = Join-Path $backupDataDir "AitherOS/Library/Data/backups/master_key.enc"
}
$hasMasterKey = Test-Path $masterKeyPath
Write-Host "  Master key backup: $(if ($hasMasterKey) { $masterKeyPath } else { 'NOT FOUND' })" -ForegroundColor $(if ($hasMasterKey) { 'Green' } else { 'Red' })

# Check for vault.enc
$vaultPath = $null
foreach ($candidate in @(
    (Join-Path $backupDataDir "AitherOS/Library/Data/secrets/vault.enc"),
    (Join-Path $BackupPath "data/$backupId/AitherOS/Library/Data/secrets/vault.enc")
)) {
    if (Test-Path $candidate) { $vaultPath = $candidate; break }
}
$hasVault = [bool]$vaultPath
Write-Host "  Vault backup: $(if ($hasVault) { 'FOUND' } else { 'NOT FOUND' })" -ForegroundColor $(if ($hasVault) { 'Green' } else { 'Red' })

# ── Output result object ───────────────────────────────────────────────────
$result = [PSCustomObject]@{
    BackupId         = $backupId
    BackupPath       = $BackupPath
    ManifestPath     = $selectedManifest.FullName
    Manifest         = $manifest
    BackupDataDir    = $backupDataDir
    PostgresDumpPath = $pgDumpFile
    VolumeSnapshotDir = if ($hasVolumes) { $volumeSnapshotDir } else { $null }
    VolumeSnapshots  = $volumeSnapshots
    MasterKeyPath    = if ($hasMasterKey) { $masterKeyPath } else { $null }
    VaultPath        = $vaultPath
    HasDataDir       = $hasDataDir
    HasPgDump        = $hasPgDump
    HasVolumes       = $hasVolumes
    HasMasterKey     = $hasMasterKey
    HasVault         = $hasVault
}

Write-Host ""
Write-Host "Backup validation complete. Ready for restore." -ForegroundColor Green
Write-Host ""

return $result
