#Requires -Version 7.0
# Stage: Development
# Dependencies: Python
# Description: Scaffolds a new AitherZero Sub-Agent
# Tags: agent, adk, scaffold

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Role,

    [Parameter(Mandatory = $true)]
    [string]$Instruction,

    [Parameter()]
    [string]$Model = "gemini-2.5-flash"
)

$ErrorActionPreference = 'Stop'

# Import Core
. "$PSScriptRoot/_init.ps1"

$targetDir = Join-Path $projectRoot "AitherOS/agents/$Name"
if (Test-Path $targetDir) {
    throw "Agent '$Name' already exists at $targetDir"
}

Write-Host "🤖 Scaffolding new sub-agent: $Name ($Role)..." -ForegroundColor Cyan

# Copy Template
Copy-Item -Path $templateDir -Destination $targetDir -Recurse -Force

# Customize prompts.py
$promptsFile = Join-Path $targetDir "prompts.py"
if (Test-Path $promptsFile) {
    $content = Get-Content $promptsFile -Raw

    # Simple replacement for instruction (assuming template has specific marker or just overwrite)
    # Since template might be complex, let's just prepend/replace the SYSTEM_INSTRUCTION

    $newInstruction = @"
SYSTEM_INSTRUCTION = """
You are the $Name, a specialized AI agent responsible for: $Role.

$Instruction

Use your available tools to fulfill requests.
"""
"@

    # Replace existing SYSTEM_INSTRUCTION block or file content?
    # Let's overwrite prompts.py for simplicity or regex replace
    $content = $content -replace 'SYSTEM_INSTRUCTION = """[\s\S]*?"""', $newInstruction
    Set-Content -Path $promptsFile -Value $content
}

# Customize agent.py (Name)
$agentFile = Join-Path $targetDir "agent.py"
if (Test-Path $agentFile) {
    $content = Get-Content $agentFile -Raw
    $content = $content -replace 'name="AitherZeroAutomationAgent"', "name=""$Name"""
    # Update banner title if present
    Set-Content -Path $agentFile -Value $content
}

# Setup Venv
Write-Host "📦 Setting up virtual environment..." -ForegroundColor Cyan
$setupScript = Join-Path $projectRoot "AitherZero/library/automation-scripts/0752_Setup-AgentVenv.ps1"
Invoke-AitherScript -Script $setupScript -Arguments @{ Path = $targetDir }

Write-Host "✅ Sub-Agent '$Name' created successfully!" -ForegroundColor Green
Write-Host "   Location: $targetDir"
Write-Host "   To run: cd agents/$Name; ./run.sh"
