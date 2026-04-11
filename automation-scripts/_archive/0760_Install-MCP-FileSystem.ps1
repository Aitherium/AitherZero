#Requires -Version 7.0
# Description: Installs and registers the MCP Filesystem Server
# Tags: mcp, filesystem, tool

param(
    [Parameter(Mandatory=$true)]
    [string[]]$AllowedPaths
)

# Import Core
. "$PSScriptRoot/_init.ps1"
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm is required."
}

Write-Host "📦 Installing @modelcontextprotocol/server-filesystem..." -ForegroundColor Cyan
npm install -g @modelcontextprotocol/server-filesystem

if ($LASTEXITCODE -ne 0) { throw "npm install failed" }

# Register
Write-Host "🔗 Registering MCP Server..." -ForegroundColor Cyan

# Determine paths to allow
$argsList = @()
foreach ($path in $AllowedPaths) {
    $argsList += $path
}

Set-AitherMCPConfig -Name "FileSystem" `
                    -Command "npx" `
                    -Args (@("-y", "@modelcontextprotocol/server-filesystem") + $argsList) `
                    -Verbose

Write-Host "✅ Filesystem MCP Server registered." -ForegroundColor Green
