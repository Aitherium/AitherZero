<#
.SYNOPSIS
    Installs or removes a Windows Scheduled Task to keep AitherWatch running.

.DESCRIPTION
    Creates a scheduled task that checks every 60 seconds if AitherWatch is running.
    If not running, it automatically starts the watchdog service.
    This ensures AitherWatch is always available as the system's health monitor.

.PARAMETER Action
    Action to perform: Install, Remove, or Status

.PARAMETER CheckInterval
    How often to check if AitherWatch is running (in seconds). Default: 60

.EXAMPLE
    # Install the scheduled task
    .\0770_Manage-AitherWatchTask.ps1 -Action Install

.EXAMPLE
    # Remove the scheduled task
    .\0770_Manage-AitherWatchTask.ps1 -Action Remove

.EXAMPLE
    # Check task status
    .\0770_Manage-AitherWatchTask.ps1 -Action Status

.NOTES
    Script Number: 0770
    Category: Infrastructure
    MCP Usage: execute_aither_script with script_number "0770" and arguments { "action": "Install" }
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Install", "Remove", "Status")]
    [string]$Action = "Status",

    [Parameter(Mandatory = $false)]
    [int]$CheckInterval = 60
)

$ErrorActionPreference = "Stop"

# Configuration
$TaskName = "AitherWatch-Watchdog"
$TaskDescription = "Ensures AitherWatch watchdog service is always running. Checks every $CheckInterval seconds."
$AitherZeroRoot = $env:AITHERZERO_ROOT
if (-not $AitherZeroRoot) {
    $AitherZeroRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
}

$PythonExe = Join-Path $AitherZeroRoot "AitherOS\agents\NarrativeAgent\.venv\Scripts\python.exe"
$AitherWatchScript = Join-Path $AitherZeroRoot "AitherOS\AitherNode\AitherWatch.py"
$LogFile = Join-Path $AitherZeroRoot "logs\AitherWatch-task.log"

# Ensure logs directory exists
$LogDir = Split-Path $LogFile -Parent
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage
    Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
}

function Test-AitherWatchRunning {
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:8082/health" -TimeoutSec 5 -ErrorAction Stop
        return $response.status -eq "healthy"
    } catch {
        return $false
    }
}

function Install-AitherWatchTask {
    Write-Log "Installing AitherWatch scheduled task..."

    # Check if task already exists
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log "Task already exists. Removing old task first..."
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    # Create the PowerShell script that the task will run
    $CheckerScript = @"
# AitherWatch Health Check Script
`$ErrorActionPreference = 'SilentlyContinue'
`$logFile = '$LogFile'

function Write-TaskLog {
    param([string]`$Message)
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path `$logFile -Value "[`$timestamp] `$Message"
}

try {
    `$response = Invoke-RestMethod -Uri 'http://localhost:8082/health' -TimeoutSec 5
    if (`$response.status -eq 'healthy') {
        # AitherWatch is running, all good
        exit 0
    }
} catch {
    # AitherWatch is not responding, start it
    Write-TaskLog 'AitherWatch not responding, starting...'
    
    `$pythonExe = '$PythonExe'
    `$scriptPath = '$AitherWatchScript'
    `$workDir = '$AitherZeroRoot\AitherOS\AitherNode'
    
    Start-Process -FilePath `$pythonExe -ArgumentList `$scriptPath -WorkingDirectory `$workDir -WindowStyle Hidden
    Write-TaskLog 'AitherWatch start command executed'
}
"@

    $CheckerScriptPath = Join-Path $AitherZeroRoot "AitherZero\library\automation-scripts\helpers\Check-AitherWatch.ps1"
    $CheckerScriptDir = Split-Path $CheckerScriptPath -Parent
    if (-not (Test-Path $CheckerScriptDir)) {
        New-Item -ItemType Directory -Path $CheckerScriptDir -Force | Out-Null
    }
    Set-Content -Path $CheckerScriptPath -Value $CheckerScript -Force

    # Create the scheduled task
    $Action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$CheckerScriptPath`""
    
    # Trigger: Every X seconds (using repetition on a daily trigger)
    $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Seconds $CheckInterval)
    
    # Settings
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false -MultipleInstances IgnoreNew

    # Principal (run as current user)
    $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest

    # Register the task
    Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null

    Write-Log "Scheduled task '$TaskName' installed successfully!"
    Write-Log "Check interval: $CheckInterval seconds"
    Write-Log "Checker script: $CheckerScriptPath"
    
    return @{
        Success = $true
        TaskName = $TaskName
        CheckInterval = $CheckInterval
        Message = "AitherWatch watchdog task installed. Will check every $CheckInterval seconds."
    }
}

function Remove-AitherWatchTask {
    Write-Log "Removing AitherWatch scheduled task..."

    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existingTask) {
        Write-Log "Task '$TaskName' does not exist."
        return @{
            Success = $true
            Message = "Task was not installed."
        }
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Log "Scheduled task '$TaskName' removed successfully!"
    
    return @{
        Success = $true
        Message = "AitherWatch watchdog task removed."
    }
}

function Get-AitherWatchTaskStatus {
    Write-Log "Checking AitherWatch scheduled task status..."

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $eyesRunning = Test-AitherWatchRunning

    if (-not $task) {
        return @{
            TaskInstalled = $false
            TaskState = "NotInstalled"
            AitherWatchRunning = $eyesRunning
            Message = "Scheduled task is not installed. AitherWatch is $(if ($eyesRunning) { 'running' } else { 'not running' })."
        }
    }

    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue

    return @{
        TaskInstalled = $true
        TaskState = $task.State.ToString()
        LastRunTime = if ($taskInfo.LastRunTime) { $taskInfo.LastRunTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
        NextRunTime = if ($taskInfo.NextRunTime) { $taskInfo.NextRunTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Unknown" }
        LastResult = $taskInfo.LastTaskResult
        AitherWatchRunning = $eyesRunning
        Message = "Task is $($task.State). AitherWatch is $(if ($eyesRunning) { 'running' } else { 'not running' })."
    }
}

# Main execution
switch ($Action) {
    "Install" {
        $result = Install-AitherWatchTask
    }
    "Remove" {
        $result = Remove-AitherWatchTask
    }
    "Status" {
        $result = Get-AitherWatchTaskStatus
    }
}

# Output result
$result | ConvertTo-Json -Depth 3
