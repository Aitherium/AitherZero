#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: 0720_Install-StableDiffusionWebUI
# Description: Downloads curated Stable Diffusion models from CivitAI and HuggingFace
# Tags: ai, stable-diffusion, models, civitai, huggingface

<#
.SYNOPSIS
    Downloads popular Stable Diffusion models from CivitAI and HuggingFace.

.DESCRIPTION
    Provides a wide selection of SD models categorized by:
    - Base Models (SD 1.5, SDXL)
    - Realistic (photorealistic styles)
    - Artistic (paintings, illustrations)
    - Anime (anime/manga styles)
    - Creative (fantasy, sci-fi)
    - Specialized (architecture, product design)

.PARAMETER Model
    The model to download. Categories:

    BASE MODELS:
    - sd-v1.5 (Stable Diffusion 1.5 - Original, 4GB VRAM)
    - sdxl-base (SDXL Base 1.0 - High quality, 8GB+ VRAM)
    - sdxl-turbo (SDXL Turbo - Fast generation, 6GB VRAM)
    - sd-v2.1 (Stable Diffusion 2.1 - Improved, 6GB VRAM)

    REALISTIC (Photorealistic):
    - realistic-vision (Realistic Vision v5.1 - Top photorealism)
    - absolute-reality (Absolute Reality v1.8 - Ultra realistic)
    - epicrealism (Epic Realism - Natural photos)
    - deliberate (Deliberate v3 - Versatile realistic)
    - majicmix-realistic (MajicMix Realistic - Portrait focus)

    ARTISTIC (Paintings/Illustrations):
    - dreamshaper (DreamShaper 8 - Versatile, popular)
    - revanimated (ReV Animated - Vibrant art)
    - anything-v5 (Anything V5 - General art)
    - protogen (Protogen x3.4 - Sci-fi art)
    - openjourney (OpenJourney - MidJourney style)

    ANIME:
    - counterfeit (Counterfeit V3 - Top anime)
    - anything-v3 (Anything V3 - Classic anime)
    - abyssorangemix (AbyssOrangeMix - Vibrant anime)
    - anythingelse (AnythingElse V4 - Balanced anime)
    - cetusmix (Cetus-Mix - Detailed anime)

    CREATIVE/FANTASY:
    - dreamshaper-xl (DreamShaper XL - High-res creative)
    - ghostmix (GhostMix - Dark fantasy)
    - darksouls-diffusion (Dark Souls - Game style)
    - inkpunk-diffusion (Inkpunk - Tattoo/punk art)
    - redshift-diffusion (Redshift - 3D rendered)

    SPECIALIZED:
    - architecture-diffusion (Architecture - Building design)
    - product-design (Product Design - Industrial)
    - food-diffusion (Food Photography)
    - portrait-plus (Portrait+ - Face focus)
    - landscape-diffusion (Landscape - Nature scenes)

.PARAMETER Source
    Download source: CivitAI or HuggingFace. Auto-selects based on model.

.PARAMETER InstallPath
    Custom installation path. Defaults to config or ~/stable-diffusion-webui

.EXAMPLE
    .\0723_Setup-SDModels.ps1 -Model realistic-vision
    Downloads Realistic Vision v5.1 from CivitAI

.EXAMPLE
    .\0723_Setup-SDModels.ps1 -Model sdxl-base
    Downloads SDXL Base from HuggingFace
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet(
        # Base Models
        "sd-v1.5", "sdxl-base", "sdxl-turbo", "sd-v2.1",
        # Realistic
        "realistic-vision", "absolute-reality", "epicrealism", "deliberate", "majicmix-realistic",
        # Artistic
        "dreamshaper", "revanimated", "anything-v5", "protogen", "openjourney",
        # Anime
        "counterfeit", "anything-v3", "abyssorangemix", "anythingelse", "cetusmix",
        # Creative/Fantasy
        "dreamshaper-xl", "ghostmix", "darksouls-diffusion", "inkpunk-diffusion", "redshift-diffusion",
        # Specialized
        "architecture-diffusion", "product-design", "food-diffusion", "portrait-plus", "landscape-diffusion"
    )]
    [string]$Model = "dreamshaper",

    [ValidateSet("Auto", "CivitAI", "HuggingFace")]
    [string]$Source = "Auto",

    [Parameter()]
    [string]$InstallPath
)

