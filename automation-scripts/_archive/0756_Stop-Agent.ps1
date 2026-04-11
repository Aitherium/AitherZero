<#
.SYNOPSIS
    Stops an AitherOS agent.

.DESCRIPTION
    Stops the specified agent by killing its process.

.PARAMETER AgentId
    The ID (folder name) of the agent to stop.

.EXAMPLE
    ./0756_Stop-Agent.ps1 -AgentId NarrativeAgent
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$AgentId
)

$ErrorActionPreference = "Stop"

Write-Host "Stopping Agent '$AgentId'..."

$PidsToKill = @()

if ($IsWindows) {
    $Procs = Get-CimInstance Win32_Process -Filter "CommandLine like '%$AgentId%'" -ErrorAction SilentlyContinue
    foreach ($p in $Procs) {
        $PidsToKill += $p.ProcessId
    }
} else {
    $Procs = Get-Process | Where-Object { $_.ProcessName -eq "python" -or $_.ProcessName -eq "python3" } | Where-Object { $_.CommandLine -like "*$AgentId*" }
    foreach ($p in $Procs) {
        $PidsToKill += $p.Id
    }
}

if ($PidsToKill.Count -eq 0) {
    Write-Warning "No running processes found for agent '$AgentId'."
    exit 0
}

foreach ($PidToKill in $PidsToKill) {
    Write-Host "Killing PID $PidToKill..."
    Stop-Process -Id $PidToKill -Force -ErrorAction SilentlyContinue
}

Write-Host "Agent stopped." -ForegroundColor Green
