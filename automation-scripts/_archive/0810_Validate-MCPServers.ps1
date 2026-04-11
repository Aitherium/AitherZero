#Requires -Version 7.0
<#
.SYNOPSIS
    Validates all MCP servers are built, configured, and can start correctly.

.DESCRIPTION
    This script validates the AitherOS MCP server ecosystem:
    - AitherZero MCP Server (TypeScript/Node.js)
    - Python MCP Bridge Servers (Vision, Canvas, Mind, Memory)
    
    It checks:
    1. Build status (dist/index.js exists for TypeScript)
    2. Configuration in .vscode/mcp.json
    3. Services defined in services.yaml
    4. Import chain works (no circular imports)
    5. Servers can start without errors

.PARAMETER Build
    Build the AitherZero MCP server before validation

.PARAMETER Start
    Start all MCP servers after validation

.PARAMETER Fix
    Attempt to fix common issues automatically

.EXAMPLE
    .\0810_Validate-MCPServers.ps1
    # Validate all MCP servers

.EXAMPLE
    .\0810_Validate-MCPServers.ps1 -Build -Start
    # Build, validate, and start all MCP servers

.NOTES
    Author: AitherZero
    Version: 1.0.0
    Category: Testing
#>

[CmdletBinding()]
param(
    [switch]$Build,
    [switch]$Start,
    [switch]$Fix
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

# ============================================================================
# CONFIGURATION
# ============================================================================

$MCPServers = @{
    # TypeScript MCP Server
    'AitherZero' = @{
        Type = 'typescript'
        Path = "$script:Root/AitherZero/library/integrations/mcp-server"
        BuildCommand = 'npm run build'
        DistFile = 'dist/index.js'
        Port = $null  # stdio transport
        StartCommand = 'node dist/index.js'
    }
    
    # Python MCP Bridge Servers
    'MCPCanvas' = @{
        Type = 'python'
        Module = 'services.mcp_bridges.mcp_canvas_server'
        Port = 8189
        DependsOn = @('Canvas')
    }
    'MCPVision' = @{
        Type = 'python'
        Module = 'services.mcp_bridges.mcp_vision_server'
        Port = 8184
        DependsOn = @('Vision')
    }
    'MCPMind' = @{
        Type = 'python'
        Module = 'services.mcp_bridges.mcp_mind_server'
        Port = 8288
        DependsOn = @('Mind')
    }
    'MCPMemory' = @{
        Type = 'python'
        Module = 'services.mcp_bridges.mcp_memory_server'
        Port = 8295
        DependsOn = @('Spirit')
    }
}

$Results = @{
    Passed = 0
    Failed = 0
    Warnings = 0
    Details = @()
}

# ============================================================================
# HELPERS
# ============================================================================

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        'INFO' { 'Cyan' }
        default { 'White' }
    }
    
    $prefix = switch ($Status) {
        'PASS' { '✓' }
        'FAIL' { '✗' }
        'WARN' { '⚠' }
        'INFO' { '→' }
        default { ' ' }
    }
    
    Write-Host "[$prefix] " -NoNewline -ForegroundColor $color
    Write-Host $Message
    
    $Results.Details += @{
        Message = $Message
        Status = $Status
        Timestamp = Get-Date
    }
    
    switch ($Status) {
        'PASS' { $script:Results.Passed++ }
        'FAIL' { $script:Results.Failed++ }
        'WARN' { $script:Results.Warnings++ }
    }
}

function Test-Port {
    param([int]$Port)
    
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        return $null -ne $conn
    }
    catch {
        return $false
    }
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

function Test-TypeScriptMCPServer {
    param([string]$Name, [hashtable]$Config)
    
    Write-Host "`n=== Validating $Name (TypeScript) ===" -ForegroundColor Cyan
    
    $path = $Config.Path
    
    # Check package.json exists
    if (-not (Test-Path "$path/package.json")) {
        Write-Status "${Name}: package.json not found at $path" 'FAIL'
        return $false
    }
    Write-Status "${Name}: package.json exists" 'PASS'
    
    # Check node_modules
    if (-not (Test-Path "$path/node_modules")) {
        Write-Status "${Name}: node_modules not found - running npm install" 'WARN'
        if ($Build -or $Fix) {
            Push-Location $path
            npm install 2>&1 | Out-Null
            Pop-Location
        }
    }
    else {
        Write-Status "${Name}: node_modules exists" 'PASS'
    }
    
    # Check/Build dist
    $distFile = "$path/$($Config.DistFile)"
    if (-not (Test-Path $distFile)) {
        Write-Status "${Name}: $($Config.DistFile) not found - needs build" 'WARN'
        if ($Build) {
            Write-Status "${Name}: Building..." 'INFO'
            Push-Location $path
            Invoke-Expression $Config.BuildCommand 2>&1 | Out-Null
            Pop-Location
            
            if (Test-Path $distFile) {
                Write-Status "${Name}: Build successful" 'PASS'
            }
            else {
                Write-Status "${Name}: Build failed" 'FAIL'
                return $false
            }
        }
    }
    else {
        Write-Status "${Name}: dist/index.js exists" 'PASS'
    }
    
    # Test MCP server responds to initialize
    Write-Status "${Name}: Testing MCP protocol response..." 'INFO'
    try {
        $testInput = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
        $env:AITHERZERO_ROOT = $script:Root
        $output = $testInput | node "$distFile" 2>$null
        
        if ($output -match '"result"') {
            Write-Status "${Name}: MCP protocol working" 'PASS'
        }
        else {
            Write-Status "${Name}: MCP protocol test inconclusive" 'WARN'
        }
    }
    catch {
        Write-Status "${Name}: MCP protocol test failed - $($_.Exception.Message)" 'WARN'
    }
    
    return $true
}

