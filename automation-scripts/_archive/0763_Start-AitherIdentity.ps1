<#
.SYNOPSIS
    Starts the AitherIdentity service.

.DESCRIPTION
    Starts the AitherIdentity service (Unified Identity & Access Management) on port 8112.
    This service integrates AitherRBAC and AitherSecrets.

.PARAMETER Background
    Run in background (default: $true)

.PARAMETER ShowOutput
    Show output in new window (default: $false)

.EXAMPLE
    ./0763_Start-AitherIdentity.ps1
#>

[CmdletBinding()]
param(
    [switch]$Background = $true,
    [switch]$ShowOutput = $false
)

. "$PSScriptRoot/_init.ps1"

$ServiceName = "AitherIdentity"
$ScriptPath = "$env:AITHERZERO_ROOT/AitherOS/AitherNode/AitherIdentity.py"
$Port = 8112

Write-Host "Starting $ServiceName on port $Port..." -ForegroundColor Cyan

# Ensure dependencies are running (Secrets is critical)
if (-not (Test-NetConnection -ComputerName localhost -Port 8111 -InformationLevel Quiet)) {
    Write-Warning "AitherSecrets (8111) is not running. Starting it..."
    Start-Process "pwsh" -ArgumentList "-File", "$PSScriptRoot/0762_Start-AitherSecrets.ps1" -NoNewWindow -Wait
}

# Start the service
$AgentVenv = "$env:AITHERZERO_ROOT/AitherOS/agents/NarrativeAgent/.venv/Scripts/python.exe"

if (-not (Test-Path $AgentVenv)) {
    Write-Error "Python environment not found at $AgentVenv"
    exit 1
}

if ($Background) {
    if ($ShowOutput) {
        Start-Process $AgentVenv -ArgumentList $ScriptPath -NoNewWindow
    } else {
        Start-Process $AgentVenv -ArgumentList $ScriptPath -WindowStyle Hidden
    }
    Write-Host "$ServiceName started in background." -ForegroundColor Green
} else {
    & $AgentVenv $ScriptPath
}
