# PowerShell Script to Verify and Deploy HunyuanVideo Models to ComfyUI
# Usage: ./0551_Verify-HunyuanSetup.ps1
# Version: 2.0.0 - Now supports multiple LLaVA formats (safetensors + GGUF)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   HunyuanVideo Setup & Verification Tool v2.0" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$AitherData = "D:\AitherOS-Fresh\AitherOS\data\models"
$ComfyRoot = "D:\ComfyUI"
$ComfyModels = "$ComfyRoot\models"

# 1. Verify Directories
if (-not (Test-Path $ComfyRoot)) {
    Write-Error "ComfyUI not found at $ComfyRoot"
    exit 1
}

# 2. Check for LLaVA encoder (supports multiple formats now)
$LLavaFiles = Get-ChildItem "$AitherData\clip\llava*" -ErrorAction SilentlyContinue | 
    Where-Object { $_.Extension -in @('.safetensors', '.gguf') }

if ($LLavaFiles.Count -eq 0) {
    Write-Host "MISSING: LLaVA Text Encoder" -ForegroundColor Red
    Write-Host ""
    Write-Host "Run the automated setup script:" -ForegroundColor Yellow
    Write-Host "  .\AitherZero\library\automation-scripts\50-ai-setup\0550_Setup-HunyuanVideo.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "The Comfy-Org HunyuanVideo repackaged repo is NOW ACCESSIBLE!" -ForegroundColor Green
    Write-Host "No HuggingFace login or Llama 3 license acceptance required." -ForegroundColor Green
    Write-Host ""
    Write-Host "Or manual download:" -ForegroundColor Yellow  
    Write-Host "  URL: https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files/text_encoders/llava_llama3_fp16.safetensors" -ForegroundColor White
    Write-Host "  Save to: $AitherData\clip\llava_llama3_fp16.safetensors" -ForegroundColor White
    exit 1
}
$LLavaFile = $LLavaFiles[0]
Write-Host "Found LLaVA: $($LLavaFile.Name)" -ForegroundColor Green

# 3. Deploy Models to ComfyUI
Write-Host "Deploying models to ComfyUI..." -ForegroundColor Yellow

# Function to Copy if Newer/Missing
function Sync-File {
    param($Source, $DestPath)
    if (-not (Test-Path $Source)) { Write-Warning "Source missing: $Source"; return }
    if (-not (Test-Path $DestPath)) { New-Item -ItemType Directory -Path $DestPath -Force | Out-Null }
    
    $DestFile = Join-Path $DestPath (Split-Path $Source -Leaf)
    if (-not (Test-Path $DestFile)) {
        Write-Host "Copying $(Split-Path $Source -Leaf)..." -NoNewline
        Copy-Item $Source $DestPath
        Write-Host " Done." -ForegroundColor Green
    } else {
        Write-Host "Skipping $(Split-Path $Source -Leaf) (Already exists)" -ForegroundColor Gray
    }
}

# Main Model -> models/unet (for GGUF loader)
# Note: UnetLoaderGGUF scans models/unet and models/diffusion_models
Sync-File "$AitherData\hunyuan_models\hunyuan_video.gguf" "$ComfyModels\unet"

# CLIP Encoders -> models/clip
Sync-File "$AitherData\clip\clip_l.safetensors" "$ComfyModels\clip"
Sync-File $LLavaFile.FullName "$ComfyModels\clip"

# VAE -> models/vae
Sync-File "$AitherData\vae\hunyuan_video_vae.safetensors" "$ComfyModels\vae"

# 4. Update Generation Script with Correct Filename
$GenScript = "D:\AitherOS-Fresh\generate_hunyuan_gguf.py"
$Content = Get-Content $GenScript -Raw
if ($Content -match "llava_llama3_fp8.safetensors" -and $LLavaFile.Name -ne "llava_llama3_fp8.safetensors") {
    Write-Host "Updating generation script to use $($LLavaFile.Name)..."
    $Content = $Content -replace "llava_llama3_fp8.safetensors", $LLavaFile.Name
    Set-Content -Path $GenScript -Value $Content
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   SETUP COMPLETE! Ready to Generate." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Run: python D:\AitherOS-Fresh\generate_hunyuan_gguf.py"
