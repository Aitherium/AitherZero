#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: Git, Python
# Description: Installs Stable Diffusion WebUI (Automatic1111)
# Tags: ai, stable-diffusion, image-generation

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$InstallPath,

    [Parameter()]
    [switch]$SkipRequirements
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
        Write-AitherLog -Message $Message -Level $Level -Source '0720_Install-StableDiffusionWebUI'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting Stable Diffusion WebUI installation..."

try {
    # 1. Check Prerequisites
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed. Please run 0207_Install-Git.ps1 first."
    }

    if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) {
        throw "Python 3 is not installed. Please run 0206_Install-Python.ps1 first."
    }

    # 2. Clone Repository
    if ($PSCmdlet.ShouldProcess($InstallPath, "Clone Stable Diffusion WebUI")) {
        if (Test-Path $InstallPath) {
            Write-ScriptLog "Directory exists at $InstallPath. Pulling latest changes..."
            Push-Location $InstallPath
            try {
                git pull
            }
            finally {
                Pop-Location
            }
        }
        else {
            Write-ScriptLog "Cloning repository to $InstallPath..."
            git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git $InstallPath
        }
    }

    # 3. Setup Virtual Environment (Optional but recommended to pre-create)
    if (-not $SkipRequirements) {
        if ($PSCmdlet.ShouldProcess($InstallPath, "Setup Python Environment")) {
            Push-Location $InstallPath
            try {
                # Check if venv exists
                if (-not (Test-Path "venv")) {
                    Write-ScriptLog "Creating virtual environment..."
                    python3 -m venv venv
                }

                # Install requirements
                Write-ScriptLog "Installing requirements..."
                if ($IsLinux -or $IsMacOS) {
                    ./venv/bin/pip install -r requirements_versions.txt
                }
                else {
                    ./venv/Scripts/pip install -r requirements_versions.txt
                }
            }
            finally {
                Pop-Location
            }
        }
    }

    Write-ScriptLog "Stable Diffusion WebUI installed successfully at $InstallPath"
    Write-ScriptLog "To run: cd $InstallPath; ./webui.sh --api"

}
catch {
    Write-ScriptLog "Installation failed: $_" "Error"
    exit 1
}
