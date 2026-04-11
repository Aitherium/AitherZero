<#
.SYNOPSIS
    Watches AitherReasoning thinking traces in real-time.

.DESCRIPTION
    Connects to the AitherReasoning WebSocket and streams agent thoughts to the console.
    Requires the NarrativeAgent virtual environment.

.EXAMPLE
    ./0990_Watch-Reasoning.ps1
#>

[CmdletBinding()]
param(
    [string]$HostName = "localhost",
    [int]$Port = 8093
)

$ErrorActionPreference = "Stop"

# Initialize AitherZero environment
$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = "." }
. "$ScriptRoot/_init.ps1"

Write-Host "🧠 Starting Reasoning Watcher..." -ForegroundColor Cyan

# Path to Python executable in NarrativeAgent venv
$PythonPath = "$env:AITHERZERO_ROOT/AitherOS/agents/NarrativeAgent/.venv/Scripts/python.exe"
$ScriptPath = "$env:AITHERZERO_ROOT/AitherOS/AitherNode/tools/watch_reasoning.py"

if (-not (Test-Path $PythonPath)) {
    Write-Error "Python environment not found at $PythonPath"
    exit 1
}

if (-not (Test-Path $ScriptPath)) {
    Write-Error "Watch script not found at $ScriptPath"
    exit 1
}

# Run the python script
& $PythonPath $ScriptPath --host $HostName --port $Port
