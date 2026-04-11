<#
.SYNOPSIS
    Invokes an AitherOS agent with a specific instruction.
.DESCRIPTION
    Runs the async_runner.py script to execute an agent task.
    The result is written to the agent's mailbox.
.EXAMPLE
    ./0757_Invoke-Agent.ps1 -AgentName "CoderAgent" -Prompt "Write a hello world script"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AgentName,

    [Parameter(Mandatory=$true)]
    [string]$Prompt,

    [string]$Model = "gemini-2.5-flash",

    [Parameter()]
    [switch]$ShowOutput,

    [Parameter()]
    [switch]$AsJson
)

$ErrorActionPreference = "Stop"

# Resolve paths
$RepoRoot = Resolve-Path "$PSScriptRoot/../../.."
$AgentDir = Join-Path $RepoRoot "AitherOS/agents/NarrativeAgent"
$RunnerScript = Join-Path $AgentDir "async_runner.py"
$MailboxPath = Join-Path $AgentDir "mailbox.json"

# Determine Python executable
if ($IsWindows) {
    $PythonExe = Join-Path $AgentDir ".venv/Scripts/python.exe"
} else {
    $PythonExe = Join-Path $AgentDir ".venv/bin/python"
}

if (-not (Test-Path $PythonExe)) {
    # Fallback to system python if venv not found (dev environment)
    $PythonExe = "python"
}

if (-not (Test-Path $RunnerScript)) {
    Write-Error "Runner script not found at $RunnerScript"
}

Write-Verbose "Invoking $AgentName with model $Model..."

# Run the python script
$Process = Start-Process -FilePath $PythonExe -ArgumentList @(
    $RunnerScript,
    "--agent", $AgentName,
    "--instruction", $Prompt,
    "--model", $Model,
    "--mailbox", $MailboxPath
) -Wait -NoNewWindow -PassThru

$result = @{
    success = $false
    message = ""
    content = ""
}

if ($Process.ExitCode -eq 0) {
    Write-Verbose "Agent task completed successfully."
    $result.success = $true
    $result.message = "Task executed"
    
    # Optional: Read the last message from mailbox to show as output
    if (Test-Path $MailboxPath) {
        try {
            $Mailbox = Get-Content $MailboxPath -Raw | ConvertFrom-Json
            $LastMessage = $Mailbox | Select-Object -Last 1
            if ($LastMessage) {
                $result.content = $LastMessage.content
                if ($ShowOutput) {
                    Write-Host "`n--- Response from $($LastMessage.sender) ---" -ForegroundColor Cyan
                    Write-Host $LastMessage.content
                }
            }
        } catch {
            Write-Warning "Could not read mailbox: $_"
        }
    }
} else {
    $result.message = "Agent execution failed with exit code $($Process.ExitCode)"
    Write-Error $result.message
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
} elseif ($ShowOutput) {
    Write-Output $result
}
