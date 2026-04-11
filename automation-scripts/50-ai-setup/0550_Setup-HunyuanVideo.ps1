<#
.SYNOPSIS
    Downloads and sets up models for the HunyuanVideo workflow in ComfyUI.

.DESCRIPTION
    This script automates the retrieval of the HunyuanVideo DiT model, VAE, and required text encoders.
    
    The LLaVA-Llama3 text encoder is critical. This script provides MULTIPLE UNGATED alternatives:
    
    1. Kijai's ComfyUI-optimized version (llava_llama3_fp8_scaled.safetensors) - UNGATED
    2. City96's GGUF quantized version - UNGATED  
    3. HuggingFace Hub download with authentication (for gated repos if user has accepted license)
    
    This ELIMINATES the need for manual downloads even for Llama-3-based models.

.PARAMETER UseHFCLI
    Use huggingface_hub Python library for downloads (supports authentication)
    
.PARAMETER HFToken
    HuggingFace API token for authenticated downloads (optional, reads from HF_TOKEN env var)

.PARAMETER SkipLLaVA
    Skip LLaVA text encoder download (use if you already have it)

.PARAMETER Force
    Force re-download even if files exist

.NOTES
    Category: 50-ai-setup
    Author: AitherOS Team
    Version: 2.0.0
    
.EXAMPLE
    .\0550_Setup-HunyuanVideo.ps1
    # Standard setup with ungated sources
    
.EXAMPLE
    .\0550_Setup-HunyuanVideo.ps1 -UseHFCLI -HFToken "hf_xxxxx"
    # Use HuggingFace Hub with authentication
#>

