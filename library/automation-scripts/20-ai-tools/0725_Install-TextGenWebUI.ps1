#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: Git, Python
# Description: Installs Oobabooga Text Generation WebUI
# Tags: ai, llm, text-generation, oobabooga

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$InstallPath,

    [Parameter()]
    [switch]$SkipRequirements
)

. "$PSScriptRoot/_init.ps1"

if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    if ($IsWindows) {
        $InstallPath = "$env:USERPROFILE\text-generation-webui"
    }
    else {
        $InstallPath = "$env:HOME/text-generation-webui"
    }
}

if ([string]::IsNullOrEmpty($InstallPath)) {
    if ($IsWindows) {
        $InstallPath = "$env:USERPROFILE\text-generation-webui"
    }
    else {
        $InstallPath = "$env:HOME/text-generation-webui"
    }
}

Write-Host "🤖 Installing Text Generation WebUI to $InstallPath..." -ForegroundColor Cyan

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
            git clone https://github.com/oobabooga/text-generation-webui $InstallPath
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

            # Install Torch (Manual step often needed for GPU, but we'll try standard requirements)
            # Oobabooga has specific requirements files for different hardware
            # We'll default to the standard requirements.txt which usually handles it or prompts
            # For automation, we might need to be more specific, but let's start generic.

            Write-Host "   Installing requirements..." -ForegroundColor Yellow
            & $venvPython -m pip install --upgrade pip
            & $venvPython -m pip install -r requirements.txt

            Write-Host "✅ Installation complete." -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
    }
}
catch {
    Write-Error "Failed to install Text Generation WebUI: $_"
    exit 1
}
