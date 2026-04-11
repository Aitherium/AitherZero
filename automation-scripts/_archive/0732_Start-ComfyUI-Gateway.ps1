#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: ComfyUI, Cloudflared
# Description: Starts ComfyUI and exposes it via Cloudflare Tunnel
# Tags: ai, comfyui, gateway, tunnel

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallPath,

    [Parameter()]
    [int]$Port = 8188
)

. "$PSScriptRoot/_init.ps1"

# Ensure Feature is Enabled
Ensure-FeatureEnabled -Section "Features" -Key "AI.ComfyUI" -Name "ComfyUI"

$Config = Get-AitherConfigs

# Resolve Configuration
if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    if ($Config.Features.AI.ComfyUI.InstallPath) {
        $InstallPath = $Config.Features.AI.ComfyUI.InstallPath
    }
    else {
        $InstallPath = "$env:HOME/ComfyUI"
    }
}

$DefaultDrive = $Config.Infrastructure.Defaults.DefaultDrive
if (-not $DefaultDrive) { $DefaultDrive = "E" }

# Set default InstallPath if not provided
if ([string]::IsNullOrEmpty($InstallPath)) {
    if ($IsWindows) {
        $InstallPath = "$($DefaultDrive):\ComfyUI"
    }
    else {
        $InstallPath = Join-Path $env:HOME "ComfyUI"
    }
}

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0732_Start-ComfyUI-Gateway'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting ComfyUI Gateway..."

# 1. Start ComfyUI
if (-not (Test-Path $InstallPath)) {
    throw "ComfyUI not found at $InstallPath"
}

Write-ScriptLog "Launching ComfyUI..."

# Determine Python Path (Prefer venv)
$venvPython = if ($IsWindows) { Join-Path $InstallPath "venv/Scripts/python.exe" } else { Join-Path $InstallPath "venv/bin/python" }
if (Test-Path $venvPython) {
    $pythonCmd = $venvPython
    Write-ScriptLog "Using Virtual Environment Python: $pythonCmd"
}
else {
    $pythonCmd = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { "python3" }
    Write-ScriptLog "Virtual environment not found. Using System Python: $pythonCmd" "Warning"
}

$mainPy = Join-Path $InstallPath "main.py"

# Start ComfyUI in background
$comfyProcess = Start-Process -FilePath $pythonCmd -ArgumentList "$mainPy --port $Port" -PassThru -NoNewWindow
Write-ScriptLog "ComfyUI started with PID: $($comfyProcess.Id)"

# Wait a moment for it to initialize
Start-Sleep -Seconds 5

# 2. Setup Cloudflare Tunnel
$cloudflaredPath = if ($IsWindows) { "$env:USERPROFILE\cloudflared.exe" } else { "/usr/local/bin/cloudflared" }
$localCloudflared = Join-Path $PSScriptRoot "cloudflared.exe"
$cwdCloudflared = Join-Path (Get-Location) "cloudflared.exe"

if (Test-Path $localCloudflared) {
    $cfCmd = $localCloudflared
}
elseif (Test-Path $cwdCloudflared) {
    $cfCmd = $cwdCloudflared
}
elseif (Test-Path $cloudflaredPath) {
    $cfCmd = $cloudflaredPath
}
elseif (Get-Command cloudflared -ErrorAction SilentlyContinue) {
    $cfCmd = "cloudflared"
}
else {
    Write-ScriptLog "Cloudflared not found. Downloading..."
    if ($IsWindows) {
        Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $cloudflaredPath
        $cfCmd = $cloudflaredPath
    }
    else {
        # Linux install logic (simplified)
        Write-ScriptLog "Please install cloudflared manually on Linux or ensure it's in PATH."
        exit 1
    }
}

Write-ScriptLog "Using Cloudflared: $cfCmd"
Write-ScriptLog "Starting Cloudflare Tunnel..."
# Start tunnel and capture output to find the URL
$tunnelProcess = Start-Process -FilePath $cfCmd -ArgumentList "tunnel --url http://localhost:$Port" -PassThru -RedirectStandardOutput "tunnel.log" -RedirectStandardError "tunnel.err"

Write-ScriptLog "Tunnel started with PID: $($tunnelProcess.Id)"
Write-ScriptLog "Waiting for URL generation (checking tunnel.err)..."

# Poll the error log (where cloudflared prints the URL)
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    if (Test-Path "tunnel.err") {
        $logContent = Get-Content "tunnel.err" -Tail 50
        $match = $logContent | Select-String "https://.*\.trycloudflare\.com"
        if ($match) {
            $url = $match.Matches.Value
            Write-Host "`n=======================================================" -ForegroundColor Green
            Write-Host " GATEWAY URL: $url" -ForegroundColor Cyan
            Write-Host "=======================================================" -ForegroundColor Green
            Write-ScriptLog "Tunnel URL found: $url"

            # Save to a file for the Agent to potentially read if shared
            $url | Out-File "gateway_url.txt" -Force
            break
        }
    }
}

if (-not $url) {
    Write-ScriptLog "Could not retrieve Tunnel URL. Check tunnel.err for details." "Warning"
}

Write-ScriptLog "Press Ctrl+C to stop the gateway (ComfyUI + Tunnel)."
try {
    while ($true) { Start-Sleep -Seconds 1 }
}
finally {
    Write-ScriptLog "Stopping processes..."
    Stop-Process -Id $comfyProcess.Id -ErrorAction SilentlyContinue
    Stop-Process -Id $tunnelProcess.Id -ErrorAction SilentlyContinue
}
