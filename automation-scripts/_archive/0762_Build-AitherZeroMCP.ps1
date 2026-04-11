<#
.SYNOPSIS
    Build AitherZero MCP Server

.DESCRIPTION
    Builds the AitherZero MCP (Model Context Protocol) server, which provides
    PowerShell tools for AI agents. The server is a TypeScript project that
    needs to be compiled before use.

    Tools provided by AitherZero MCP:
    - execute_powershell: Run PowerShell scripts and commands
    - read_file: Read file contents
    - write_file: Write content to files
    - list_directory: List directory contents
    - create_directory: Create directories
    - delete_file: Delete files
    - copy_file: Copy files
    - move_file: Move/rename files
    - get_system_info: Get system information
    - get_environment: Get environment variables
    - set_environment: Set environment variables
    - start_process: Start a new process
    - stop_process: Stop a running process
    - get_service: Get service status

.PARAMETER Force
    Rebuild even if dist directory exists

.EXAMPLE
    .\0762_Build-AitherZeroMCP.ps1

.EXAMPLE
    .\0762_Build-AitherZeroMCP.ps1 -Force

.NOTES
    Requires Node.js 18+ and npm
#>

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Determine paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AitherZeroRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$MCPServerDir = Join-Path $AitherZeroRoot "library\integrations\mcp-server"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Building AitherZero MCP Server" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Check if MCP server directory exists
if (-not (Test-Path $MCPServerDir)) {
    Write-Host "  [ERROR] MCP server directory not found: $MCPServerDir" -ForegroundColor Red
    exit 1
}

# Check for Node.js
$nodeVersion = & node --version 2>$null
if (-not $nodeVersion) {
    Write-Host "  [ERROR] Node.js not found. Please install Node.js 18+ first." -ForegroundColor Red
    Write-Host "         Run: winget install OpenJS.NodeJS" -ForegroundColor Yellow
    exit 1
}
Write-Host "  [INFO] Node.js: $nodeVersion" -ForegroundColor Gray

# Check for npm
$npmVersion = & npm --version 2>$null
if (-not $npmVersion) {
    Write-Host "  [ERROR] npm not found. Please install Node.js with npm." -ForegroundColor Red
    exit 1
}
Write-Host "  [INFO] npm: $npmVersion" -ForegroundColor Gray

# Check if already built
$distDir = Join-Path $MCPServerDir "dist"
$distIndex = Join-Path $distDir "index.js"
if ((Test-Path $distIndex) -and -not $Force) {
    Write-Host "  [SKIP] MCP server already built (use -Force to rebuild)" -ForegroundColor Yellow
    Write-Host "         $distIndex" -ForegroundColor Gray
    exit 0
}

# Change to MCP server directory
Push-Location $MCPServerDir
try {
    # Install dependencies
    Write-Host ""
    Write-Host "  [1/2] Installing dependencies..." -ForegroundColor Cyan
    $installResult = & npm install 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] npm install failed:" -ForegroundColor Red
        Write-Host $installResult -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] Dependencies installed" -ForegroundColor Green

    # Build TypeScript
    Write-Host ""
    Write-Host "  [2/2] Building TypeScript..." -ForegroundColor Cyan
    $buildResult = & npm run build 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] npm run build failed:" -ForegroundColor Red
        Write-Host $buildResult -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] TypeScript compiled" -ForegroundColor Green

    # Verify build output
    if (Test-Path $distIndex) {
        Write-Host ""
        Write-Host "  [SUCCESS] AitherZero MCP Server built successfully!" -ForegroundColor Green
        Write-Host "            $distIndex" -ForegroundColor Gray

        # Show available tools
        Write-Host ""
        Write-Host "  Available MCP Tools:" -ForegroundColor Cyan
        Write-Host "  - execute_powershell: Run PowerShell scripts" -ForegroundColor Gray
        Write-Host "  - read_file, write_file, list_directory" -ForegroundColor Gray
        Write-Host "  - get_system_info, get_environment" -ForegroundColor Gray
        Write-Host "  - start_process, stop_process, get_service" -ForegroundColor Gray
    } else {
        Write-Host "  [ERROR] Build completed but output not found: $distIndex" -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  MCP Server build complete!" -ForegroundColor Green
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

exit 0
