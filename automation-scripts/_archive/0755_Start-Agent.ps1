<#
.SYNOPSIS
    Starts an AitherOS agent.

.DESCRIPTION
    Starts the specified agent by running its agent.py file.
    Uses the agent's virtual environment if available.

.PARAMETER AgentId
    The ID (folder name) of the agent to start.

.EXAMPLE
    ./0755_Start-Agent.ps1 -AgentId NarrativeAgent
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$AgentId
)

$ErrorActionPreference = "Stop"

# Resolve Paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot = Resolve-Path "$ScriptDir/../../.."
$AgentDir = Join-Path $RepoRoot "AitherOS/agents/$AgentId"

if (-not (Test-Path $AgentDir)) {
    Write-Error "Agent directory not found: $AgentDir"
    exit 1
}

$AgentScript = Join-Path $AgentDir "agent.py"
if (-not (Test-Path $AgentScript)) {
    Write-Error "Agent script not found: $AgentScript"
    exit 1
}

# Determine Python Executable
$VenvPath = Join-Path $AgentDir ".venv"
$PythonExe = "python"

if (Test-Path $VenvPath) {
    if ($IsWindows) {
        $PythonExe = Join-Path $VenvPath "Scripts/python.exe"
    } else {
        $PythonExe = Join-Path $VenvPath "bin/python"
    }
} elseif (Test-Path (Join-Path $RepoRoot "AitherOS/agents/NarrativeAgent/.venv")) {
    # Fallback to shared venv
    $VenvPath = Join-Path $RepoRoot "AitherOS/agents/NarrativeAgent/.venv"
    if ($IsWindows) {
        $PythonExe = Join-Path $VenvPath "Scripts/python.exe"
    } else {
        $PythonExe = Join-Path $VenvPath "bin/python"
    }
}

Write-Host "Starting Agent '$AgentId'..."
Write-Host "Script: $AgentScript"
Write-Host "Python: $PythonExe"

# Start in background
Start-Process -FilePath $PythonExe -ArgumentList $AgentScript -WorkingDirectory $AgentDir -WindowStyle Hidden

Write-Host "Agent start command issued." -ForegroundColor Green