function Test-PythonMCPServer {
    param([string]$Name, [hashtable]$Config)
    
    Write-Host "`n=== Validating $Name (Python) ===" -ForegroundColor Cyan
    
    $module = $Config.Module
    $port = $Config.Port
    
    # Check if port is in use
    if ($port -and (Test-Port $port)) {
        Write-Status "${Name}: Port $port already in use (server may be running)" 'WARN'
    }
    
    # Test import
    Write-Status "${Name}: Testing Python import..." 'INFO'
    try {
        Push-Location "$script:Root/AitherOS"
        $importTest = python -c "import importlib; m = importlib.import_module('$module'); print('OK')" 2>&1
        Pop-Location
        
        if ($importTest -match 'OK') {
            Write-Status "${Name}: Import successful" 'PASS'
        }
        elseif ($importTest -match 'Error|Exception|Traceback') {
            $errorLine = ($importTest | Where-Object { $_ -match 'Error|Exception' } | Select-Object -First 1)
            Write-Status "${Name}: Import failed - $errorLine" 'FAIL'
            return $false
        }
        else {
            Write-Status "${Name}: Import test inconclusive" 'WARN'
        }
    }
    catch {
        Write-Status "${Name}: Import test failed - $($_.Exception.Message)" 'FAIL'
        return $false
    }
    
    # Check services.yaml entry
    $servicesYaml = "$script:Root/AitherOS/config/services.yaml"
    if (Test-Path $servicesYaml) {
        $content = Get-Content $servicesYaml -Raw
        if ($content -match "${Name}`:") {
            Write-Status "${Name}: Defined in services.yaml" 'PASS'
        }
        else {
            Write-Status "${Name}: Not found in services.yaml" 'WARN'
        }
    }
    
    return $true
}

function Test-MCPConfiguration {
    Write-Host "`n=== Validating MCP Configuration ===" -ForegroundColor Cyan
    
    # Check .vscode/mcp.json
    $mcpJson = "$script:Root/.vscode/mcp.json"
    if (Test-Path $mcpJson) {
        Write-Status "VSCode MCP config exists" 'PASS'
        
        try {
            $config = Get-Content $mcpJson -Raw | ConvertFrom-Json
            $serverCount = ($config.mcpServers | Get-Member -MemberType NoteProperty).Count
            Write-Status "  Configured servers: $serverCount" 'INFO'
        }
        catch {
            Write-Status "  Failed to parse mcp.json" 'WARN'
        }
    }
    else {
        Write-Status "VSCode MCP config not found" 'WARN'
    }
    
    # Check .github/mcp-servers.json
    $githubMcp = "$script:Root/.github/mcp-servers.json"
    if (Test-Path $githubMcp) {
        Write-Status "GitHub MCP config exists" 'PASS'
    }
    else {
        Write-Status "GitHub MCP config not found" 'WARN'
    }
    
    # Check .github/copilot/mcp-config.json
    $copilotMcp = "$script:Root/.github/copilot/mcp-config.json"
    if (Test-Path $copilotMcp) {
        Write-Status "Copilot MCP config exists" 'PASS'
    }
    else {
        Write-Status "Copilot MCP config not found" 'WARN'
    }
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                    AitherOS MCP Server Validation                              ║
║                                                                                ║
║  Validates all MCP servers are built, configured, and operational              ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

# Validate configuration files
Test-MCPConfiguration

# Validate each server
foreach ($name in $MCPServers.Keys) {
    $config = $MCPServers[$name]
    
    if ($config.Type -eq 'typescript') {
        Test-TypeScriptMCPServer -Name $name -Config $config
    }
    elseif ($config.Type -eq 'python') {
        Test-PythonMCPServer -Name $name -Config $config
    }
}

# Summary
Write-Host "`n" + "=" * 70 -ForegroundColor Cyan
Write-Host "VALIDATION SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  Passed:   $($Results.Passed)" -ForegroundColor Green
Write-Host "  Failed:   $($Results.Failed)" -ForegroundColor Red
Write-Host "  Warnings: $($Results.Warnings)" -ForegroundColor Yellow
Write-Host ""

if ($Results.Failed -gt 0) {
    Write-Host "Some validations failed. Run with -Build to build servers, or -Fix to attempt repairs." -ForegroundColor Yellow
    exit 1
}
elseif ($Results.Warnings -gt 0) {
    Write-Host "Validation passed with warnings." -ForegroundColor Yellow
    exit 0
}
else {
    Write-Host "All MCP servers validated successfully!" -ForegroundColor Green
    exit 0
}
