#Requires -Version 7.0
<#
.SYNOPSIS
    Restores files from an AitherRecover manifest-based backup.

.DESCRIPTION
    Reads the backup manifest JSON, then copies each file from the backup data
    directory to its original location under the project root. Handles:
    - Regular files (direct copy)
    - Chunked files (reassembly from .chunk.NNN parts)
    - SHA256 verification (when manifest includes checksums)

    Skips secrets/ and postgres/ (handled by 0914 and 0916 respectively).

.PARAMETER ManifestPath
    Path to the backup manifest JSON file.

.PARAMETER BackupDataDir
    Path to the backup data directory containing the files.

.PARAMETER TargetDir
    Project root to restore into. Defaults to detected project root.

.PARAMETER Verify
    Verify SHA256 checksums after restore. Slower but ensures integrity.

.PARAMETER Force
    Overwrite existing files without prompting.

.EXAMPLE
    .\0915_Restore-Filesystem.ps1 -ManifestPath D:\backup\manifests\20260331.json -BackupDataDir D:\backup\data\20260331
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [string]$BackupDataDir,

    [string]$TargetDir,
    [switch]$Verify,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ── Init ────────────────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

if (-not $TargetDir) {
    $TargetDir = if ($projectRoot) { $projectRoot } else { $PWD.Path }
}

# ── Load manifest ─────────────────────────────────────────────────────────
Write-Host "[1/3] Loading manifest: $(Split-Path $ManifestPath -Leaf)" -ForegroundColor Cyan

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

$totalFiles = if ($manifest.total_files) { $manifest.total_files } else { 0 }
$totalSize = if ($manifest.total_size) { [math]::Round($manifest.total_size / 1GB, 2) } else { "?" }
Write-Host "  Backup: $($manifest.backup_id) | $totalFiles files | ${totalSize} GB" -ForegroundColor Gray

# ── Paths to skip (handled by other scripts) ──────────────────────────────
$skipPrefixes = @(
    "AitherOS/Library/Data/secrets"     # 0914_Restore-Secrets
    "AitherOS\Library\Data\secrets"
    "AitherOS/lib/security/data/rbac"   # 0914_Restore-Secrets
    "AitherOS\lib\security\data\rbac"
    "AitherOS/Library/Data/identity"    # 0914_Restore-Secrets
    "AitherOS\Library\Data\identity"
    "data/backups/postgres"             # 0916_Restore-Postgres
    "data\backups\postgres"
)

# ── Restore files ─────────────────────────────────────────────────────────
Write-Host "[2/3] Restoring files..." -ForegroundColor Cyan

$files = @()
if ($manifest.files -is [System.Collections.IDictionary] -or $manifest.files.PSObject) {
    # Manifest files is a dict keyed by relative path
    $files = $manifest.files.PSObject.Properties
} else {
    Write-Warning "Manifest has no files section or unexpected format."
}

$restored = 0
$skipped = 0
$errors = 0
$checksumFails = 0

$progressInterval = [math]::Max(1, [math]::Floor($files.Count / 20))

foreach ($entry in $files) {
    $fileInfo = $entry.Value
    $relPath = if ($fileInfo.relative_path) { $fileInfo.relative_path } else { $entry.Name }

    # Normalize path separators for comparison
    $relNorm = $relPath -replace '\\', '/'

    # Skip paths handled by other scripts
    $shouldSkip = $false
    foreach ($prefix in $skipPrefixes) {
        $prefixNorm = $prefix -replace '\\', '/'
        if ($relNorm.StartsWith($prefixNorm)) {
            $shouldSkip = $true
            break
        }
    }
    if ($shouldSkip) { $skipped++; continue }

    $dstPath = Join-Path $TargetDir $relPath

    # Skip existing files unless -Force
    if ((Test-Path $dstPath) -and -not $Force) {
        $skipped++
        continue
    }

    # Ensure parent directory exists
    $dstDir = Split-Path $dstPath -Parent
    if (-not (Test-Path $dstDir)) {
        New-Item -Path $dstDir -ItemType Directory -Force | Out-Null
    }

    try {
        if ($fileInfo.is_chunked -and $fileInfo.chunk_count -gt 0) {
            # Reassemble from chunks
            $chunksDir = Join-Path $BackupDataDir "chunks"
            $chunkBasePath = Join-Path $chunksDir (Split-Path $relPath -Parent)

            $tempFile = "$dstPath.restoring"
            $fs = [System.IO.File]::Create($tempFile)
            try {
                for ($i = 0; $i -lt $fileInfo.chunk_count; $i++) {
                    $chunkName = "$(Split-Path $relPath -Leaf).chunk.$($i.ToString('D3'))"
                    $chunkPath = Join-Path $chunkBasePath $chunkName
                    if (-not (Test-Path $chunkPath)) {
                        throw "Missing chunk: $chunkPath"
                    }
                    $chunkBytes = [System.IO.File]::ReadAllBytes($chunkPath)

                    # Verify chunk checksum if available
                    if ($Verify -and $fileInfo.chunks -and $fileInfo.chunks[$i].sha256) {
                        $sha = [System.Security.Cryptography.SHA256]::Create()
                        $hash = ($sha.ComputeHash($chunkBytes) | ForEach-Object { $_.ToString("x2") }) -join ''
                        if ($hash -ne $fileInfo.chunks[$i].sha256) {
                            Write-Warning "Chunk $i checksum mismatch for $relPath"
                            $checksumFails++
                        }
                    }

                    $fs.Write($chunkBytes, 0, $chunkBytes.Length)
                }
            } finally {
                $fs.Close()
            }
            Move-Item -Path $tempFile -Destination $dstPath -Force
            $restored++
        }
        else {
            # Regular file — find in backup data dir
            $srcPath = Join-Path $BackupDataDir $relPath
            if (-not (Test-Path $srcPath)) {
                # Try without OS-specific separator normalization
                $srcAlt = Join-Path $BackupDataDir ($relPath -replace '\\', '/')
                if (Test-Path $srcAlt) { $srcPath = $srcAlt }
                else {
                    $skipped++
                    continue
                }
            }
            Copy-Item -Path $srcPath -Destination $dstPath -Force
            $restored++
        }

        # Verify checksum if requested
        if ($Verify -and $fileInfo.sha256 -and (Test-Path $dstPath)) {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $bytes = [System.IO.File]::ReadAllBytes($dstPath)
            $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ''
            if ($hash -ne $fileInfo.sha256) {
                Write-Warning "Checksum mismatch: $relPath"
                $checksumFails++
            }
        }
    }
    catch {
        Write-Warning "Failed to restore $relPath : $_"
        $errors++
    }

    # Progress reporting
    if ($restored % $progressInterval -eq 0 -and $restored -gt 0) {
        Write-Host "  ... $restored files restored" -ForegroundColor Gray
    }
}

# ── Summary ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/3] Filesystem restore complete." -ForegroundColor Cyan
Write-Host "  Restored: $restored | Skipped: $skipped | Errors: $errors" -ForegroundColor $(if ($errors -gt 0) { 'Yellow' } else { 'Green' })

if ($checksumFails -gt 0) {
    Write-Warning "$checksumFails files failed SHA256 verification."
}

return [PSCustomObject]@{
    Restored       = $restored
    Skipped        = $skipped
    Errors         = $errors
    ChecksumFails  = $checksumFails
    Ok             = ($errors -eq 0)
}