. "$PSScriptRoot/_init.ps1"

# Ensure Feature is Enabled
Ensure-FeatureEnabled -Section "Features" -Key "AI.StableDiffusion" -Name "Stable Diffusion WebUI"

# Resolve Configuration
if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    $configPath = Get-AitherConfigs -Section "Features" -Key "AI.StableDiffusion.InstallPath" -ErrorAction SilentlyContinue
    if ($configPath) {
        $InstallPath = $configPath
    }
    else {
        $InstallPath = "$env:HOME/stable-diffusion-webui"
    }
}

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0723_Setup-SDModels'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

function Get-VRAM {
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            $vramOutput = nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits
            $vram = [int]$vramOutput[0]
            return $vram
        }
        catch {
            return 0
        }
    }
    return 0
}

function Download-Model {
    param(
        [string]$Url,
        [string]$FileName,
        [string]$Destination
    )

    $dest = Join-Path $Destination $FileName

    if (Test-Path $dest) {
        Write-ScriptLog "Model $FileName already exists. Skipping download."
        return
    }

    Write-ScriptLog "Downloading $FileName from $Url..."
    Write-Host "  This may take several minutes depending on file size (2-7GB typical)"

    try {
        # Use aria2c if available for faster downloads
        if (Get-Command aria2c -ErrorAction SilentlyContinue) {
            Write-ScriptLog "Using aria2c for accelerated download..."
            aria2c --continue=true --max-connection-per-server=16 --min-split-size=1M `
                   --split=16 --out="$dest" "$Url"
        }
        else {
            # Fallback to Invoke-WebRequest
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $dest -UserAgent "AitherZero/2.0"
            $ProgressPreference = 'Continue'
        }

        Write-ScriptLog "Successfully downloaded $FileName"
    }
    catch {
        Write-ScriptLog "Failed to download $FileName: $_" "Error"
        if (Test-Path $dest) { Remove-Item $dest -Force }
        throw
    }
}

# Main Script
Write-Host ""
Write-Host "🎨 Stable Diffusion Model Setup" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan

try {
    if (-not (Test-Path $InstallPath)) {
        throw "Stable Diffusion WebUI not found at $InstallPath. Run 0720_Install-StableDiffusionWebUI.ps1 first."
    }

    $modelsPath = Join-Path $InstallPath "models/Stable-diffusion"
    if (-not (Test-Path $modelsPath)) {
        New-Item -ItemType Directory -Path $modelsPath -Force | Out-Null
    }

    # Detect Hardware
    $vram = Get-VRAM
    if ($vram -gt 0) {
        Write-Host "🖥️  Detected GPU VRAM: $vram MB" -ForegroundColor Green
    }
    else {
        Write-Host "⚠️  No NVIDIA GPU detected - CPU mode" -ForegroundColor Yellow
    }

    # Display model information
    Write-Host ""
    Write-Host "📊 Model Information:" -ForegroundColor Cyan

    $modelInfo = @{
        # Base Models
        "sd-v1.5" = @{
            Category = "Base Model"
            Name = "Stable Diffusion v1.5"
            Size = "~4GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors"
            FileName = "sd-v1-5-pruned-emaonly.safetensors"
            BestFor = "Original SD, widely compatible"
        }
        "sdxl-base" = @{
            Category = "Base Model"
            Name = "Stable Diffusion XL Base 1.0"
            Size = "~7GB"
            VRAM = "8GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors"
            FileName = "sdxl-base-1.0.safetensors"
            BestFor = "High resolution, best quality"
        }
        "sdxl-turbo" = @{
            Category = "Base Model"
            Name = "SDXL Turbo"
            Size = "~7GB"
            VRAM = "6GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/stabilityai/sdxl-turbo/resolve/main/sd_xl_turbo_1.0_fp16.safetensors"
            FileName = "sdxl-turbo-1.0.safetensors"
            BestFor = "Fast generation, 1-4 steps"
        }
        "sd-v2.1" = @{
            Category = "Base Model"
            Name = "Stable Diffusion v2.1"
            Size = "~5GB"
            VRAM = "6GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/stabilityai/stable-diffusion-2-1/resolve/main/v2-1_768-ema-pruned.safetensors"
            FileName = "sd-v2-1-768-ema.safetensors"
            BestFor = "Improved over v1.5, 768px"
        }

        # Realistic Models
        "realistic-vision" = @{
            Category = "Realistic"
            Name = "Realistic Vision v5.1"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/130072"
            FileName = "realistic-vision-v5.1.safetensors"
            BestFor = "Top photorealistic quality"
        }
        "absolute-reality" = @{
            Category = "Realistic"
            Name = "Absolute Reality v1.8.1"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/132760"
            FileName = "absolute-reality-v1.8.1.safetensors"
            BestFor = "Ultra realistic portraits"
        }
        "epicrealism" = @{
            Category = "Realistic"
            Name = "Epic Realism"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/143906"
            FileName = "epicrealism-naturalsin.safetensors"
            BestFor = "Natural photo style"
        }
        "deliberate" = @{
            Category = "Realistic"
            Name = "Deliberate v3"
            Size = "~4GB"
            VRAM = "6GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/134065"
            FileName = "deliberate-v3.safetensors"
            BestFor = "Versatile realistic/artistic"
        }
        "majicmix-realistic" = @{
            Category = "Realistic"
            Name = "MajicMix Realistic v7"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/176425"
            FileName = "majicmix-realistic-v7.safetensors"
            BestFor = "Asian portrait focus"
        }

        # Artistic Models
        "dreamshaper" = @{
            Category = "Artistic"
            Name = "DreamShaper 8"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/128713"
            FileName = "dreamshaper-8.safetensors"
            BestFor = "Versatile, popular choice"
        }
        "revanimated" = @{
            Category = "Artistic"
            Name = "ReV Animated v1.2.2"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/46846"
            FileName = "revanimated-v1.2.2.safetensors"
            BestFor = "Vibrant illustrations"
        }
        "anything-v5" = @{
            Category = "Artistic"
            Name = "Anything V5"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/30163"
            FileName = "anything-v5.safetensors"
            BestFor = "General artwork"
        }
        "protogen" = @{
            Category = "Artistic"
            Name = "Protogen x3.4"
            Size = "~4GB"
            VRAM = "6GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/3627"
            FileName = "protogen-x3.4.safetensors"
            BestFor = "Sci-fi art style"
        }
        "openjourney" = @{
            Category = "Artistic"
            Name = "OpenJourney v4"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/prompthero/openjourney-v4/resolve/main/openjourney-v4.safetensors"
            FileName = "openjourney-v4.safetensors"
            BestFor = "MidJourney-like style"
        }

        # Anime Models
        "counterfeit" = @{
            Category = "Anime"
            Name = "Counterfeit V3.0"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/57618"
            FileName = "counterfeit-v3.0.safetensors"
            BestFor = "Top anime quality"
        }
        "anything-v3" = @{
            Category = "Anime"
            Name = "Anything V3"
            Size = "~4GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/Linaqruf/anything-v3.0/resolve/main/anything-v3-fp16-pruned.safetensors"
            FileName = "anything-v3-pruned.safetensors"
            BestFor = "Classic anime style"
        }
        "abyssorangemix" = @{
            Category = "Anime"
            Name = "AbyssOrangeMix3"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/9942"
            FileName = "abyssorangemix3.safetensors"
            BestFor = "Vibrant anime colors"
        }
        "anythingelse" = @{
            Category = "Anime"
            Name = "AnythingElse V4"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/5200"
            FileName = "anythingelse-v4.safetensors"
            BestFor = "Balanced anime/realistic"
        }
        "cetusmix" = @{
            Category = "Anime"
            Name = "Cetus-Mix V3.5"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/105924"
            FileName = "cetusmix-v3.5.safetensors"
            BestFor = "Detailed anime characters"
        }

        # Creative/Fantasy
        "dreamshaper-xl" = @{
            Category = "Creative/Fantasy"
            Name = "DreamShaper XL"
            Size = "~7GB"
            VRAM = "8GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/251662"
            FileName = "dreamshaper-xl-1.0.safetensors"
            BestFor = "High-res creative art"
        }
        "ghostmix" = @{
            Category = "Creative/Fantasy"
            Name = "GhostMix v2.0"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/76907"
            FileName = "ghostmix-v2.0.safetensors"
            BestFor = "Dark fantasy, gothic"
        }
        "darksouls-diffusion" = @{
            Category = "Creative/Fantasy"
            Name = "Dark Souls Diffusion"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/nitrosocke/elden-ring-diffusion/resolve/main/eldenring-v3-pruned.safetensors"
            FileName = "darksouls-diffusion.safetensors"
            BestFor = "Dark fantasy game style"
        }
        "inkpunk-diffusion" = @{
            Category = "Creative/Fantasy"
            Name = "Inkpunk Diffusion"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/Envvi/Inkpunk-Diffusion/resolve/main/Inkpunk-Diffusion-v2.safetensors"
            FileName = "inkpunk-diffusion-v2.safetensors"
            BestFor = "Tattoo/punk art style"
        }
        "redshift-diffusion" = @{
            Category = "Creative/Fantasy"
            Name = "Redshift Diffusion"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/nitrosocke/redshift-diffusion/resolve/main/redshift-diffusion-v10.safetensors"
            FileName = "redshift-diffusion-v10.safetensors"
            BestFor = "3D rendered look"
        }

        # Specialized
        "architecture-diffusion" = @{
            Category = "Specialized"
            Name = "Architecture Diffusion"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/Merjimi/architecture-diffusion/resolve/main/model.safetensors"
            FileName = "architecture-diffusion.safetensors"
            BestFor = "Building/interior design"
        }
        "product-design" = @{
            Category = "Specialized"
            Name = "Product Design Diffusion"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/wavymulder/product-design/resolve/main/product-design.safetensors"
            FileName = "product-design.safetensors"
            BestFor = "Industrial/product renders"
        }
        "food-diffusion" = @{
            Category = "Specialized"
            Name = "Food Diffusion"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/Astrofox/food-diffusion/resolve/main/food-diffusion.safetensors"
            FileName = "food-diffusion.safetensors"
            BestFor = "Food photography"
        }
        "portrait-plus" = @{
            Category = "Specialized"
            Name = "Portrait+ v1.0"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "CivitAI"
            Url = "https://civitai.com/api/download/models/94640"
            FileName = "portrait-plus-v1.0.safetensors"
            BestFor = "Portrait focus, faces"
        }
        "landscape-diffusion" = @{
            Category = "Specialized"
            Name = "Landscape Diffusion"
            Size = "~2GB"
            VRAM = "4GB+"
            Source = "HuggingFace"
            Url = "https://huggingface.co/wavymulder/landscape-diffusion/resolve/main/landscape-diffusion.safetensors"
            FileName = "landscape-diffusion.safetensors"
            BestFor = "Nature/landscape scenes"
        }
    }

    $info = $modelInfo[$Model]
    Write-Host "   Category: $($info.Category)" -ForegroundColor White
    Write-Host "   Name: $($info.Name)" -ForegroundColor White
    Write-Host "   File Size: $($info.Size)" -ForegroundColor White
    Write-Host "   VRAM Required: $($info.VRAM)" -ForegroundColor White
    Write-Host "   Source: $($info.Source)" -ForegroundColor White
    Write-Host "   Best For: $($info.BestFor)" -ForegroundColor White

    # VRAM Warning
    if ($vram -gt 0) {
        $requiredVRAM = [int]($info.VRAM -replace '[^\d]', '')
        if ($vram -lt ($requiredVRAM * 1024)) {
            Write-Host ""
            Write-Host "⚠️  WARNING: Your GPU has $vram MB VRAM, but $($info.VRAM) recommended" -ForegroundColor Yellow
            Write-Host "   Model may run slowly or require --lowvram flag" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "📥 Starting download..." -ForegroundColor Cyan
    Write-Host ""

    if ($PSCmdlet.ShouldProcess($info.Name, "Download Model")) {
        Download-Model -Url $info.Url -FileName $info.FileName -Destination $modelsPath
    }

    Write-Host ""
    Write-Host "✅ Model setup complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Model installed to: $modelsPath" -ForegroundColor Cyan
    Write-Host "You can now use this model in Stable Diffusion WebUI" -ForegroundColor Cyan
    Write-Host ""

}
catch {
    Write-ScriptLog "Model setup failed: $_" "Error"
    Write-Host ""
    Write-Host "❌ Error: $_" -ForegroundColor Red
    Write-Host ""
    exit 1
}
