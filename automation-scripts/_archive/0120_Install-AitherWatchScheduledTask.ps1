<#
.SYNOPSIS
    Installs a Windows Scheduled Task to ensure AitherWatch watchdog stays running.

.DESCRIPTION
    Creates a scheduled task that checks every 60 seconds if AitherWatch is running.
    If not running, it automatically starts AitherWatch to ensure the watchdog never stays down.
    
    This is the "watchdog for the watchdog" - the ultimate failsafe.

.PARAMETER Action
    The action to perform: Install, Uninstall, Status, or Test.
    Default: Install

.PARAMETER CheckInterval
    How often to check if AitherWatch is running (in seconds).
    Default: 60

.PARAMETER TaskName
    Name of the scheduled task.
    Default: AitherWatch-Watchdog

.EXAMPLE
    .\0120_Install-AitherWatchScheduledTask.ps1 -Action Install
    
.EXAMPLE
    .\0120_Install-AitherWatchScheduledTask.ps1 -Action Uninstall

.EXAMPLE
    .\0120_Install-AitherWatchScheduledTask.ps1 -Action Status

.NOTES
    Script ID: 0120
    Category: Infrastructure
    Requires: Administrator privileges for task installation
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Install', 'Uninstall', 'Status', 'Test')]
    [string]$Action = 'Install',

    [Parameter()]
    [int]$CheckInterval = 60,

    [Parameter()]
    [string]$TaskName = 'AitherWatch-Watchdog'
)

# Determine paths
$ScriptRoot = if ($env:AITHERZERO_ROOT) { $env:AITHERZERO_ROOT } else { Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) }
$AitherNodeDir = Join-Path $ScriptRoot "AitherOS" "AitherNode"
$VenvPython = Join-Path $ScriptRoot "AitherOS" "agents" "NarrativeAgent" ".venv" "Scripts" "python.exe"
$AitherWatchScript = Join-Path $AitherNodeDir "AitherWatch.py"
$LogDir = Join-Path $ScriptRoot "logs"
$WatchdogScript = Join-Path $ScriptRoot "AitherZero" "library" "automation-scripts" "helpers" "Start-AitherWatchIfStopped.ps1"

# Ensure log directory exists
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path (Join-Path $LogDir "AitherWatch-task.log") -Value $logMessage -ErrorAction SilentlyContinue
}

function Test-AitherWatchRunning {
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:8082/health" -TimeoutSec 5 -ErrorAction Stop
        return $response.status -eq "healthy"
    } catch {
        return $false
    }
}

function Install-WatchdogTask {
    Write-Log "Installing AitherWatch Watchdog scheduled task..."
    
    # Create the helper script that will be run by the task
    $helperDir = Split-Path -Parent $WatchdogScript
    if (-not (Test-Path $helperDir)) {
        New-Item -ItemType Directory -Path $helperDir -Force | Out-Null
    }

    $helperContent = @"
# AitherWatch Watchdog Helper Script
# This script is run by Windows Task Scheduler to ensure AitherWatch stays running

`$ErrorActionPreference = 'SilentlyContinue'
`$ScriptRoot = "$ScriptRoot"
`$VenvPython = "$VenvPython"
`$AitherWatchScript = "$AitherWatchScript"
`$LogFile = "$LogDir\AitherWatch-watchdog.log"

function Write-WatchdogLog {
    param([string]`$Message)
    `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path `$LogFile -Value "[`$timestamp] `$Message"
}

# Check if AitherWatch is responding
try {
    `$response = Invoke-RestMethod -Uri "http://localhost:8082/health" -TimeoutSec 5 -ErrorAction Stop
    if (`$response.status -eq "healthy") {
        # AitherWatch is running, nothing to do
        exit 0
    }
} catch {
    # AitherWatch is not responding, need to start it
    Write-WatchdogLog "AitherWatch not responding, attempting to start..."
}

# Check if process exists but not responding
`$existingProcess = Get-Process -Name "python" -ErrorAction SilentlyContinue | Where-Object {
    `$_.CommandLine -like "*AitherWatch*"
}

