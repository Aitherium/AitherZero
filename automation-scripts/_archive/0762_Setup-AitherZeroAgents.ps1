#Requires -Version 7.0

<#
.SYNOPSIS
    Sets up AitherZero Automation Agent and MCP Server for use with AI coding assistants.

.DESCRIPTION
    This script automatically installs and configures:
    - AitherZeroAutomationAgent: Python-based automation agent using Google ADK
    - AitherZero MCP Server: TypeScript Model Context Protocol server
    
    After setup, you can use AitherZero tools directly from Claude, VS Code Copilot,
    or any MCP-compatible AI assistant.

.PARAMETER SkipAgent
    Skip setting up the AitherZeroAutomationAgent.

.PARAMETER SkipMcp
    Skip setting up the MCP Server.

.PARAMETER Force
    Force reinstallation even if already set up.

.PARAMETER ConfigureMcp
    Automatically configure MCP for VS Code and Claude Desktop.

.EXAMPLE
    ./0762_Setup-AitherZeroAgents.ps1
    
.EXAMPLE
    ./0762_Setup-AitherZeroAgents.ps1 -ConfigureMcp
    
.NOTES
    Stage: AI
    Order: 0762
#>

[CmdletBinding()]
param(
    [switch]$SkipAgent,
    [switch]$SkipMcp,
    [switch]$Force,
    [switch]$ConfigureMcp
)

$ErrorActionPreference = 'Stop'

# Resolve paths
$scriptRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $scriptRoot

# Try to load AitherZero module for logging
$modulePath = Join-Path $projectRoot "AitherZero.psd1"
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -ErrorAction SilentlyContinue
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "INFO" { "Cyan" }
        default { "White" }
    }
    $symbol = switch ($Status) {
        "OK" { "✅" }
        "WARN" { "⚠️" }
        "ERROR" { "❌" }
        "INFO" { "📦" }
        default { "•" }
    }
    Write-Host "$symbol $Message" -ForegroundColor $color
}

