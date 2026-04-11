#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: None
# Description: Configures the AitherNode MCP Server environment (config only)
# Tags: ai, mcp, aithernode, config

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_init.ps1"

$nodePath = Join-Path $projectRoot "AitherOS/AitherNode"
if (-not (Test-Path $nodePath)) {
    throw "AitherNode directory not found at $nodePath"
}

Write-Host "🤖 Configuring AitherNode MCP Server..." -ForegroundColor Cyan

# 1. Create .env if missing
$envPath = Join-Path $nodePath ".env"
if (-not (Test-Path $envPath)) {
    if ($PSCmdlet.ShouldProcess($envPath, "Create .env file")) {
        Write-Host "   Creating default .env file..." -ForegroundColor Yellow
        $envContent = @"
COMFY_API_URL=127.0.0.1:8188
OLLAMA_API_URL=http://localhost:11434
AITHER_OUTPUT_DIR=output
"@
        Set-Content -Path $envPath -Value $envContent
    }
} else {
    Write-Host "   .env file already exists." -ForegroundColor Green
}

Write-Host "✅ AitherNode configuration complete." -ForegroundColor Green
Write-Host "   Note: Python dependencies are managed by 0720_Setup-AitherOSVenv.ps1" -ForegroundColor Gray
