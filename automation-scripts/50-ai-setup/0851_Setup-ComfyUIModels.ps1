#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Downloads and provisions required ComfyUI models (checkpoints + LoRAs) for AitherCanvas.

.DESCRIPTION
    Ensures all required models are present in the ComfyUI models directory.
    Downloads missing models from CivitAI (using API token from env/secrets)
    or HuggingFace as fallback.

    Model categories:
    - Core checkpoints: Flux Dev, SDXL Lightning, waiIllustrious
    - Technical/diagram LoRAs: Schematic, Technical Manuals, Flat Illustration
    - Existing art/pose LoRAs are preserved (not re-downloaded)

    This script is idempotent — already-downloaded models are skipped.

.PARAMETER Force
    Re-download models even if they already exist.

.PARAMETER SkipCheckpoints
    Only download LoRAs, skip large checkpoint files.

.PARAMETER ComfyUIPath
    Override the ComfyUI data directory. Default: D:/ComfyUI or $env:COMFYUI_PATH.

.PARAMETER CanvasUrl
    URL of the AitherCanvas service for API-based downloads. Default: http://localhost:8108.

.EXAMPLE
    ./0851_Setup-ComfyUIModels.ps1
    Downloads all missing required models.

.EXAMPLE
    ./0851_Setup-ComfyUIModels.ps1 -SkipCheckpoints
    Only downloads missing LoRAs (faster, smaller).

.NOTES
    Author: AitherOS Team
    Part of AitherZero automation scripts (0800-0899: Ecosystem startup/validation)
    Requires: CivitAI API token in $env:CIVITAI_API_TOKEN or .env file
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipCheckpoints,
    [string]$ComfyUIPath = "",
    [string]$CanvasUrl = "http://localhost:8108"
)

# Initialize
. "$PSScriptRoot/../_init.ps1"

$ErrorActionPreference = 'Continue'

# ============================================================================
# CONFIGURATION
# ============================================================================

# Resolve ComfyUI path
if (-not $ComfyUIPath) {
    $ComfyUIPath = $env:COMFYUI_PATH
}
if (-not $ComfyUIPath) {
    # Try to detect from Docker inspect
    try {
        $mounts = docker inspect aitheros-comfyui --format "{{range .Mounts}}{{.Source}}|{{.Destination}}{{println}}{{end}}" 2>$null
        $modelMount = $mounts | Where-Object { $_ -match '\|/opt/ComfyUI/models$' }
        if ($modelMount) {
            $ComfyUIPath = ($modelMount -split '\|')[0] -replace '/models$', ''
        }
    } catch {}
}
if (-not $ComfyUIPath) {
    # Fallback defaults
    if (Test-Path "D:/ComfyUI") { $ComfyUIPath = "D:/ComfyUI" }
    elseif (Test-Path "$projectRoot/data/comfyui") { $ComfyUIPath = "$projectRoot/data/comfyui" }
    else { $ComfyUIPath = "D:/ComfyUI" }
}

$checkpointDir = Join-Path $ComfyUIPath "models/checkpoints"
$loraDir = Join-Path $ComfyUIPath "models/loras"
$controlnetDir = Join-Path $ComfyUIPath "models/controlnet"

# Ensure directories exist
@($checkpointDir, $loraDir, $controlnetDir) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-Host "📁 Created: $_" -ForegroundColor DarkGray
    }
}

# Get CivitAI token
$civitaiToken = $env:CIVITAI_API_TOKEN
if (-not $civitaiToken) {
    # Try loading from .env
    $envFile = Join-Path $projectRoot ".env"
    if (Test-Path $envFile) {
        $tokenLine = Get-Content $envFile | Where-Object { $_ -match '^CIVITAI_API_TOKEN=' }
        if ($tokenLine) {
            $civitaiToken = ($tokenLine -split '=', 2)[1].Trim()
        }
    }
}

if (-not $civitaiToken) {
    Write-Warning "No CIVITAI_API_TOKEN found. CivitAI downloads may fail (401)."
    Write-Warning "Set it in .env or: `$env:CIVITAI_API_TOKEN = 'your_key'"
}

# ============================================================================
# MODEL MANIFEST — Single source of truth for required models
# ============================================================================