function Test-Command {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

# Header
Write-Host ""
Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║    AitherZero Agent & MCP Setup            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
Write-Step "Checking prerequisites..." "INFO"

$prereqs = @{
    'python' = @{ Name = 'Python 3.10+'; Required = -not $SkipAgent }
    'node'   = @{ Name = 'Node.js 18+'; Required = -not $SkipMcp }
    'npm'    = @{ Name = 'npm'; Required = -not $SkipMcp }
    'git'    = @{ Name = 'Git'; Required = $true }
}

$missing = @()
foreach ($cmd in $prereqs.Keys) {
    $info = $prereqs[$cmd]
    if ($info.Required -and -not (Test-Command $cmd)) {
        $missing += "  - $($info.Name) ($cmd)"
    }
}

if ($missing.Count -gt 0) {
    Write-Step "Missing prerequisites:" "ERROR"
    $missing | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Install missing tools and try again." -ForegroundColor Yellow
    exit 1
}

Write-Step "All prerequisites available" "OK"

# Determine agent and MCP paths
$agentPath = Join-Path $projectRoot "agents/AitherZeroAutomationAgent"
$mcpPath = Join-Path $projectRoot "AitherZero/library/integrations/mcp-server"

# Alternative paths (for public repo structure)
if (-not (Test-Path $agentPath)) {
    $agentPath = Join-Path (Split-Path $projectRoot) "agents/AitherZeroAutomationAgent"
}
if (-not (Test-Path $mcpPath)) {
    $mcpPath = Join-Path $projectRoot "library/integrations/mcp-server"
}

#region Setup AitherZeroAutomationAgent
if (-not $SkipAgent) {
    Write-Host ""
    Write-Step "Setting up AitherZeroAutomationAgent..." "INFO"
    
    if (-not (Test-Path $agentPath)) {
        Write-Step "Agent not found at: $agentPath" "ERROR"
        Write-Host "  Clone the full AitherZero repo or run from correct location." -ForegroundColor Yellow
    }
    else {
        $venvPath = Join-Path $agentPath ".venv"
        
        if ((Test-Path $venvPath) -and -not $Force) {
            Write-Step "Virtual environment exists (use -Force to recreate)" "WARN"
        }
        else {
            Push-Location $agentPath
            try {
                # Create virtual environment
                Write-Host "  Creating Python virtual environment..." -ForegroundColor Gray
                python -m venv .venv
                
                # Determine pip path
                $pip = if ($IsWindows -or $env:OS -match 'Windows') {
                    ".venv/Scripts/pip.exe"
                } else {
                    ".venv/bin/pip"
                }
                
                # Install dependencies
                Write-Host "  Installing Python dependencies..." -ForegroundColor Gray
                & $pip install --upgrade pip --quiet 2>$null
                & $pip install -r requirements.txt --quiet
                
                # Setup .env if needed
                if (-not (Test-Path ".env") -and (Test-Path ".env.example")) {
                    Copy-Item ".env.example" ".env"
                    Write-Step "Created .env from template - edit with your API keys" "WARN"
                }
                
                Write-Step "AitherZeroAutomationAgent ready!" "OK"
            }
            catch {
                Write-Step "Failed to setup agent: $_" "ERROR"
            }
            finally {
                Pop-Location
            }
        }
    }
}
#endregion

#region Setup MCP Server
if (-not $SkipMcp) {
    Write-Host ""
    Write-Step "Setting up AitherZero MCP Server..." "INFO"
    
    if (-not (Test-Path $mcpPath)) {
        Write-Step "MCP Server not found at: $mcpPath" "ERROR"
    }
    else {
        $nodeModules = Join-Path $mcpPath "node_modules"
        
        if ((Test-Path $nodeModules) -and -not $Force) {
            Write-Step "Node modules exist (use -Force to reinstall)" "WARN"
        }
        else {
            Push-Location $mcpPath
            try {
                Write-Host "  Installing npm dependencies..." -ForegroundColor Gray
                npm install --silent 2>$null
                
                Write-Host "  Building TypeScript..." -ForegroundColor Gray
                npm run build --silent 2>$null
                
                Write-Step "MCP Server ready!" "OK"
            }
            catch {
                Write-Step "Failed to setup MCP server: $_" "ERROR"
            }
            finally {
                Pop-Location
            }
        }
    }
}
#endregion

#region Configure MCP Clients
if ($ConfigureMcp -and (Test-Path $mcpPath)) {
    Write-Host ""
    Write-Step "Configuring MCP clients..." "INFO"
    
    $mcpDistPath = (Join-Path $mcpPath "dist/index.js").Replace('\', '/')
    
    # VS Code MCP config
    $vscodeMcpPath = Join-Path $projectRoot ".vscode/mcp.json"
    if (-not (Test-Path $vscodeMcpPath)) {
        $vscodeMcpPath = Join-Path (Split-Path $projectRoot) ".vscode/mcp.json"
    }
    
    if (Test-Path (Split-Path $vscodeMcpPath)) {
        $mcpConfig = @{
            servers = @{
                aitherzero = @{
                    command = "node"
                    args = @($mcpDistPath)
                }
            }
        }
        $mcpConfig | ConvertTo-Json -Depth 5 | Set-Content $vscodeMcpPath -Encoding utf8
        Write-Step "Configured VS Code MCP: $vscodeMcpPath" "OK"
    }
    
    # Claude Desktop config (if exists)
    $claudeConfigPath = if ($IsWindows -or $env:OS -match 'Windows') {
        "$env:APPDATA\Claude\claude_desktop_config.json"
    } else {
        "$HOME/.config/claude/claude_desktop_config.json"
    }
    
    if (Test-Path (Split-Path $claudeConfigPath)) {
        $claudeConfig = if (Test-Path $claudeConfigPath) {
            Get-Content $claudeConfigPath -Raw | ConvertFrom-Json -AsHashtable
        } else {
            @{ mcpServers = @{} }
        }
        
        if (-not $claudeConfig.mcpServers) {
            $claudeConfig.mcpServers = @{}
        }
        
        $claudeConfig.mcpServers.aitherzero = @{
            command = "node"
            args = @($mcpDistPath)
        }
        
        $claudeConfig | ConvertTo-Json -Depth 5 | Set-Content $claudeConfigPath -Encoding utf8
        Write-Step "Configured Claude Desktop: $claudeConfigPath" "OK"
    }
}
#endregion

# Summary
Write-Host ""
Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║    Setup Complete!                         ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

if (-not $SkipAgent -and (Test-Path $agentPath)) {
    $pythonExe = if ($IsWindows -or $env:OS -match 'Windows') {
        "$agentPath/.venv/Scripts/python.exe"
    } else {
        "$agentPath/.venv/bin/python"
    }
    
    Write-Host "🤖 AitherZeroAutomationAgent:" -ForegroundColor White
    Write-Host "   Start: $pythonExe $agentPath/service.py" -ForegroundColor Gray
    Write-Host ""
}

if (-not $SkipMcp -and (Test-Path $mcpPath)) {
    Write-Host "🔌 MCP Server:" -ForegroundColor White
    Write-Host "   Add to your MCP client config:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   {" -ForegroundColor DarkGray
    Write-Host "     `"aitherzero`": {" -ForegroundColor DarkGray
    Write-Host "       `"command`": `"node`"," -ForegroundColor DarkGray
    Write-Host "       `"args`": [`"$($mcpPath.Replace('\','/'))/dist/index.js`"]" -ForegroundColor DarkGray
    Write-Host "     }" -ForegroundColor DarkGray
    Write-Host "   }" -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "📖 Documentation: AitherZero/library/integrations/mcp-server/README.md" -ForegroundColor Cyan
