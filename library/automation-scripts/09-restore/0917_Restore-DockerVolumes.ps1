#Requires -Version 7.0
<#
.SYNOPSIS
    Restores Docker named volumes from .tgz snapshot archives.

.DESCRIPTION
    AitherRecover snapshots named Docker volumes as .tgz archives using:
      docker run --rm -v vol:/source:ro -v dir:/backup alpine:3.20 tar -czf ...

    This script reverses that process: creates the volume if needed, then
    extracts the .tgz archive into it.

    Skips external pinned volumes (aither-hf-cache, aither-vllm-cache,
    aither-optimized-models) as these contain re-downloadable model data.

.PARAMETER VolumeSnapshotDir
    Directory containing .tgz volume archives.

.PARAMETER IncludeModelVolumes
    Also restore model cache volumes (aither-hf-cache, etc.). These are large
    and re-downloadable, so skipped by default.

.PARAMETER Force
    Overwrite volumes that already have data.

.EXAMPLE
    .\0917_Restore-DockerVolumes.ps1 -VolumeSnapshotDir D:\backup\recover-runtime\20260331\docker-volumes
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VolumeSnapshotDir,

    [switch]$IncludeModelVolumes,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ── Init ────────────────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

# ── Validate ──────────────────────────────────────────────────────────────
if (-not (Test-Path $VolumeSnapshotDir)) {
    Write-Error "Volume snapshot directory not found: $VolumeSnapshotDir"
    exit 1
}

# Check Docker is running
try {
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker not running" }
} catch {
    Write-Error "Docker is not running. Start Docker Desktop first."
    exit 1
}

# ── Discover archives ────────────────────────────────────────────────────
$archives = Get-ChildItem -Path $VolumeSnapshotDir -Filter "*.tgz" | Sort-Object Name

if ($archives.Count -eq 0) {
    Write-Warning "No .tgz archives found in $VolumeSnapshotDir"
    return [PSCustomObject]@{ Restored = 0; Skipped = 0; Errors = 0; Ok = $true }
}

Write-Host "Found $($archives.Count) volume archives to restore." -ForegroundColor Cyan

# Volumes to skip (large model caches, re-downloadable)
$modelVolumes = @(
    'aither-hf-cache',
    'aither-vllm-cache',
    'aither-optimized-models',
    'aither-models'       # Ollama models
)

# Volumes safe to skip entirely (deprecated or unused)
$deprecatedVolumes = @(
    'aither-leann-data'
)

$restored = 0
$skipped = 0
$errors = 0

foreach ($archive in $archives) {
    # Derive volume name from archive filename (reverse of safe_name encoding)
    $volumeName = $archive.BaseName -replace '_', '-'

    # Skip deprecated
    if ($volumeName -in $deprecatedVolumes) {
        Write-Host "  skip  $volumeName (deprecated)" -ForegroundColor Gray
        $skipped++
        continue
    }

    # Skip model volumes unless requested
    if ((-not $IncludeModelVolumes) -and ($volumeName -in $modelVolumes)) {
        Write-Host "  skip  $volumeName (model cache, use -IncludeModelVolumes)" -ForegroundColor Gray
        $skipped++
        continue
    }

    Write-Host "  Restoring $volumeName from $($archive.Name)..." -ForegroundColor Cyan

    # Check if volume has data already
    if (-not $Force) {
        $volExists = docker volume ls -q --filter "name=^${volumeName}$" 2>&1
        if ($volExists -eq $volumeName) {
            # Check if it has any content
            $fileCount = docker run --rm -v "${volumeName}:/check:ro" alpine:3.20 sh -c "find /check -type f 2>/dev/null | head -5 | wc -l" 2>&1
            if ([int]$fileCount -gt 0) {
                Write-Host "  skip  $volumeName (has data, use -Force to overwrite)" -ForegroundColor Yellow
                $skipped++
                continue
            }
        }
    }

    try {
        # Create volume if it doesn't exist
        $volExists = docker volume ls -q --filter "name=^${volumeName}$" 2>&1
        if ($volExists -ne $volumeName) {
            docker volume create --name $volumeName | Out-Null
        }

        # Convert Windows path to a format Docker can mount
        $archiveDir = $archive.DirectoryName
        $archiveName = $archive.Name

        # Extract archive into volume
        # Mount the archive directory as /backup (read-only) and the volume as /target
        docker run --rm `
            -v "${volumeName}:/target" `
            -v "${archiveDir}:/backup:ro" `
            alpine:3.20 `
            sh -c "cd /target && tar -xzf /backup/$archiveName" 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to extract $volumeName (exit code $LASTEXITCODE)"
            $errors++
            continue
        }

        # Verify something was extracted
        $verifyCount = docker run --rm -v "${volumeName}:/check:ro" alpine:3.20 sh -c "find /check -type f 2>/dev/null | head -5 | wc -l" 2>&1

        Write-Host "  OK    $volumeName ($verifyCount files verified)" -ForegroundColor Green
        $restored++
    }
    catch {
        Write-Warning "  Error restoring $volumeName : $_"
        $errors++
    }
}

# ── Summary ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Volume restore complete: $restored restored, $skipped skipped, $errors errors." -ForegroundColor $(if ($errors -gt 0) { 'Yellow' } else { 'Green' })

return [PSCustomObject]@{
    Restored = $restored
    Skipped  = $skipped
    Errors   = $errors
    Ok       = ($errors -eq 0)
}
