#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: Git, Node.js
# Description: Installs SillyTavern (LLM Frontend)
# Tags: ai, llm, frontend, sillytavern

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$InstallPath
)

. "$PSScriptRoot/_init.ps1"

if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    if ($IsWindows) {
        $InstallPath = "$env:USERPROFILE\SillyTavern"
    }
    else {
        $InstallPath = "$env:HOME/SillyTavern"
    }
}

if ([string]::IsNullOrEmpty($InstallPath)) {
    if ($IsWindows) {
        $InstallPath = "$env:USERPROFILE\SillyTavern"
    }
    else {
        $InstallPath = "$env:HOME/SillyTavern"
    }
}

Write-Host "🍺 Installing SillyTavern to $InstallPath..." -ForegroundColor Cyan

try {
    # 1. Check Prerequisites
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed. Please run 0207_Install-Git.ps1 first."
    }

    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw "Node.js is not installed. Please run 0201_Install-Node.ps1 first."
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
            git clone https://github.com/SillyTavern/SillyTavern $InstallPath
        }
    }

    # 3. Install Dependencies
    if ($PSCmdlet.ShouldProcess($InstallPath, "Install Dependencies")) {
        Write-Host "   Installing Node.js dependencies..." -ForegroundColor Yellow
        Push-Location $InstallPath
        try {
            npm install
            Write-Host "✅ Installation complete." -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
    }
}
catch {
    Write-Error "Failed to install SillyTavern: $_"
    exit 1
}
