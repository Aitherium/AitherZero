#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: ComfyUI
# Description: Downloads AI Models (Flux, SDXL, IPAdapter) for ComfyUI
# Tags: ai, models, flux, sdxl, ipadapter

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$InstallPath,

    [Parameter()]
    [ValidateSet("All", "Flux", "SDXL", "IPAdapter", "ClipVision")]
    [string]$ModelSet = "All"
)

. "$PSScriptRoot/_init.ps1"

# Set default InstallPath if not provided
if ([string]::IsNullOrEmpty($InstallPath)) {
    if ($IsWindows) {
        # Auto-detect ComfyUI location
        $PossiblePaths = @("E:\ComfyUI", "D:\ComfyUI", "C:\ComfyUI", "$env:USERPROFILE\ComfyUI")
        foreach ($path in $PossiblePaths) {
            if (Test-Path $path) {
                $InstallPath = $path
                Write-Host "Auto-detected ComfyUI at: $InstallPath" -ForegroundColor Cyan
                break
            }
        }
        # Fallback
        if ([string]::IsNullOrEmpty($InstallPath)) {
            if (Test-Path "E:") {
                $InstallPath = "E:\ComfyUI"
            }
            elseif (Test-Path "D:") {
                $InstallPath = "D:\ComfyUI"
            }
            else {
                $InstallPath = "C:\ComfyUI"
            }
        }
    }
    else {
        $InstallPath = Join-Path $env:HOME "ComfyUI"
    }
}

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0731_Install-ComfyUI-Models'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    if (Test-Path $Destination) {
        Write-ScriptLog "File already exists: $Destination (Skipping)"
        return
    }

    Write-ScriptLog "Downloading $Url to $Destination..."

    # Create parent directory if needed
    $parent = Split-Path $Destination -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # Use aria2c if available (faster), else Invoke-WebRequest
    if (Get-Command aria2c -ErrorAction SilentlyContinue) {
        aria2c -x 16 -s 16 -o (Split-Path $Destination -Leaf) -d $parent $Url
    }
    else {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
}

Write-ScriptLog "Starting Model Downloads for ComfyUI at $InstallPath..."

if (-not (Test-Path $InstallPath)) {
    throw "ComfyUI not found at $InstallPath. Please run 0730_Install-ComfyUI.ps1 first."
}

$checkpointsDir = Join-Path $InstallPath "models/checkpoints"
$vaeDir = Join-Path $InstallPath "models/vae"
$clipDir = Join-Path $InstallPath "models/clip"
$loraDir = Join-Path $InstallPath "models/loras"
$ipadapterDir = Join-Path $InstallPath "models/ipadapter"
$clipVisionDir = Join-Path $InstallPath "models/clip_vision"

try {
    # --- IPADAPTER MODELS (Required for character consistency) ---
    if ($ModelSet -in @("All", "IPAdapter")) {
        Write-ScriptLog "Processing IPAdapter models (SDXL)..."
        
        # Create ipadapter directory
        if (-not (Test-Path $ipadapterDir)) {
            New-Item -ItemType Directory -Path $ipadapterDir -Force | Out-Null
        }

        # IPAdapter Plus for SDXL (high quality style transfer)
        Download-File -Url "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors" `
            -Destination (Join-Path $ipadapterDir "ip-adapter-plus_sdxl_vit-h.safetensors")

        # IPAdapter Plus Face for SDXL (portrait consistency)
        Download-File -Url "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus-face_sdxl_vit-h.safetensors" `
            -Destination (Join-Path $ipadapterDir "ip-adapter-plus-face_sdxl_vit-h.safetensors")
            
        # Base IPAdapter for SDXL
        Download-File -Url "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter_sdxl_vit-h.safetensors" `
            -Destination (Join-Path $ipadapterDir "ip-adapter_sdxl_vit-h.safetensors")
    }

    # --- CLIP VISION MODELS (Required for IPAdapter) ---
    if ($ModelSet -in @("All", "IPAdapter", "ClipVision")) {
        Write-ScriptLog "Processing CLIP Vision models..."
        
        # Create clip_vision directory
        if (-not (Test-Path $clipVisionDir)) {
            New-Item -ItemType Directory -Path $clipVisionDir -Force | Out-Null
        }

        # CLIP ViT-H (required for IPAdapter PLUS SDXL) - ~2.4GB
        Download-File -Url "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" `
            -Destination (Join-Path $clipVisionDir "CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors")
            
        # CLIP ViT-bigG (alternative for some SDXL workflows) - ~1.9GB
        Download-File -Url "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/image_encoder/model.safetensors" `
            -Destination (Join-Path $clipVisionDir "CLIP-ViT-bigG-14-laion2B-39B-b160k.safetensors")
    }

    # --- FLUX DEV ---
    if ($ModelSet -in @("All", "Flux")) {
        Write-ScriptLog "Processing Flux Dev models..."

        # Flux Dev FP8 (Checkpoint)
        Download-File -Url "https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors" `
            -Destination (Join-Path $checkpointsDir "flux1-dev-fp8.safetensors")

        # VAE
        Download-File -Url "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors" `
            -Destination (Join-Path $vaeDir "ae.safetensors")

        # CLIPs
        Download-File -Url "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors" `
            -Destination (Join-Path $clipDir "t5xxl_fp8_e4m3fn.safetensors")

        Download-File -Url "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" `
            -Destination (Join-Path $clipDir "clip_l.safetensors")
    }

    Write-ScriptLog "Model downloads completed."

}
catch {
    Write-ScriptLog "Download failed: $_" "Error"
    exit 1
}
