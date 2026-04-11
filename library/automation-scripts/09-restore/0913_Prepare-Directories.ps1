#Requires -Version 7.0
<#
.SYNOPSIS
    Creates all directories and Docker volumes required for AitherOS.

.DESCRIPTION
    Prepares the filesystem and Docker infrastructure for a restore:
    - Host data directories (D:\AitherOS-Data\volumes\*, data/*, AitherOS/Library/*)
    - External pinned Docker volumes (aither-hf-cache, aither-vllm-cache, aither-optimized-models)
    - Bind-mount target directories referenced by docker-compose.aitheros.yml

    Safe to run multiple times (idempotent). Never deletes anything.

.PARAMETER TargetDir
    Project root directory. Defaults to detected project root.

.PARAMETER SkipDockerVolumes
    Skip creating external Docker volumes (useful if Docker is not yet running).

.EXAMPLE
    .\0913_Prepare-Directories.ps1
    .\0913_Prepare-Directories.ps1 -TargetDir D:\AitherOS-Fresh
#>

[CmdletBinding()]
param(
    [string]$TargetDir,
    [switch]$SkipDockerVolumes
)

$ErrorActionPreference = 'Stop'

# ── Init ────────────────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

if (-not $TargetDir) {
    $TargetDir = if ($projectRoot) { $projectRoot } else { $PWD.Path }
}

$created = 0
function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        script:created++
        Write-Host "  + $Path" -ForegroundColor Green
    }
}

# ── Phase 1: D:\AitherOS-Data volume directories ──────────────────────────
Write-Host "[1/4] Creating D:\AitherOS-Data volume directories..." -ForegroundColor Cyan

$baseDir = "D:\AitherOS-Data\volumes"
$volumeDirs = @(
    "$baseDir\chronicle",  "$baseDir\secrets",
    "$baseDir\strata\hot", "$baseDir\strata\warm",  "$baseDir\strata\cold",
    "$baseDir\mind",       "$baseDir\workingmemory", "$baseDir\spirit",
    "$baseDir\veil\next",  "$baseDir\veil\node_modules",
    "$baseDir\ollama\models",
    "$baseDir\comfyui\models", "$baseDir\comfyui\output", "$baseDir\comfyui\custom_nodes",
    "$baseDir\training\data",  "$baseDir\training\checkpoints"
)

foreach ($dir in $volumeDirs) { Ensure-Dir $dir }

# ── Phase 2: Host bind-mount targets ──────────────────────────────────────
Write-Host "[2/4] Creating host bind-mount directories..." -ForegroundColor Cyan

$bindMountDirs = @(
    # Critical data paths
    "AitherOS/Library/Data/secrets"
    "AitherOS/Library/Data/identity"
    "AitherOS/Library/Data/private-ca"
    "AitherOS/Library/Data/skills"
    "AitherOS/Library/Data/apps"
    "AitherOS/Library/Data/backups"
    "AitherOS/Library/Data/codegraph"
    "AitherOS/Library/Data/ide-sessions"
    "AitherOS/Library/Training"
    "AitherOS/Library/Results"
    "AitherOS/Library/Logs"
    "AitherOS/Library/Traces"
    # Runtime data
    "AitherOS/data"
    "AitherOS/data/telegram"
    "AitherOS/data/discord"
    "AitherOS/data/slack"
    "AitherOS/data/whatsapp"
    # Host data directories
    "data/postgres"
    "data/backups"
    "data/backups/postgres"
    "data/backups/recover-runtime"
    "data/backups/manifests"
    "data/backups/secrets_rolling"
    "data/signing"
    "data/media"
    "data/uploads"
    "data/agents"
    "data/playground"
    "data/acta"
    "data/minio"
    "data/comfyui/models"
    "data/comfyui/output"
    "data/comfyui/input"
    # Logs
    "logs"
    # RBAC
    "AitherOS/lib/security/data/rbac"
    # Config personas
    "AitherOS/config/personas"
    # Training data
    "training-data"
)

foreach ($rel in $bindMountDirs) {
    Ensure-Dir (Join-Path $TargetDir $rel)
}

# ── Phase 3: External Docker volumes ──────────────────────────────────────
if ($SkipDockerVolumes) {
    Write-Host "[3/4] Skipping Docker volume creation (-SkipDockerVolumes)." -ForegroundColor Yellow
} else {
    Write-Host "[3/4] Creating external Docker volumes..." -ForegroundColor Cyan

    $externalVolumes = @("aither-hf-cache", "aither-vllm-cache", "aither-optimized-models")

    # Check Docker is running
    $dockerOk = $false
    try {
        docker info 2>&1 | Out-Null
        $dockerOk = ($LASTEXITCODE -eq 0)
    } catch {}

    if (-not $dockerOk) {
        Write-Warning "Docker is not running. Skipping volume creation. Run this step again after starting Docker."
    } else {
        foreach ($vol in $externalVolumes) {
            $exists = docker volume ls -q --filter "name=^${vol}$" 2>&1
            if ($exists -eq $vol) {
                Write-Host "  = $vol (already exists)" -ForegroundColor Gray
            } else {
                docker volume create --name $vol | Out-Null
                Write-Host "  + $vol" -ForegroundColor Green
                $created++
            }
        }
    }
}

# ── Phase 4: Verify critical paths ───────────────────────────────────────
Write-Host "[4/4] Verifying critical paths..." -ForegroundColor Cyan

$critical = @(
    "AitherOS/Library/Data/secrets"
    "AitherOS/Library/Data/identity"
    "data/postgres"
    "data/backups"
)

$allOk = $true
foreach ($rel in $critical) {
    $full = Join-Path $TargetDir $rel
    if (Test-Path $full) {
        Write-Host "  OK  $rel" -ForegroundColor Green
    } else {
        Write-Host "  MISSING  $rel" -ForegroundColor Red
        $allOk = $false
    }
}

Write-Host ""
Write-Host "Directory preparation complete. Created $created new items." -ForegroundColor Green

return [PSCustomObject]@{
    TargetDir  = $TargetDir
    Created    = $created
    AllOk      = $allOk
}
