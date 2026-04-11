#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: Git, Python
# Description: Installs Fooocus (Simple SDXL)
# Tags: ai, image-generation, sdxl, fooocus

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$InstallPath,

    [Parameter()]
    [switch]$SkipRequirements
)

. "$PSScriptRoot/_init.ps1"

# Ensure Feature is Enabled
Ensure-FeatureEnabled -Section "Features" -Key "AI.Fooocus" -Name "Fooocus"

# Resolve Configuration
if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    $configPath = Get-AitherConfigs -Section "Features" -Key "AI.Fooocus.InstallPath" -ErrorAction SilentlyContinue
    if ($configPath) {
        $InstallPath = $configPath
    }
    else {
        if ($IsWindows) {
            $InstallPath = "$env:USERPROFILE\Fooocus"
        }
        else {
            $InstallPath = "$env:HOME/Fooocus"
        }
    }
}

if ([string]::IsNullOrEmpty($InstallPath)) {
    if ($IsWindows) {
        $InstallPath = "$env:USERPROFILE\Fooocus"
    }
    else {
        $InstallPath = "$env:HOME/Fooocus"
    }
}

Write-Host "🎨 Installing Fooocus to $InstallPath..." -ForegroundColor Cyan

try {
    # 1. Check Prerequisites
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed. Please run 0207_Install-Git.ps1 first."
    }

    $pythonCmd = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { "python3" }
    if (-not $pythonCmd) {
        throw "Python is not installed. Please run 0206_Install-Python.ps1 first."
    }

    # 2. Clone Repository
    if ($PSCmdlet.ShouldProcess($InstallPath, "Clone Repository")) {
        if (Test-Path $InstallPath) {
            Write-Host "   Directory exists. Pulling latest changes..." -ForegroundColor Yellow
            Push-Location $InstallPath
            try {
                git pull
            }
            finally {
                Pop-Location
            }
        }
        else {
            Write-Host "   Cloning repository..." -ForegroundColor Yellow
            git clone https://github.com/lllyasviel/Fooocus.git $InstallPath
        }
    }

    # 3. Install Requirements
    if (-not $SkipRequirements -and $PSCmdlet.ShouldProcess($InstallPath, "Install Requirements")) {
        Write-Host "   Setting up Virtual Environment..." -ForegroundColor Yellow
        Push-Location $InstallPath
        try {
            # Create Venv
            if (-not (Test-Path "venv")) {
                & $pythonCmd -m venv venv
            }

            # Determine Venv Python
            if ($IsWindows) {
                $venvPython = "venv\Scripts\python.exe"
            }
            else {
                $venvPython = "venv/bin/python"
            }

            Write-Host "   Installing requirements..." -ForegroundColor Yellow
            & $venvPython -m pip install --upgrade pip
            & $venvPython -m pip install -r requirements_versions.txt

            Write-Host "✅ Installation complete." -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
    }
}
catch {
    Write-Error "Failed to install Fooocus: $_"
    exit 1
}
