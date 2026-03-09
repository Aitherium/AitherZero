#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: 0720_Install-StableDiffusionWebUI
# Description: Downloads appropriate Stable Diffusion models based on hardware
# Tags: ai, stable-diffusion, models

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$InstallPath,

    [Parameter()]
    [ValidateSet("Auto", "SD15", "SDXL", "All")]
    [string]$ModelSet = "Auto"
)

. "$PSScriptRoot/_init.ps1"

if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    $InstallPath = "$env:HOME/stable-diffusion-webui"
}

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0721_Configure-SDWebUI-Models'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

function Get-VRAM {
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            $vramOutput = nvidia-smi --query-gpu=memory.total --format=csv, noheader, nounits
            $vram = [int]$vramOutput[0]
            return $vram
        }
        catch {
            return 0
        }
    }
    return 0
}

function Download-File {
    param($Url, $Dest)
    if (-not (Test-Path $Dest)) {
        Write-ScriptLog "Downloading $(Split-Path $Dest -Leaf)..."
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UserAgent "AitherZero/1.0"
    }
    else {
        Write-ScriptLog "File $(Split-Path $Dest -Leaf) already exists. Skipping."
    }
}

Write-ScriptLog "Configuring Stable Diffusion Models..."

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
    Write-ScriptLog "Detected VRAM: $vram MB"

    $downloadList = @()

    # Decision Logic
    if ($ModelSet -eq "Auto") {
        if ($vram -ge 8000) {
            Write-ScriptLog "High VRAM detected. Selecting SDXL models."
            $ModelSet = "SDXL"
        }
        else {
            Write-ScriptLog "Standard/Low VRAM detected. Selecting SD 1.5 models."
            $ModelSet = "SD15"
        }
    }

    # Define Models
    $sd15Base = @{ Name = "v1-5-pruned-emaonly.safetensors"; Url = "https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors" }
    $dreamshaper = @{ Name = "DreamShaper_8_pruned.safetensors"; Url = "https://huggingface.co/Lykon/DreamShaper/resolve/main/DreamShaper_8_pruned.safetensors" }

    $sdxlBase = @{ Name = "sd_xl_base_1.0.safetensors"; Url = "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors" }
    $sdxlRefiner = @{ Name = "sd_xl_refiner_1.0.safetensors"; Url = "https://huggingface.co/stabilityai/stable-diffusion-xl-refiner-1.0/resolve/main/sd_xl_refiner_1.0.safetensors" }

    if ($ModelSet -eq "SD15" -or $ModelSet -eq "All") {
        $downloadList += $sd15Base
        $downloadList += $dreamshaper
    }

    if ($ModelSet -eq "SDXL" -or $ModelSet -eq "All") {
        $downloadList += $sdxlBase
        $downloadList += $sdxlRefiner
        # If SDXL is chosen but we want a good general purpose one too, DreamShaper is still great and lighter
        $downloadList += $dreamshaper
    }

    # Execute Downloads
    if ($PSCmdlet.ShouldProcess($modelsPath, "Download Models")) {
        foreach ($model in $downloadList) {
            $dest = Join-Path $modelsPath $model.Name
            Download-File -Url $model.Url -Dest $dest
        }
    }

    Write-ScriptLog "Model configuration complete."

}
catch {
    Write-ScriptLog "Model configuration failed: $_" "Error"
    exit 1
}
