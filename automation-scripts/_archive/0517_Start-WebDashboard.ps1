#Requires -Version 7.0

<#
.SYNOPSIS
    Starts the AitherZero Web Dashboard (Next.js).
.DESCRIPTION
    Checks for Node.js, installs dependencies if missing, and starts the Next.js development server.
    The dashboard provides a web-based interface for AitherZero.
.NOTES
    Stage: Reporting
    Order: 0517
    Tags: dashboard, web, nextjs, ui
#>

[CmdletBinding()]
param(
    [switch]$InstallOnly,
    [switch]$Build,
    [switch]$StartProduction,
    [switch]$WithPulse
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Helper for logging
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Level $Level -Message $Message -Source "StartWebDashboard"
    } else {
        $color = switch ($Level) {
            'Error' { 'Red' }
            'Warning' { 'Yellow' }
            'Success' { 'Green' }
            default { 'Cyan' }
        }
        Write-Host "[$Level] $Message" -ForegroundColor $color
    }
}

# Start AitherPulse if requested
if ($WithPulse) {
    Write-ScriptLog "Starting AitherPulse background service..."
    $pulseScript = Join-Path $PSScriptRoot "0530_Start-AitherPulse.ps1"
    if (Test-Path $pulseScript) {
        Start-Process pwsh -ArgumentList "-File `"$pulseScript`"" -WindowStyle Hidden
        Write-ScriptLog "AitherPulse started." -Level Success
    } else {
        Write-ScriptLog "AitherPulse script not found at $pulseScript" -Level Warning
    }
}

# 1. Check Prerequisites
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-ScriptLog "Node.js is not installed or not in PATH." -Level Error
    Write-Host "Please install Node.js (LTS recommended) to run the Web Dashboard." -ForegroundColor Yellow
    exit 1
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-ScriptLog "npm is not installed or not in PATH." -Level Error
    exit 1
}

# 2. Locate Dashboard Directory
$dashboardPath = Join-Path $PSScriptRoot "../../integrations/AitherZero-WebDash"
$dashboardPath = $dashboardPath | Resolve-Path

if (-not (Test-Path $dashboardPath)) {
    Write-ScriptLog "Web Dashboard directory not found at: $dashboardPath" -Level Error
    exit 1
}

Write-ScriptLog "Found Web Dashboard at: $dashboardPath"

# 3. Install Dependencies
Push-Location $dashboardPath
try {
    if (-not (Test-Path "node_modules") -or (Test-Path "package-lock.json" -NewerThan "node_modules")) {
        Write-ScriptLog "Installing Node.js dependencies..."
        npm install
        if ($LASTEXITCODE -ne 0) {
            throw "npm install failed with exit code $LASTEXITCODE"
        }
        Write-ScriptLog "Dependencies installed successfully." -Level Success
    } else {
        Write-ScriptLog "Dependencies appear up to date."
    }

    if ($InstallOnly) {
        return
    }

    # 4. Build (Optional)
    if ($Build -or $StartProduction) {
        Write-ScriptLog "Building Next.js application..."
        npm run build
        if ($LASTEXITCODE -ne 0) {
            throw "npm run build failed"
        }
        Write-ScriptLog "Build complete." -Level Success
    }

    # 5. Start Server
    if ($StartProduction) {
        Write-ScriptLog "Starting Web Dashboard (Production)..."
        npm start
    } else {
        Write-ScriptLog "Starting Web Dashboard (Development)..."
        Write-Host "Press Ctrl+C to stop the server." -ForegroundColor Yellow
        npm run dev
    }
}
catch {
    Write-ScriptLog "Error starting Web Dashboard: $_" -Level Error
    exit 1
}
finally {
    Pop-Location
}
