#Requires -Version 7.0
<#
.SYNOPSIS
    Master restore orchestrator — recovers AitherOS from backup on new or wiped hardware.

.DESCRIPTION
    Runs the 09-restore playbook scripts in sequence to perform a full cold-metal
    restore of AitherOS from an AitherRecover backup. Each phase is a standalone
    script that can be re-run independently if a step fails.

    Playbook phases:
      0910  Validate backup source, select manifest
      0911  Decrypt master_key.enc
      0912  Reconstruct .env from vault + generate fresh secrets
      0913  Create directory structure + external Docker volumes
      0914  Restore secrets, certs, signing keys, identity
      0915  Restore filesystem data from manifest
      0916  Restore PostgreSQL from SQL dump
      0917  Restore Docker named volumes from .tgz snapshots
      0918  Post-restore validation checks

    After this completes, run:
      .\0000_Bootstrap-AitherOS.ps1 -SkipCleanup [-SkipBuild]

.PARAMETER BackupPath
    Path to a local backup directory. Defaults to data/backups in the project root.

.PARAMETER GitHubRepo
    GitHub backup repo URL (alternative to -BackupPath).

.PARAMETER BackupId
    Specific backup ID. If omitted, newest available is used.

.PARAMETER Passphrase
    Passphrase for master_key.enc decryption. Prompted if omitted.

.PARAMETER Profile
    Service profile for bootstrap after restore. Default: "core".

.PARAMETER SkipPostgres
    Skip Postgres restore (e.g., fresh instance, no DB needed).

.PARAMETER SkipVolumes
    Skip Docker volume restore.

.PARAMETER SkipBootstrap
    Don't auto-run bootstrap after restore. Just restore data and validate.

.PARAMETER NonInteractive
    Auto-select newest backup, skip confirmations.

.PARAMETER Force
    Overwrite existing files/volumes.

.EXAMPLE
    # Restore from local backup (interactive)
    .\0009_Restore-FromBackup.ps1 -BackupPath D:\AitherOS-Backup

    # Restore from GitHub backup repo (non-interactive)
    .\0009_Restore-FromBackup.ps1 -GitHubRepo https://github.com/Aitherium/AitherBackup -NonInteractive

    # Restore specific backup, skip bootstrap
    .\0009_Restore-FromBackup.ps1 -BackupPath D:\backup -BackupId 20260331_100425 -SkipBootstrap
#>

