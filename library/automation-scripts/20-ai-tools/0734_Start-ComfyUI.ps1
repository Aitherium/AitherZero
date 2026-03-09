#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: Python
# Description: Starts the ComfyUI server
# Tags: ai, comfyui, server

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallPath,

    [Parameter()]
    [switch]$Listen,

    [Parameter()]
    [string]$Port = "8188"
)

. "$PSScriptRoot/_init.ps1"

# Set default InstallPath if not provided
if ([string]::IsNullOrEmpty($InstallPath)) {
    if ($IsWindows) {
        # Auto-detect ComfyUI location
        $PossiblePaths = @("E:\ComfyUI", "D:\ComfyUI", "C:\ComfyUI", "$env:USERPROFILE\ComfyUI")
        foreach ($path in $PossiblePaths) {
            if (Test-Path $path) {
                $InstallPath = $path
                Write-Host "Auto-detected ComfyUI at: $InstallPath" -ForegroundColor Cyan
                break
            }
        }
        # Fallback
        if ([string]::IsNullOrEmpty($InstallPath)) {
            if (Test-Path "E:") {
                $InstallPath = "E:\ComfyUI"
            }
            elseif (Test-Path "D:") {
                $InstallPath = "D:\ComfyUI"
            }
            else {
                $InstallPath = "C:\ComfyUI"
            }
        }
    }
    else {
        $InstallPath = Join-Path $env:HOME "ComfyUI"
    }
}

if (-not (Test-Path $InstallPath)) {
    Write-Error "ComfyUI directory not found at $InstallPath"
    exit 1
}

$venvPython = if ($IsWindows) { Join-Path $InstallPath "venv\Scripts\python.exe" } else { Join-Path $InstallPath "venv/bin/python" }
$mainPy = Join-Path $InstallPath "main.py"

if (-not (Test-Path $venvPython)) {
    Write-Error "Python venv not found at $venvPython"
    exit 1
}

$argsList = @($mainPy)
if ($Listen) { $argsList += "--listen" }
if ($Port) { $argsList += "--port"; $argsList += $Port }

Write-Host "Starting ComfyUI..." -ForegroundColor Green
Write-Host "Command: $venvPython $argsList" -ForegroundColor DarkGray

& $venvPython @argsList