$RequiredLoRAs = @(
    # Technical/Diagram LoRAs (Flux.1 Dev compatible)
    @{
        Name        = "schematic_v1_flux.safetensors"
        CivitAIId   = "1509120"
        Description = "Schematic gridlines + graphite shading (Flux Dev)"
        Category    = "technical"
        Priority    = "high"
    },
    @{
        Name        = "1980s_technical_manuals_flux.safetensors"
        CivitAIId   = "2319339"
        Description = "Retro technical manual aesthetic (Flux Dev)"
        Category    = "technical"
        Priority    = "high"
    },
    @{
        Name        = "flat_illustration_flux.safetensors"
        CivitAIId   = "936348"
        Description = "Clean flat-color 2D illustrations (Flux Dev)"
        Category    = "technical"
        Priority    = "medium"
    }
)

# NOTE: Checkpoints are large (6-16GB each) and typically pre-installed.
# This list is for validation, not routine download.
$RequiredCheckpoints = @(
    @{
        Name        = "flux1-dev-fp8.safetensors"
        Description = "Flux Dev FP8 — primary for technical/photorealistic (16GB)"
        Source      = "huggingface"  # Too large for CivitAI token download
        Priority    = "critical"
    },
    @{
        Name        = "sdxl_lightning_4step.safetensors"
        Description = "SDXL Lightning 4-step — fast preview (6.5GB)"
        Source      = "huggingface"
        Priority    = "high"
    },
    @{
        Name        = "waiIllustriousSDXL_v140.safetensors"
        Description = "waiIllustrious SDXL — default anime/illustration (6.5GB)"
        Source      = "civitai"
        Priority    = "high"
    }
)

# ============================================================================
# DOWNLOAD FUNCTIONS
# ============================================================================

