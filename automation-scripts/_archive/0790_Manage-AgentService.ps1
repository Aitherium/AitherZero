<#
.SYNOPSIS
    Manages AitherZero Agents as background system services (Scheduled Tasks).

.DESCRIPTION
    Installs or removes AitherZero Agents as persistent background tasks.
    Uses Windows Task Scheduler to ensure the agent runs at startup/logon.
    
    The agent runs in "Persistent Mode" (--persistent), exposing an HTTP server
    that accepts prompts via POST requests.

.PARAMETER Action
    "Install" or "Uninstall". Default is "Install".

.PARAMETER AgentName
    The name of the agent to manage.
    Options: "NarrativeAgent", "InfrastructureAgent", "AitherZeroAutomationAgent".
    Default: "NarrativeAgent".

.PARAMETER Port
    The port for the agent server to listen on.
    Defaults:
    - NarrativeAgent: 8001
    - InfrastructureAgent: 8002
    - AitherZeroAutomationAgent: 8003

.PARAMETER Model
    The model to use (e.g., "mistral-nemo", "gemini-2.5-flash"). Default is "mistral-nemo".

.EXAMPLE
    .\0790_Manage-AgentService.ps1 -Action Install -AgentName InfrastructureAgent
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("Install", "Uninstall", "Status", "Start", "Stop")]
    [string]$Action = "Install",

    [Parameter(Mandatory=$false)]
    [ValidateSet("NarrativeAgent", "InfrastructureAgent", "AitherZeroAutomationAgent")]
    [string]$AgentName = "NarrativeAgent",

    [Parameter(Mandatory=$false)]
    [int]$Port,

    [Parameter(Mandatory=$false)]
    [string]$Model = "mistral-nemo"
)

# Default Port Logic
if (-not $PSBoundParameters.ContainsKey('Port')) {
    switch ($AgentName) {
        "NarrativeAgent" { $Port = 8001 }
        "InfrastructureAgent" { $Port = 8002 }
        "AitherZeroAutomationAgent" { $Port = 8003 }
        Default { $Port = 8001 }
    }
}

$TaskName = "AitherAgent-$AgentName"
$AgentScript = Join-Path "$PSScriptRoot\..\..\..\AitherOS\agents\$AgentName" "agent.py"
$AgentDir = Split-Path $AgentScript -Parent

# Validate Agent Script Exists
if (-not (Test-Path $AgentScript)) {
    Write-Error "Agent script not found at: $AgentScript"
    exit 1
}

# Resolve Python Path
# Try to find the agent's specific venv python first
$VenvPython = Join-Path $AgentDir ".venv\Scripts\python.exe"
if (Test-Path $VenvPython) {
    $PythonPath = $VenvPython
    Write-Host "Using Agent Virtual Environment: $PythonPath" -ForegroundColor Gray
} else {
    # Fallback to global python
    $PythonPath = (Get-Command "py.exe" -ErrorAction SilentlyContinue).Source
    if (-not $PythonPath) {
        $PythonPath = (Get-Command "python.exe" -ErrorAction SilentlyContinue).Source
    }
    Write-Host "Using Global Python: $PythonPath" -ForegroundColor Yellow
}

if (-not $PythonPath) {
    Write-Error "Python executable not found."
    exit 1
}

function Get-TaskStatus {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        return $task.State
    }
    return "NotInstalled"
}

if ($Action -eq "Status") {
    $status = Get-TaskStatus
    Write-Host "Agent Service ($AgentName) Status: $status" -ForegroundColor Cyan
    if ($status -eq "Running") {
        Write-Host "Listening on port: $Port" -ForegroundColor Gray
    }
    exit 0
}

if ($Action -eq "Stop") {
    Write-Host "Stopping $TaskName..." -ForegroundColor Yellow
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    exit 0
}

if ($Action -eq "Start") {
    Write-Host "Starting $TaskName..." -ForegroundColor Green
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    exit 0
}

if ($Action -eq "Uninstall") {
    Write-Host "Removing $TaskName service..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Successfully removed." -ForegroundColor Green
    exit 0
}

if ($Action -eq "Install") {
    Write-Host "Installing $AgentName as a background service ($TaskName)..." -ForegroundColor Cyan
    
    # Arguments for the agent
    $ArgList = "`"$AgentScript`" --persistent --port $Port --model $Model"
    
    # Create Action
    $ActionObj = New-ScheduledTaskAction -Execute $PythonPath -Argument $ArgList -WorkingDirectory $AgentDir
    
    # Create Trigger (AtLogon is safer for user-context apps like Ollama)
    $Trigger = New-ScheduledTaskTrigger -AtLogon
    
    # Create Settings (Allow running on demand, restart if fails)
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 365)
    
    # Register Task
    # Run as current user to access local Ollama and User Profile
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $ActionObj -Trigger $Trigger -Settings $Settings -User $env:USERNAME -Force | Out-Null
        
        Write-Host "Service registered successfully!" -ForegroundColor Green
        Write-Host "Starting service now..." -ForegroundColor Cyan
        Start-ScheduledTask -TaskName $TaskName
        
        Write-Host "$AgentName is running on port $Port." -ForegroundColor Green
        Write-Host "You can now use: py agent.py --prompt 'Hello'" -ForegroundColor Gray
    }
    catch {
        Write-Error "Failed to register task: $_"
        Write-Host "Try running this script as Administrator." -ForegroundColor Red
    }
}
