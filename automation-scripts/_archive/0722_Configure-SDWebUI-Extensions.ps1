#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: 0720_Install-StableDiffusionWebUI
# Description: Installs essential extensions for Stable Diffusion WebUI
# Tags: ai, stable-diffusion, extensions

[CmdletBinding(SupportsShouldProcess)]
param(
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
        Write-AitherLog -Message $Message -Level $Level -Source '0722_Configure-SDWebUI-Extensions'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Configuring Stable Diffusion Extensions..."

try {
    if (-not (Test-Path $InstallPath)) {
        throw "Stable Diffusion WebUI not found at $InstallPath. Run 0720_Install-StableDiffusionWebUI.ps1 first."
    }

    $extensionsPath = Join-Path $InstallPath "extensions"
    if (-not (Test-Path $extensionsPath)) {
        New-Item -ItemType Directory -Path $extensionsPath -Force | Out-Null
    }

    $extensions = @(
        @{ Name = "sd-webui-controlnet"; Url = "https://github.com/Mikubill/sd-webui-controlnet" },
        @{ Name = "stable-diffusion-webui-images-browser"; Url = "https://github.com/AlUlkesh/stable-diffusion-webui-images-browser" },
        @{ Name = "ultimate-upscale-for-automatic1111"; Url = "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111" }
    )

    if ($PSCmdlet.ShouldProcess($extensionsPath, "Install Extensions")) {
        foreach ($ext in $extensions) {
            $dest = Join-Path $extensionsPath $ext.Name
            if (Test-Path $dest) {
                Write-ScriptLog "Extension $($ext.Name) already installed. Updating..."
                Push-Location $dest
                try {
                    git pull
                }
                finally {
                    Pop-Location
                }
            }
            else {
                Write-ScriptLog "Installing extension $($ext.Name)..."
                git clone $ext.Url $dest
            }
        }
    }

    Write-ScriptLog "Extension configuration complete."

}
catch {
    Write-ScriptLog "Extension configuration failed: $_" "Error"
    exit 1
}