if (`$existingProcess) {
    Write-WatchdogLog "Found unresponsive AitherWatch process (PID: `$(`$existingProcess.Id)), terminating..."
    Stop-Process -Id `$existingProcess.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Start AitherWatch
Write-WatchdogLog "Starting AitherWatch..."
try {
    Start-Process -FilePath `$VenvPython -ArgumentList "`"`$AitherWatchScript`"" -WorkingDirectory (Split-Path `$AitherWatchScript) -WindowStyle Hidden
    Write-WatchdogLog "AitherWatch start command issued"
    
    # Wait and verify
    Start-Sleep -Seconds 10
    try {
        `$response = Invoke-RestMethod -Uri "http://localhost:8082/health" -TimeoutSec 5 -ErrorAction Stop
        if (`$response.status -eq "healthy") {
            Write-WatchdogLog "AitherWatch started successfully"
        } else {
            Write-WatchdogLog "AitherWatch started but not healthy: `$(`$response | ConvertTo-Json -Compress)"
        }
    } catch {
        Write-WatchdogLog "AitherWatch failed to respond after start: `$_"
    }
} catch {
    Write-WatchdogLog "Failed to start AitherWatch: `$_"
}
"@

    Set-Content -Path $WatchdogScript -Value $helperContent -Force
    Write-Log "Created helper script at: $WatchdogScript"

    # Check for admin rights
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Log "WARNING: Not running as administrator. Task installation may fail." "WARN"
        Write-Log "Please run this script as administrator to install the scheduled task." "WARN"
    }

    # Remove existing task if present
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log "Removing existing task..."
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    # Create the scheduled task
    try {
        $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$WatchdogScript`""
        
        # Trigger every X seconds using repetition
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Seconds $CheckInterval)
        
        # Run whether user is logged in or not, run with highest privileges
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        
        # Settings
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        
        $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Monitors AitherWatch watchdog service and restarts it if stopped. Checks every $CheckInterval seconds."
        
        Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
        
        Write-Log "Scheduled task '$TaskName' installed successfully!" "SUCCESS"
        Write-Log "AitherWatch will be checked every $CheckInterval seconds and restarted if not running."
        
        # Return success object
        return @{
            Success = $true
            TaskName = $TaskName
            CheckInterval = $CheckInterval
            HelperScript = $WatchdogScript
            Message = "Scheduled task installed successfully"
        }
    } catch {
        Write-Log "Failed to create scheduled task: $_" "ERROR"
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Uninstall-WatchdogTask {
    Write-Log "Uninstalling AitherWatch Watchdog scheduled task..."
    
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Log "Scheduled task '$TaskName' removed successfully!" "SUCCESS"
            
            # Also remove helper script
            if (Test-Path $WatchdogScript) {
                Remove-Item $WatchdogScript -Force
                Write-Log "Removed helper script"
            }
            
            return @{
                Success = $true
                Message = "Scheduled task uninstalled successfully"
            }
        } catch {
            Write-Log "Failed to remove scheduled task: $_" "ERROR"
            return @{
                Success = $false
                Error = $_.Exception.Message
            }
        }
    } else {
        Write-Log "Scheduled task '$TaskName' not found" "WARN"
        return @{
            Success = $true
            Message = "Task was not installed"
        }
    }
}

function Get-WatchdogStatus {
    Write-Log "Checking AitherWatch Watchdog scheduled task status..."
    
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $eyesRunning = Test-AitherWatchRunning
    
    if ($task) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        
        $status = @{
            TaskInstalled = $true
            TaskName = $TaskName
            TaskState = $task.State.ToString()
            LastRunTime = if ($taskInfo.LastRunTime) { $taskInfo.LastRunTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
            LastResult = $taskInfo.LastTaskResult
            NextRunTime = if ($taskInfo.NextRunTime) { $taskInfo.NextRunTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }
            AitherWatchRunning = $eyesRunning
            HelperScriptExists = Test-Path $WatchdogScript
        }
        
        Write-Log "Task State: $($status.TaskState)"
        Write-Log "Last Run: $($status.LastRunTime)"
        Write-Log "AitherWatch Running: $eyesRunning"
        
        return $status
    } else {
        Write-Log "Scheduled task not installed" "WARN"
        return @{
            TaskInstalled = $false
            TaskName = $TaskName
            AitherWatchRunning = $eyesRunning
        }
    }
}

function Test-WatchdogTask {
    Write-Log "Testing watchdog functionality..."
    
    # Check if AitherWatch is running
    $running = Test-AitherWatchRunning
    Write-Log "AitherWatch currently running: $running"
    
    # Check if helper script exists
    $helperExists = Test-Path $WatchdogScript
    Write-Log "Helper script exists: $helperExists"
    
    # Check task status
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $taskInstalled = $null -ne $task
    Write-Log "Scheduled task installed: $taskInstalled"
    
    if ($helperExists) {
        Write-Log "Running helper script manually for testing..."
        try {
            & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $WatchdogScript
            Write-Log "Helper script executed successfully"
        } catch {
            Write-Log "Helper script execution failed: $_" "ERROR"
        }
    }
    
    return @{
        AitherWatchRunning = $running
        HelperScriptExists = $helperExists
        TaskInstalled = $taskInstalled
        TestComplete = $true
    }
}

# Main execution
switch ($Action) {
    'Install' {
        $result = Install-WatchdogTask
    }
    'Uninstall' {
        $result = Uninstall-WatchdogTask
    }
    'Status' {
        $result = Get-WatchdogStatus
    }
    'Test' {
        $result = Test-WatchdogTask
    }
}

# Output result as JSON for MCP consumption
$result | ConvertTo-Json -Depth 3