[CmdletBinding()]
param(
    [string]$BackupPath,
    [string]$GitHubRepo,
    [string]$BackupId,
    [string]$Passphrase,

    [ValidateSet("minimal", "core", "full")]
    [string]$Profile = "core",

    [switch]$SkipPostgres,
    [switch]$SkipVolumes,
    [switch]$SkipBootstrap,
    [switch]$NonInteractive,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ── Init ────────────────────────────────────────────────────────────────────
$scriptDir = $PSScriptRoot
$restoreDir = Join-Path (Split-Path $scriptDir -Parent) "09-restore"
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent

$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

if ($projectRoot) { $workspaceRoot = $projectRoot }

# ── Banner ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  AitherOS Restore from Backup" -ForegroundColor Cyan
Write-Host "  Target: $workspaceRoot" -ForegroundColor Gray
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$startTime = Get-Date
$phaseResults = @{}

function Invoke-Phase {
    param(
        [string]$Number,
        [string]$Name,
        [string]$Script,
        [hashtable]$Params,
        [switch]$Optional
    )

    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  Phase $Number: $Name" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""

    $scriptPath = Join-Path $restoreDir $Script
    if (-not (Test-Path $scriptPath)) {
        Write-Error "Phase script not found: $scriptPath"
        if (-not $Optional) { exit 1 }
        return $null
    }

    $phaseStart = Get-Date
    try {
        $result = & $scriptPath @Params
        $duration = (Get-Date) - $phaseStart
        Write-Host ""
        Write-Host "  Phase $Number completed in $([math]::Round($duration.TotalSeconds, 1))s" -ForegroundColor Green
        $script:phaseResults[$Number] = @{ Status = 'OK'; Duration = $duration; Result = $result }
        return $result
    }
    catch {
        $duration = (Get-Date) - $phaseStart
        Write-Host ""
        Write-Host "  Phase $Number FAILED after $([math]::Round($duration.TotalSeconds, 1))s: $_" -ForegroundColor Red
        $script:phaseResults[$Number] = @{ Status = 'FAIL'; Duration = $duration; Error = $_.ToString() }

        if ($Optional) {
            Write-Host "  (Optional phase — continuing)" -ForegroundColor Yellow
            return $null
        }
        else {
            Write-Host ""
            Write-Host "Restore aborted. Fix the issue and re-run, or run individual scripts:" -ForegroundColor Red
            Write-Host "  $scriptPath" -ForegroundColor Gray
            exit 1
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: Validate backup source
# ═══════════════════════════════════════════════════════════════════════════
$validateParams = @{}
if ($BackupPath) { $validateParams.BackupPath = $BackupPath }
if ($GitHubRepo) { $validateParams.GitHubRepo = $GitHubRepo }
if ($BackupId) { $validateParams.BackupId = $BackupId }
if ($NonInteractive) { $validateParams.NonInteractive = $true }

$backup = Invoke-Phase -Number "0910" -Name "Validate Backup Source" `
    -Script "0910_Validate-BackupSource.ps1" -Params $validateParams

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: Decrypt master key
# ═══════════════════════════════════════════════════════════════════════════
if ($backup.HasMasterKey) {
    $decryptParams = @{ MasterKeyPath = $backup.MasterKeyPath }
    if ($Passphrase) { $decryptParams.Passphrase = $Passphrase }

    $keyResult = Invoke-Phase -Number "0911" -Name "Decrypt Master Key" `
        -Script "0911_Decrypt-MasterKey.ps1" -Params $decryptParams

    $masterKey = $keyResult.MasterKey
}
else {
    Write-Warning "No master_key.enc in backup. You must provide AITHER_MASTER_KEY manually."
    if ($env:AITHER_MASTER_KEY) {
        $masterKey = $env:AITHER_MASTER_KEY
        Write-Host "Using AITHER_MASTER_KEY from environment." -ForegroundColor Yellow
    } else {
        $masterKey = Read-Host "Enter AITHER_MASTER_KEY"
    }
    if ([string]::IsNullOrWhiteSpace($masterKey)) {
        Write-Error "Cannot proceed without master key."
        exit 1
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3: Reconstruct .env
# ═══════════════════════════════════════════════════════════════════════════
$envParams = @{
    MasterKey = $masterKey
    TargetDir = $workspaceRoot
}
if ($backup.VaultPath) { $envParams.VaultPath = $backup.VaultPath }
if ($Force) { $envParams.Force = $true }

Invoke-Phase -Number "0912" -Name "Reconstruct Environment" `
    -Script "0912_Reconstruct-Env.ps1" -Params $envParams

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4: Prepare directories
# ═══════════════════════════════════════════════════════════════════════════
$dirParams = @{ TargetDir = $workspaceRoot }

Invoke-Phase -Number "0913" -Name "Prepare Directories" `
    -Script "0913_Prepare-Directories.ps1" -Params $dirParams

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5: Restore secrets
# ═══════════════════════════════════════════════════════════════════════════
if ($backup.HasDataDir) {
    $secretsParams = @{
        BackupDataDir = $backup.BackupDataDir
        TargetDir     = $workspaceRoot
    }
    if ($Force) { $secretsParams.Force = $true }

    Invoke-Phase -Number "0914" -Name "Restore Secrets" `
        -Script "0914_Restore-Secrets.ps1" -Params $secretsParams
}
else {
    Write-Warning "No backup data directory — skipping secrets restore."
    Write-Warning "Vault and signing keys will need manual restoration."
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 6: Restore filesystem
# ═══════════════════════════════════════════════════════════════════════════
if ($backup.HasDataDir -and $backup.ManifestPath) {
    $fsParams = @{
        ManifestPath  = $backup.ManifestPath
        BackupDataDir = $backup.BackupDataDir
        TargetDir     = $workspaceRoot
        Verify        = $true
    }
    if ($Force) { $fsParams.Force = $true }

    Invoke-Phase -Number "0915" -Name "Restore Filesystem" `
        -Script "0915_Restore-Filesystem.ps1" -Params $fsParams
}
else {
    Write-Warning "No backup data — skipping filesystem restore."
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 7: Restore PostgreSQL
# ═══════════════════════════════════════════════════════════════════════════
if (-not $SkipPostgres -and $backup.HasPgDump) {
    $pgParams = @{
        DumpPath    = $backup.PostgresDumpPath
        TargetDir   = $workspaceRoot
        KeepRunning = $true  # Keep running for validation
    }

    Invoke-Phase -Number "0916" -Name "Restore PostgreSQL" `
        -Script "0916_Restore-Postgres.ps1" -Params $pgParams -Optional
}
elseif ($SkipPostgres) {
    Write-Host "Skipping Postgres restore (-SkipPostgres)." -ForegroundColor Yellow
}
else {
    Write-Warning "No Postgres dump found in backup — skipping."
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 8: Restore Docker volumes
# ═══════════════════════════════════════════════════════════════════════════
if (-not $SkipVolumes -and $backup.HasVolumes) {
    $volParams = @{
        VolumeSnapshotDir = $backup.VolumeSnapshotDir
    }
    if ($Force) { $volParams.Force = $true }

    Invoke-Phase -Number "0917" -Name "Restore Docker Volumes" `
        -Script "0917_Restore-DockerVolumes.ps1" -Params $volParams -Optional
}
elseif ($SkipVolumes) {
    Write-Host "Skipping volume restore (-SkipVolumes)." -ForegroundColor Yellow
}
else {
    Write-Warning "No volume snapshots found in backup — skipping."
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 9: Post-restore validation
# ═══════════════════════════════════════════════════════════════════════════
$valParams = @{ TargetDir = $workspaceRoot }
if ($SkipPostgres) { $valParams.SkipPostgres = $true }

$validation = Invoke-Phase -Number "0918" -Name "Post-Restore Validation" `
    -Script "0918_Post-Restore-Validate.ps1" -Params $valParams

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
$totalDuration = (Get-Date) - $startTime

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Restore Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Duration:  $([math]::Round($totalDuration.TotalMinutes, 1)) minutes" -ForegroundColor Gray
Write-Host "  Backup:    $($backup.BackupId)" -ForegroundColor Gray
Write-Host ""

foreach ($num in ($phaseResults.Keys | Sort-Object)) {
    $p = $phaseResults[$num]
    $icon = if ($p.Status -eq 'OK') { 'OK  ' } else { 'FAIL' }
    $color = if ($p.Status -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host "  [$icon] Phase $num ($([math]::Round($p.Duration.TotalSeconds, 1))s)" -ForegroundColor $color
}

# ── Auto-bootstrap ──────────────────────────────────────────────────────
if (-not $SkipBootstrap -and $validation -and $validation.Ok) {
    Write-Host ""
    Write-Host "Data restore complete. Starting services..." -ForegroundColor Cyan
    Write-Host ""

    $bootstrapScript = Join-Path $scriptDir "0000_Bootstrap-AitherOS.ps1"
    if (Test-Path $bootstrapScript) {
        & $bootstrapScript -Profile $Profile -SkipCleanup -SkipBuild
    } else {
        Write-Warning "Bootstrap script not found at $bootstrapScript"
        Write-Host "Run manually: .\0000_Bootstrap-AitherOS.ps1 -SkipCleanup -SkipBuild -Profile $Profile" -ForegroundColor Yellow
    }
}
elseif (-not $SkipBootstrap -and $validation -and -not $validation.Ok) {
    Write-Host ""
    Write-Host "Validation has failures. Fix them, then run:" -ForegroundColor Red
    Write-Host "  .\0000_Bootstrap-AitherOS.ps1 -SkipCleanup -SkipBuild -Profile $Profile" -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "Next step — start services:" -ForegroundColor Cyan
    Write-Host "  .\0000_Bootstrap-AitherOS.ps1 -SkipCleanup -SkipBuild -Profile $Profile" -ForegroundColor Yellow
}
