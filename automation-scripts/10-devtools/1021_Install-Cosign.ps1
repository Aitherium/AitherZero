#Requires -Version 7.0

<#
.SYNOPSIS
    Install Sigstore Cosign
.DESCRIPTION
    Installs the Cosign signing tool for container image signing.
    Supports Windows (winget), Linux (binary download), macOS (brew).
.EXAMPLE
    ./1021_Install-Cosign.ps1
.NOTES
    Stage: Development Tools
    Dependencies: None
    Tags: security, signing, containers, cosign
#>

[CmdletBinding()]
param(
    [switch]$Force
)

# Common helper or just inline logic
function Get-LatestCosignVersion {
    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/sigstore/cosign/releases/latest"
        return $release.tag_name
    } catch {
        Write-Warning "Could not fetch latest version, falling back to v2.4.1"
        return "v2.4.1"
    }
}

$ErrorActionPreference = "Stop"

Write-Host "Installing Cosign..." -ForegroundColor Cyan

if (Get-Command cosign -ErrorAction SilentlyContinue) {
    if (-not $Force) {
        $v = cosign version 2>&1 | Select-Object -First 1
        Write-Host "Cosign is already installed: $v" -ForegroundColor Green
        exit 0
    }
    Write-Host "Reinstalling..." -ForegroundColor Yellow
}

if ($IsWindows) {
    Write-Host "Installing via Winget..."
    winget install Sigstore.Cosign -e --silent --accept-source-agreements --accept-package-agreements
    
    # Refresh environment variables to pick up new PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
elseif ($IsLinux) {
    Write-Host "Installing via binary download..."
    $version = Get-LatestCosignVersion
    $url = "https://github.com/sigstore/cosign/releases/download/$version/cosign-linux-amd64"
    $dest = "/usr/local/bin/cosign"
    
    # Check permissions (need sudo?)
    if ([System.Environment]::UserName -ne "root") {
        Write-Host "Requesting sudo permissions to write to $dest..." -ForegroundColor Yellow
        sudo curl -L -o $dest $url
        sudo chmod +x $dest
    } else {
        curl -L -o $dest $url
        chmod +x $dest
    }
}
elseif ($IsMacOS) {
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        Write-Host "Installing via Homebrew..."
        brew install cosign
    } else {
        Write-Error "Homebrew not found. Please install Homebrew first."
        exit 1
    }
}

# Verify
if (Get-Command cosign -ErrorAction SilentlyContinue) {
    $v = cosign version 2>&1 | Select-Object -First 1
    Write-Host "Cosign installed successfully: $v" -ForegroundColor Green
} else {
    Write-Warning "Cosign command not found in current session. You may need to restart your shell."
    if ($IsWindows) {
        if (Test-Path "$env:ProgramFiles\Cosign\cosign.exe") {
             Write-Host "Binary found at: $env:ProgramFiles\Cosign\cosign.exe" -ForegroundColor Green
        }
    }
}