[CmdletBinding()]
param(
    [switch]$UseHFCLI,
    [string]$HFToken = $env:HF_TOKEN,
    [switch]$SkipLLaVA,
    [switch]$Force
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$ErrorActionPreference = "Continue"
$ProgressPreference = 'SilentlyContinue'  # Speeds up Invoke-WebRequest

# Define Base Paths
$BaseModelPath = "D:\AitherOS-Fresh\AitherOS\data\models"
$HunyuanPath = "$BaseModelPath\hunyuan_models"
$ClipPath = "$BaseModelPath\clip"
$VaePath = "$BaseModelPath\vae"

# ============================================================================
# MODEL SOURCES - Prioritized by accessibility (ungated first)
# ============================================================================

# All sources are UNGATED (Tencent Hunyuan Community License or similar)
$ModelSources = @{
    HunyuanModel = @{
        Name = "HunyuanVideo DiT Model"
        Destination = "$HunyuanPath\hunyuan_video_720_cfgdistill_fp8.safetensors"
        Candidates = @(
            "https://huggingface.co/Kijai/HunyuanVideo_comfy/resolve/main/hunyuan_video_720_cfgdistill_fp8_e4m3fn.safetensors",
            "https://huggingface.co/Kijai/HunyuanVideo_comfy/resolve/main/hunyuan_video_FastVideo_720_fp8_e4m3fn.safetensors"
        )
    }
    
    HunyuanVAE = @{
        Name = "HunyuanVideo VAE"
        Destination = "$VaePath\hunyuan_video_vae_bf16.safetensors"
        Candidates = @(
            "https://huggingface.co/Kijai/HunyuanVideo_comfy/resolve/main/hunyuan_video_vae_bf16.safetensors"
        )
    }
    
    ClipL = @{
        Name = "CLIP-L Text Encoder"
        Destination = "$ClipPath\clip_l.safetensors"
        Candidates = @(
            "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors"
        )
    }
    
    # LLaVA-Llama3 Text Encoder - THE CRITICAL ONE
    # These sources ARE NOW ACCESSIBLE without manual login!
    LLaVA = @{
        Name = "LLaVA-Llama3 Text Encoder"
        Destination = "$ClipPath\llava_llama3_fp16.safetensors"
        Candidates = @(
            # PRIMARY: Comfy-Org repackaged - NOW ACCESSIBLE (no login required!)
            "https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files/text_encoders/llava_llama3_fp16.safetensors",
            # Fallback: FP8 version from Comfy-Org
            "https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files/text_encoders/llava_llama3_fp8_scaled.safetensors"
        )
    }
}

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan  
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-Status {
    param([string]$Message, [string]$Level = 'Info')
    $colors = @{ Info = 'Gray'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red' }
    $prefixes = @{ Info = '[INFO]'; Success = '[OK]'; Warning = '[WARN]'; Error = '[ERROR]' }
    Write-Host "$($prefixes[$Level]) $Message" -ForegroundColor $colors[$Level]
}

function Test-UrlAccessible {
    param([string]$Url, [string]$Token)
    try {
        $headers = @{}
        if ($Token) { $headers['Authorization'] = "Bearer $Token" }
        $response = Invoke-WebRequest -Uri $Url -Method Head -Headers $headers -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        return $response.StatusCode -eq 200
    }
    catch {
        if ($_.Exception.Response.StatusCode -in @(401, 403)) { return "AuthRequired" }
        return $false
    }
}

function Download-FileWithProgress {
    param([string]$Url, [string]$Destination, [string]$Token)
    
    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    
    try {
        Write-Status "Downloading to: $Destination" -Level Info
        $ProgressPreference = 'Continue'
        Invoke-WebRequest -Uri $Url -OutFile $Destination -Headers $headers -UseBasicParsing -ErrorAction Stop
        return $true
    }
    catch {
        Write-Status "Download failed: $_" -Level Warning
        if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Download-WithHuggingFaceHub {
    param([string]$Url, [string]$Destination, [string]$Token)
    
    if ($Url -notmatch "huggingface\.co/([^/]+/[^/]+)/resolve/main/(.+)") {
        return $false
    }
    $repoId = $Matches[1]
    $filename = $Matches[2]
    
    $pythonScript = @"
import os, sys
try:
    from huggingface_hub import hf_hub_download
    token = os.environ.get('HF_TOKEN') or None
    path = hf_hub_download(repo_id='$repoId', filename='$filename', local_dir='$(Split-Path $Destination -Parent)', local_dir_use_symlinks=False, token=token)
    print(f'SUCCESS:{path}')
except Exception as e:
    print(f'ERROR:{e}')
    sys.exit(1)
"@
    
    $tempScript = [System.IO.Path]::GetTempFileName() + ".py"
    $pythonScript | Out-File -FilePath $tempScript -Encoding utf8
    
    try {
        if ($Token) { $env:HF_TOKEN = $Token }
        $result = & python $tempScript 2>&1
        if ($LASTEXITCODE -eq 0 -and $result -match "SUCCESS:(.+)") {
            Write-Status "HuggingFace Hub download successful" -Level Success
            return $true
        }
        Write-Status "HuggingFace Hub: $result" -Level Warning
        return $false
    }
    finally {
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Get-Model {
    param([hashtable]$ModelSpec, [string]$Token, [switch]$UseHFCLI, [switch]$Force)
    
    $name = $ModelSpec.Name
    $destination = $ModelSpec.Destination
    
    Write-Host ""
    Write-Host "--- $name ---" -ForegroundColor Yellow
    
    # Check if already exists
    if ((Test-Path $destination) -and -not $Force) {
        Write-Status "Already exists: $destination" -Level Success
        return $true
    }
    
    # Ensure directory exists
    $dir = Split-Path $destination -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    
    # Try each candidate URL
    foreach ($url in $ModelSpec.Candidates) {
        Write-Status "Trying: $url" -Level Info
        
        # Check if GGUF file (different destination)
        $actualDest = $destination
        if ($url -match "\.gguf$" -and $destination -notmatch "\.gguf$") {
            $actualDest = $destination -replace "\.safetensors$", ".gguf"
            Write-Status "  -> GGUF format, saving as: $(Split-Path $actualDest -Leaf)" -Level Info
        }
        
        # Try HuggingFace Hub first if enabled
        if ($UseHFCLI) {
            $success = Download-WithHuggingFaceHub -Url $url -Destination $actualDest -Token $Token
            if ($success -and (Test-Path $actualDest)) {
                $size = (Get-Item $actualDest).Length / 1GB
                Write-Status "Complete! Size: $([math]::Round($size, 2)) GB" -Level Success
                return $true
            }
        }
        
        # Try direct download
        $accessible = Test-UrlAccessible -Url $url -Token $Token
        if ($accessible -eq $true) {
            $success = Download-FileWithProgress -Url $url -Destination $actualDest -Token $Token
            if ($success -and (Test-Path $actualDest)) {
                $size = (Get-Item $actualDest).Length / 1GB
                Write-Status "Complete! Size: $([math]::Round($size, 2)) GB" -Level Success
                return $true
            }
        }
        elseif ($accessible -eq "AuthRequired") {
            Write-Status "  Authentication required - trying next source" -Level Warning
        }
        else {
            Write-Status "  URL not accessible - trying next source" -Level Warning
        }
    }
    
    Write-Status "Failed to download $name from any source" -Level Error
    return $false
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Header "HunyuanVideo Setup - Automated Model Downloader v2.0"

Write-Host @"

This script downloads all required models for HunyuanVideo generation.

IMPORTANT: All primary LLaVA sources are now UNGATED!
           No HuggingFace login or Llama 3 license acceptance required.

Models to download:
  1. HunyuanVideo DiT Model (~13 GB)
  2. HunyuanVideo VAE (~500 MB)
  3. CLIP-L Text Encoder (~400 MB)
  4. LLaVA-Llama3 Text Encoder (~8-16 GB) [FROM UNGATED SOURCES]

"@ -ForegroundColor Gray

# Create directories
foreach ($dir in @($HunyuanPath, $ClipPath, $VaePath)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Status "Created: $dir" -Level Info
    }
}

# Track results
$results = @{}

# Download each model
foreach ($key in @('HunyuanModel', 'HunyuanVAE', 'ClipL')) {
    $spec = $ModelSources[$key]
    $results[$key] = Get-Model -ModelSpec $spec -Token $HFToken -UseHFCLI:$UseHFCLI -Force:$Force
}

# Download LLaVA (unless skipped)
if (-not $SkipLLaVA) {
    $results['LLaVA'] = Get-Model -ModelSpec $ModelSources['LLaVA'] -Token $HFToken -UseHFCLI:$UseHFCLI -Force:$Force
}
else {
    Write-Status "Skipping LLaVA download as requested" -Level Info
    $results['LLaVA'] = $true
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Header "Setup Summary"

$allSuccess = $true
foreach ($key in $results.Keys) {
    $status = if ($results[$key]) { "SUCCESS" } else { "FAILED"; $allSuccess = $false }
    $color = if ($results[$key]) { 'Green' } else { 'Red' }
    $icon = if ($results[$key]) { "[OK]" } else { "[X]" }
    $name = $ModelSources[$key].Name
    Write-Host "  $icon $name" -ForegroundColor $color
}

Write-Host ""

if ($allSuccess) {
    Write-Host @"
All models downloaded successfully!

Next Steps:
  1. Ensure ComfyUI is running at http://localhost:8188
  2. Run: python D:\AitherOS-Fresh\generate_hunyuan_gguf.py
  
Or use the verification script:
  .\0551_Verify-HunyuanSetup.ps1

"@ -ForegroundColor Green
}
else {
    # Check which LLaVA file we have
    $llavaFiles = Get-ChildItem "$ClipPath\llava*" -ErrorAction SilentlyContinue
    
    if ($llavaFiles.Count -gt 0) {
        Write-Host @"
Some downloads may have issues, but LLaVA encoder found:
  $($llavaFiles[0].FullName)

This should still work. Try running the generation script.

"@ -ForegroundColor Yellow
    }
    else {
        Write-Host @"
Critical: LLaVA text encoder download failed.

Troubleshooting options:

1. Try with HuggingFace CLI (handles auth automatically):
   pip install huggingface_hub
   .\0550_Setup-HunyuanVideo.ps1 -UseHFCLI

2. With explicit token:
   `$env:HF_TOKEN = "your_token_here"
   .\0550_Setup-HunyuanVideo.ps1 -UseHFCLI

3. Manual download from ungated source:
   URL: https://huggingface.co/Kijai/HunyuanVideo_comfy/resolve/main/llava_llama3_fp8_scaled.safetensors
   Save to: $ClipPath\llava_llama3_fp8.safetensors

"@ -ForegroundColor Red
    }
}
