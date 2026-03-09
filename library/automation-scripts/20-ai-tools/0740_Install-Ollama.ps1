#Requires -Version 7.0

<#
.SYNOPSIS
    Installs and configures Ollama for local LLM inference.
.DESCRIPTION
    Downloads and installs Ollama, starts the service, and pulls the specified model.
    Supports Linux and Windows.
.PARAMETER Model
    The default model to pull (default: llama3.2-vision).
.PARAMETER Port
    The port to run Ollama on (default: 11434).
.NOTES
    Stage: AI Tools
    Order: 0740
#>

[CmdletBinding()]
param(
    [string]$Model,
    [int]$Port
)

. "$PSScriptRoot/_init.ps1"

if ([string]::IsNullOrWhiteSpace($Model)) {
    $Model = "llama3.2-vision"
}

if ($Port -eq 0) {
    $Port = 11434
}

Write-Host "🤖 Setting up Ollama Local AI Node..." -ForegroundColor Cyan

# 1. Check if Ollama is already installed
if (Get-Command "ollama" -ErrorAction SilentlyContinue) {
    Write-Host "✅ Ollama is already installed." -ForegroundColor Green
}
else {
    Write-Host "⬇️ Installing Ollama..." -ForegroundColor Yellow

    if ($IsLinux) {
        # Official Linux install script
        Write-Host "   Running Linux installer (curl https://ollama.com/install.sh)..."
        curl -fsSL https://ollama.com/install.sh | sh
    }
    elseif ($IsWindows) {
        Write-Host "   Downloading Windows installer..."
        $installerUrl = "https://ollama.com/download/OllamaSetup.exe"
        $installerPath = Join-Path $env:TEMP "OllamaSetup.exe"
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath

        Write-Host "   Running installer..."
        Start-Process -FilePath $installerPath -ArgumentList "/silent" -Wait
    }
    else {
        Write-Error "Unsupported operating system for automatic installation."
        exit 1
    }

    # Verify installation
    if (-not (Get-Command "ollama" -ErrorAction SilentlyContinue)) {
        Write-Error "❌ Installation failed. 'ollama' command not found."
        exit 1
    }
    Write-Host "✅ Ollama installed successfully." -ForegroundColor Green
}

# 2. Start Service (if not running)
Write-Host "🔄 Checking Ollama service..." -ForegroundColor Cyan

$serviceRunning = $false
try {
    $response = Invoke-WebRequest -Uri "http://localhost:$Port" -Method Get -ErrorAction SilentlyContinue
    if ($response.StatusCode -eq 200) {
        $serviceRunning = $true
        Write-Host "✅ Ollama service is running on port $Port." -ForegroundColor Green
    }
}
catch {
    # Service not reachable
}

if (-not $serviceRunning) {
    Write-Host "🚀 Starting Ollama service..." -ForegroundColor Yellow
    if ($IsLinux) {
        $started = $false
        # Try systemd first if available and active
        if (Get-Command "systemctl" -ErrorAction SilentlyContinue) {
            # Check if systemd is actually running
            $systemdCheck = systemctl is-system-running 2>&1
            if ($LASTEXITCODE -eq 0 -or $systemdCheck -match "running" -or $systemdCheck -match "degraded") {
                try {
                    sudo systemctl start ollama
                    sudo systemctl enable ollama
                    $started = $true
                }
                catch {
                    Write-Warning "Failed to start via systemctl: $_"
                }
            }
        }

        if (-not $started) {
            # Fallback for containers/WSL without systemd
            Write-Host "   Systemd not available. Starting 'ollama serve' in background..."
            # Start-Process is better than Start-Job here as it keeps the process alive independent of the PS session job
            # But we need to hide output to prevent blocking
            Start-Process -FilePath "ollama" -ArgumentList "serve" -NoNewWindow -RedirectStandardOutput "/dev/null" -RedirectStandardError "/dev/null"
        }
    }
    elseif ($IsWindows) {
        # Windows installer usually adds it to startup, but we can start the app
        Start-Process "ollama" -ArgumentList "serve" -NoNewWindow
    }

    # Wait for service to come up
    Write-Host "   Waiting for service to initialize..."
    $retries = 0
    while ($retries -lt 10) {
        Start-Sleep -Seconds 2
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$Port" -Method Get -ErrorAction SilentlyContinue
            if ($response.StatusCode -eq 200) {
                Write-Host "✅ Service is up!" -ForegroundColor Green
                break
            }
        }
        catch {}
        $retries++
    }
}

# 3. Pull Model
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    Write-Host "🧠 Checking model: $Model..." -ForegroundColor Cyan

    # List models to see if it exists
    $models = ollama list
    if ($models -match $Model) {
        Write-Host "✅ Model '$Model' is already available." -ForegroundColor Green
    }
    else {
        Write-Host "⬇️ Pulling model '$Model' (this may take a while)..." -ForegroundColor Yellow
        ollama pull $Model
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Model pulled successfully." -ForegroundColor Green
        }
        else {
            Write-Error "❌ Failed to pull model."
        }
    }
}

Write-Host "🎉 Local AI Node setup complete!" -ForegroundColor Green
Write-Host "   API URL: http://localhost:$Port"
Write-Host "   Model:   $Model"
