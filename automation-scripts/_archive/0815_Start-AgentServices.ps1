<#
.SYNOPSIS
    Starts AitherOS Agent Services

.DESCRIPTION
    Starts all agent services as always-on daemons:
    - AitherOrchestrator (8767) - THE BRAIN
    - NarrativeAgent (8770) - Creative writing
    - InfraAgent (8771) - Infrastructure
    - AutomationAgent (8772) - PowerShell
    - AitherAgent (8773) - General assistant

.PARAMETER Agents
    Which agents to start. Options: All, Brain, Narrative, Infra, Automation, Aither

.PARAMETER Background
    Run in background (default: true)

.EXAMPLE
    .\0815_Start-AgentServices.ps1 -Agents All
    .\0815_Start-AgentServices.ps1 -Agents Brain
    .\0815_Start-AgentServices.ps1 -Agents Narrative,Infra
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('All', 'Brain', 'Narrative', 'Infra', 'Automation', 'Aither', 'Orchestrator')]
    [string[]]$Agents = @('All'),
    
    [switch]$Background = $true,
    
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

# Configuration
$AITHERZERO_ROOT = $env:AITHERZERO_ROOT
if (-not $AITHERZERO_ROOT) {
    $AITHERZERO_ROOT = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
}

$AITHEROS_ROOT = Join-Path $AITHERZERO_ROOT "AitherOS"
$AGENTS_DIR = Join-Path $AITHEROS_ROOT "agents"
$SERVICES_DIR = Join-Path $AITHEROS_ROOT "AitherNode\services\agents"
$VENV_PATH = Join-Path $AGENTS_DIR "NarrativeAgent\.venv"

# Agent configurations
$AgentConfigs = @{
    'Orchestrator' = @{
        Port = 8767
        Path = Join-Path $SERVICES_DIR "AitherOrchestrator.py"
        Name = "AitherOrchestrator"
        Module = "AitherOrchestrator:app"
    }
    'Narrative' = @{
        Port = 8770
        Path = Join-Path $AGENTS_DIR "NarrativeAgent\service.py"
        Name = "NarrativeAgent"
        Module = "service:app"
        WorkDir = Join-Path $AGENTS_DIR "NarrativeAgent"
    }
    'Infra' = @{
        Port = 8771
        Path = Join-Path $AGENTS_DIR "InfrastructureAgent\service.py"
        Name = "InfraAgent"
        Module = "service:app"
        WorkDir = Join-Path $AGENTS_DIR "InfrastructureAgent"
    }
    'Automation' = @{
        Port = 8772
        Path = Join-Path $AGENTS_DIR "AitherZeroAutomationAgent\service.py"
        Name = "AutomationAgent"
        Module = "service:app"
        WorkDir = Join-Path $AGENTS_DIR "AitherZeroAutomationAgent"
    }
    'Aither' = @{
        Port = 8773
        Path = Join-Path $AGENTS_DIR "Aither\service.py"
        Name = "AitherAgent"
        Module = "service:app"
        WorkDir = Join-Path $AGENTS_DIR "Aither"
    }
}

# Resolve agent selection
$SelectedAgents = @()
if ('All' -in $Agents) {
    $SelectedAgents = @('Orchestrator', 'Narrative', 'Infra', 'Automation', 'Aither')
} elseif ('Brain' -in $Agents) {
    $SelectedAgents = @('Orchestrator')
} else {
    $SelectedAgents = $Agents
}

Write-Host ""
Write-Host "🧠 AitherOS Agent Services Startup" -ForegroundColor Cyan
Write-Host "=" * 50

# Check venv
$pythonExe = if ($IsWindows -or $env:OS -eq "Windows_NT") {
    Join-Path $VENV_PATH "Scripts\python.exe"
} else {
    Join-Path $VENV_PATH "bin/python"
}

if (-not (Test-Path $pythonExe)) {
    Write-Host "⚠️  Virtual environment not found at: $VENV_PATH" -ForegroundColor Yellow
    Write-Host "   Run: python run_agent.py --setup" -ForegroundColor Yellow
    $pythonExe = "python"
}

# Function to check if port is in use
function Test-PortInUse {
    param([int]$Port)
    try {
        $connection = New-Object System.Net.Sockets.TcpClient
        $connection.Connect("localhost", $Port)
        $connection.Close()
        return $true
    } catch {
        return $false
    }
}

# Function to start an agent service
function Start-AgentService {
    param(
        [string]$AgentKey,
        [hashtable]$Config
    )
    
    $name = $Config.Name
    $port = $Config.Port
    $path = $Config.Path
    $workDir = $Config.WorkDir
    
    Write-Host ""
    Write-Host "Starting $name on port $port..." -ForegroundColor Green
    
    # Check if already running
    if (Test-PortInUse -Port $port) {
        if (-not $Force) {
            Write-Host "   ✓ Already running on port $port" -ForegroundColor DarkGreen
            return
        }
        Write-Host "   ⚠️  Port $port in use, forcing restart..." -ForegroundColor Yellow
    }
    
    # Check if script exists
    if (-not (Test-Path $path)) {
        Write-Host "   ❌ Service script not found: $path" -ForegroundColor Red
        return
    }
    
    # Determine working directory
    if (-not $workDir) {
        $workDir = Split-Path $path -Parent
    }
    
    # Build command
    $module = $Config.Module
    
    # Set up environment
    $env:PYTHONPATH = "$AITHEROS_ROOT\AitherNode;$AITHEROS_ROOT\AitherNode\services;$AITHEROS_ROOT\agents\common"
    
    if ($Background) {
        # Start as background job
        $scriptBlock = {
            param($pythonExe, $workDir, $module, $port, $pythonPath)
            $env:PYTHONPATH = $pythonPath
            Set-Location $workDir
            & $pythonExe -m uvicorn $module --host 0.0.0.0 --port $port
        }
        
        $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $pythonExe, $workDir, $module, $port, $env:PYTHONPATH
        Write-Host "   ✓ Started as background job (ID: $($job.Id))" -ForegroundColor Green
    } else {
        # Start in foreground (blocks)
        Push-Location $workDir
        & $pythonExe -m uvicorn $module --host 0.0.0.0 --port $port
        Pop-Location
    }
}

# Start selected agents
Write-Host ""
Write-Host "Starting agents: $($SelectedAgents -join ', ')" -ForegroundColor Cyan

foreach ($agentKey in $SelectedAgents) {
    if ($AgentConfigs.ContainsKey($agentKey)) {
        Start-AgentService -AgentKey $agentKey -Config $AgentConfigs[$agentKey]
    } else {
        Write-Host "Unknown agent: $agentKey" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "=" * 50
Write-Host ""
Write-Host "🧠 Agent Services Summary:" -ForegroundColor Cyan
Write-Host ""

foreach ($agentKey in $SelectedAgents) {
    if ($AgentConfigs.ContainsKey($agentKey)) {
        $config = $AgentConfigs[$agentKey]
        $status = if (Test-PortInUse -Port $config.Port) { "✓ Running" } else { "○ Starting" }
        Write-Host "   $status $($config.Name) - http://localhost:$($config.Port)" -ForegroundColor $(if ($status -match "Running") { "Green" } else { "Yellow" })
    }
}

Write-Host ""
Write-Host "Use the CLI to interact: python aither_cli.py" -ForegroundColor DarkGray
Write-Host "Or start interactively: python run_agent.py cli" -ForegroundColor DarkGray
Write-Host ""