function Download-FromCivitAI {
    param(
        [string]$ModelId,
        [string]$FileName,
        [string]$TargetDir,
        [string]$Token
    )
    
    $targetPath = Join-Path $TargetDir $FileName
    
    # Skip if exists and not forcing
    if ((Test-Path $targetPath) -and -not $Force) {
        $size = [math]::Round((Get-Item $targetPath).Length / 1MB, 1)
        if ($size -gt 1) {
            Write-Host "  ✅ Already exists: $FileName (${size}MB)" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  ⚠️ Broken file detected (${size}MB), re-downloading..." -ForegroundColor Yellow
            Remove-Item $targetPath -Force
        }
    }
    
    Write-Host "  ⬇️  Downloading $FileName from CivitAI #$ModelId..." -ForegroundColor Cyan
    
    # Try Canvas API first (if running)
    try {
        $body = @{ id = $ModelId; type = if ($TargetDir -match 'loras') { "lora" } else { "checkpoint" }; name = $FileName } | ConvertTo-Json
        $result = Invoke-RestMethod -Uri "$CanvasUrl/models/download" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 10
        
        if ($result.success) {
            $downloadId = $result.download_id
            Write-Host "    Canvas download started: $downloadId" -ForegroundColor DarkGray
            
            # Poll for completion
            $maxWait = 600  # 10 minutes
            $waited = 0
            while ($waited -lt $maxWait) {
                Start-Sleep 5
                $waited += 5
                try {
                    $status = Invoke-RestMethod -Uri "$CanvasUrl/models/download/$downloadId/status" -TimeoutSec 5
                    if ($status.status -eq "complete") {
                        $sizeMb = [math]::Round($status.downloaded_mb, 1)
                        Write-Host "    ✅ Downloaded: ${sizeMb}MB" -ForegroundColor Green
                        return $true
                    } elseif ($status.status -eq "error") {
                        Write-Host "    ❌ Canvas download error: $($status.error)" -ForegroundColor Red
                        break
                    } else {
                        $pct = $status.progress
                        if ($waited % 15 -eq 0) {
                            Write-Host "    ⏳ Progress: ${pct}%" -ForegroundColor DarkGray
                        }
                    }
                } catch {
                    # Status check failed, continue waiting
                }
            }
        }
    } catch {
        Write-Host "    Canvas API unavailable, falling back to direct download..." -ForegroundColor DarkGray
    }
    
    # Direct download fallback
    if ($Token) {
        try {
            # Get model info from CivitAI API
            $headers = @{ "Authorization" = "Bearer $Token"; "User-Agent" = "AitherZero/1.0" }
            $modelInfo = Invoke-RestMethod -Uri "https://civitai.com/api/v1/models/$ModelId" -Headers $headers -TimeoutSec 15
            
            $version = $modelInfo.modelVersions[0]
            $file = $version.files | Where-Object { $_.name -like "*.safetensors" } | Select-Object -First 1
            if (-not $file) { $file = $version.files[0] }
            
            $downloadUrl = "$($file.downloadUrl)?token=$Token"
            
            # Download directly
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "AitherZero/1.0")
            $wc.DownloadFile($downloadUrl, $targetPath)
            
            $size = [math]::Round((Get-Item $targetPath).Length / 1MB, 1)
            Write-Host "    ✅ Direct download complete: ${size}MB" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "    ❌ Direct download failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
    
    Write-Host "    ❌ No CivitAI token available for direct download" -ForegroundColor Red
    return $false
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ComfyUI Model Provisioning" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ComfyUI Path: $ComfyUIPath" -ForegroundColor DarkGray
Write-Host "  CivitAI Auth: $(if ($civitaiToken) { '✅ Token available' } else { '❌ No token' })" -ForegroundColor DarkGray
Write-Host ""

$totalDownloaded = 0
$totalSkipped = 0
$totalFailed = 0

# --- Checkpoints ---
if (-not $SkipCheckpoints) {
    Write-Host "📦 Checking Checkpoints..." -ForegroundColor White
    foreach ($cp in $RequiredCheckpoints) {
        $path = Join-Path $checkpointDir $cp.Name
        if ((Test-Path $path) -and -not $Force) {
            $size = [math]::Round((Get-Item $path).Length / 1MB, 1)
            if ($size -gt 100) {
                Write-Host "  ✅ $($cp.Name) (${size}MB) — $($cp.Description)" -ForegroundColor Green
                $totalSkipped++
                continue
            }
        }
        Write-Host "  ⚠️ Missing: $($cp.Name) — $($cp.Description)" -ForegroundColor Yellow
        Write-Host "    → Large checkpoint, must be downloaded manually or via HuggingFace" -ForegroundColor DarkGray
        $totalFailed++
    }
    Write-Host ""
}

# --- LoRAs ---
Write-Host "🎨 Provisioning LoRAs..." -ForegroundColor White
foreach ($lora in $RequiredLoRAs) {
    $success = Download-FromCivitAI -ModelId $lora.CivitAIId -FileName $lora.Name -TargetDir $loraDir -Token $civitaiToken
    if ($success) {
        $path = Join-Path $loraDir $lora.Name
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 1024) {
            $totalSkipped++  # Already existed or just downloaded
        } else {
            $totalDownloaded++
        }
    } else {
        $totalFailed++
    }
}

# --- Summary ---
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Results" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✅ Ready: $totalSkipped" -ForegroundColor Green
Write-Host "  ⬇️  Downloaded: $totalDownloaded" -ForegroundColor Cyan
if ($totalFailed -gt 0) {
    Write-Host "  ❌ Failed/Missing: $totalFailed" -ForegroundColor Red
}

# List all models now available
Write-Host ""
Write-Host "📋 Available Models:" -ForegroundColor White
Write-Host "  Checkpoints:" -ForegroundColor DarkGray
Get-ChildItem $checkpointDir -Filter "*.safetensors" -ErrorAction SilentlyContinue | ForEach-Object {
    $sz = [math]::Round($_.Length / 1GB, 1)
    Write-Host "    • $($_.Name) (${sz}GB)" -ForegroundColor DarkGray
}
Write-Host "  LoRAs:" -ForegroundColor DarkGray
Get-ChildItem $loraDir -Filter "*.safetensors" -ErrorAction SilentlyContinue | ForEach-Object {
    $sz = [math]::Round($_.Length / 1MB, 1)
    Write-Host "    • $($_.Name) (${sz}MB)" -ForegroundColor DarkGray
}

Write-Host ""

if ($totalFailed -gt 0) {
    exit 1
}
exit 0
