#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Idempotent setup and validation of MCP servers for GitHub Copilot.

.DESCRIPTION
    This script provides complete MCP server lifecycle management:
    1. Validates prerequisites (Node.js 18+)
    2. Builds the custom AitherZero MCP server (TypeScript -> JavaScript)
    3. Validates MCP server configuration files
    4. Fixes common configuration issues (non-existent packages)
    5. Verifies VS Code Copilot MCP settings
    6. Provides clear activation instructions

    The script is idempotent - safe to run multiple times.

.PARAMETER Force
    Force rebuild even if already built.

.PARAMETER SkipValidation
    Skip validation checks and just build.

.PARAMETER FixConfig
    Automatically fix known configuration issues.

.EXAMPLE
    ./0010_Setup-MCPServers.ps1
    Standard setup with validation.

.EXAMPLE
    ./0010_Setup-MCPServers.ps1 -Force
    Force rebuild of MCP servers.

.EXAMPLE
    ./0010_Setup-MCPServers.ps1 -FixConfig
    Fix configuration issues automatically.

.NOTES
    Script: 0010_Setup-MCPServers.ps1
    Stage: Environment
    Category: Setup
    Range: 0000-0099 (Environment preparation)
    Dependencies: Node.js 18+, npm
    Author: Aitherium Corporation
    Requires: Node.js 18+, npm
    Idempotent: Yes - safe to run multiple times
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$SkipValidation,

    [Parameter(Mandatory = $false)]
    [switch]$FixConfig
)

. "$PSScriptRoot/_init.ps1"
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Colors for output
$script:Colors = @{
    Success = 'Green'
    Info    = 'Cyan'
    Warning = 'Yellow'
    Error   = 'Red'
}

function Write-StatusMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Success', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $color = $script:Colors[$Level]
    $prefix = switch ($Level) {
        'Success' { '[✓]' }
        'Info' { '[i]' }
        'Warning' { '[!]' }
        'Error' { '[✗]' }
    }

    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Test-NodeInstalled {
    try {
        $nodeVersion = node --version 2>$null
        $npmVersion = npm --version 2>$null

        if ($nodeVersion -and $npmVersion) {
            Write-StatusMessage "Node.js $nodeVersion and npm $npmVersion detected" -Level Success
            return $true
        }

        Write-StatusMessage "Node.js or npm not found in PATH" -Level Error
        return $false
    } catch {
        Write-StatusMessage "Failed to check Node.js installation: $_" -Level Error
        return $false
    }
}

function Test-MCPServerBuilt {
    param([string]$ServerPath)

    $distPath = Join-Path $ServerPath 'dist'
    $indexJs = Join-Path $distPath 'index.js'

    if (Test-Path $indexJs) {
        Write-StatusMessage "MCP server already built at: $indexJs" -Level Success
        return $true
    }

    Write-StatusMessage "MCP server not built (dist/index.js missing)" -Level Warning
    return $false
}

function Build-MCPServer {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$ServerPath)

    $locationPushed = $false
    try {
        if ($PSCmdlet.ShouldProcess("MCP Server at $ServerPath", "Build")) {
            Push-Location $ServerPath
            $locationPushed = $true
            Write-StatusMessage "Building AitherZero MCP server..." -Level Info

            # Install dependencies
            Write-StatusMessage "Installing npm dependencies..." -Level Info
            npm install --silent

            # Build is automatic via postinstall, but verify
            if (-not (Test-Path 'dist/index.js')) {
                Write-StatusMessage "Build failed - dist/index.js not created" -Level Error
                return $false
            }

            Write-StatusMessage "MCP server built successfully" -Level Success
            return $true
        } else {
            Write-StatusMessage "Would build MCP server at: $ServerPath" -Level Info
            return $true
        }
    } catch {
        Write-StatusMessage "Failed to build MCP server: $_" -Level Error
        return $false
    } finally {
        if ($locationPushed) {
            Pop-Location
        }
    }
}

function Test-MCPConfiguration {
    param([string]$WorkspaceRoot)

    $configFile = Join-Path $WorkspaceRoot '.vscode' 'mcp.json'
    $legacyConfigFile = Join-Path $WorkspaceRoot '.vscode' 'mcp-servers.json'
    $settingsFile = Join-Path $WorkspaceRoot '.vscode' 'settings.json'

    # Check config file exists
    if (-not (Test-Path $configFile)) {
        if (Test-Path $legacyConfigFile) {
             Write-StatusMessage "Found legacy MCP config: $legacyConfigFile" -Level Warning
             $configFile = $legacyConfigFile
        } else {
            Write-StatusMessage "MCP config file missing: $configFile" -Level Error
            return $false
        }
    }

    # Validate JSON and check for non-existent packages
    $hasIssues = $false
    try {
        $config = Get-Content $configFile -Raw | ConvertFrom-Json

        # Handle both formats safely for Strict Mode
        $serversObj = $null
        if ($config.PSObject.Properties['mcpServers']) {
            $serversObj = $config.mcpServers
        } elseif ($config.PSObject.Properties['servers']) {
            $serversObj = $config.servers
        }

        if (-not $serversObj) {
             Write-StatusMessage "No mcpServers or servers property in config" -Level Warning
             return $false
        }

        $serverNames = @($serversObj | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
        $serverCount = $serverNames.Count
        Write-StatusMessage "Found $serverCount MCP servers configured" -Level Success

        # Known non-existent packages that cause Sentry errors
        $badPackages = @{
            '@modelcontextprotocol/server-git'   = 'git operations (package does not exist)'
            '@modelcontextprotocol/server-fetch' = 'fetch operations (package does not exist)'
        }

        # List servers and check for issues
        foreach ($serverName in $serverNames) {
            $server = $serversObj.$serverName
            $desc = if ($server.PSObject.Properties['description']) { $server.description } else { "No description" }
            Write-StatusMessage "  - ${serverName}: $desc" -Level Info

            # Check if using non-existent package
            if ($server.PSObject.Properties['args']) {
                foreach ($arg in $server.args) {
                    foreach ($badPkg in $badPackages.Keys) {
                        if ($arg -eq $badPkg) {
                            Write-StatusMessage "    [!] Uses $badPkg - $($badPackages[$badPkg])" -Level Warning
                            $hasIssues = $true
                        }
                    }
                }
            }
        }
    } catch {
        Write-StatusMessage "Failed to parse MCP config: $_" -Level Error
        return $false
    }

    return -not $hasIssues
}

function Repair-MCPConfiguration {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$WorkspaceRoot)

    if ($PSCmdlet.ShouldProcess("MCP Configuration at $WorkspaceRoot", "Repair")) {
        Write-StatusMessage "Fixing MCP configuration issues..." -Level Info

        $configFile = Join-Path $WorkspaceRoot '.vscode' 'mcp.json'
        $legacyConfigFile = Join-Path $WorkspaceRoot '.vscode' 'mcp-servers.json'

        if (-not (Test-Path $configFile)) {
            if (Test-Path $legacyConfigFile) {
                $configFile = $legacyConfigFile
            } else {
                Write-StatusMessage "Config file not found, cannot fix" -Level Error
                return $false
            }
        }

        try {
            $config = Get-Content $configFile -Raw | ConvertFrom-Json
            $modified = $false

            # Remove servers using non-existent packages
            $serversToRemove = @()
            $badPackages = @('@modelcontextprotocol/server-git', '@modelcontextprotocol/server-fetch')

            # Handle both formats
            $serversObj = $null
            if ($config.PSObject.Properties['mcpServers']) {
                $serversObj = $config.mcpServers
            } elseif ($config.PSObject.Properties['servers']) {
                $serversObj = $config.servers
            }

            if ($serversObj) {
                $serverNames = @($serversObj | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)

                foreach ($serverName in $serverNames) {
                    $server = $serversObj.$serverName
                    if ($server.PSObject.Properties['args']) {
                        foreach ($arg in $server.args) {
                            if ($badPackages -contains $arg) {
                                $serversToRemove += $serverName
                                Write-StatusMessage "Removing server '$serverName' (uses non-existent package: $arg)" -Level Info
                                break
                            }
                        }
                    }
                }

                # Remove bad servers
                foreach ($serverName in $serversToRemove) {
                    $serversObj.PSObject.Properties.Remove($serverName)
                    $modified = $true
                }
            }

            # Update defaultServers list (if exists)
            if ($config.PSObject.Properties['defaultServers']) {
                $newDefaults = @()
                foreach ($server in $config.defaultServers) {
                    if ($serversToRemove -notcontains $server) {
                        $newDefaults += $server
                    }
                }
                $config.defaultServers = $newDefaults
                $modified = $true
            }

            if ($modified) {
                # Backup original
                $backupFile = $configFile + ".backup." + (Get-Date -Format "yyyyMMddHHmmss")
                Copy-Item $configFile $backupFile
                Write-StatusMessage "Backed up original config to: $backupFile" -Level Info

                # Write fixed config
                $config | ConvertTo-Json -Depth 10 | Set-Content $configFile -Encoding UTF8
                Write-StatusMessage "MCP configuration fixed successfully" -Level Success
                Write-StatusMessage "Removed $($serversToRemove.Count) problematic server(s)" -Level Success
                return $true
            } else {
                Write-StatusMessage "No configuration issues found to fix" -Level Info
                return $true
            }
        } catch {
            Write-StatusMessage "Failed to fix configuration: $_" -Level Error
            return $false
        }
    } else {
        Write-StatusMessage "Would repair MCP configuration at: $WorkspaceRoot" -Level Info
        return $true
    }
}

function Show-ActivationInstruction {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  MCP Servers Setup Complete!" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To activate MCP servers in GitHub Copilot:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Reload VS Code window:" -ForegroundColor White
    Write-Host "     - Press: Ctrl+Shift+P (Windows/Linux) or Cmd+Shift+P (macOS)" -ForegroundColor Gray
    Write-Host "     - Type: 'Developer: Reload Window'" -ForegroundColor Gray
    Write-Host "     - Press: Enter" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Verify MCP servers loaded:" -ForegroundColor White
    Write-Host "     - Open: View > Output (Ctrl+Shift+U)" -ForegroundColor Gray
    Write-Host "     - Select: 'GitHub Copilot' from dropdown" -ForegroundColor Gray
    Write-Host "     - Look for: '[MCP] Server ready: aitherzero'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. Test in Copilot Chat:" -ForegroundColor White
    Write-Host "     - Open Copilot Chat (Ctrl+Shift+I)" -ForegroundColor Gray
    Write-Host "     - Type: '@workspace List all automation scripts'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

function Update-GlobalMCPConfig {
    param([string]$WorkspaceRoot)

    $homeDir = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }

    if ($IsWindows) {
        $globalConfigPath = Join-Path $homeDir "AppData/Roaming/Code/User/mcp.json"
    } elseif ($IsMacOS) {
        $globalConfigPath = Join-Path $homeDir "Library/Application Support/Code/User/mcp.json"
    } else {
        $globalConfigPath = Join-Path $homeDir ".config/Code/User/mcp.json"
    }

    if (-not (Test-Path $globalConfigPath)) {
        # Ensure directory exists
        $parentDir = Split-Path $globalConfigPath -Parent
        if (-not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        Write-StatusMessage "Global MCP config file not found. Creating a new one." -Level Info
        New-Item -ItemType File -Path $globalConfigPath -Force | Out-Null
    }

    try {
        $globalConfig = @{ mcpServers = @{} }
        if (Test-Path $globalConfigPath) {
            $content = Get-Content $globalConfigPath -Raw
            if ($content -match "\S") {
                $jsonObj = $content | ConvertFrom-Json
                # Convert PSCustomObject to Hashtable for easier manipulation
                $globalConfig = @{}
                foreach ($prop in $jsonObj.PSObject.Properties) {
                    $globalConfig[$prop.Name] = $prop.Value
                }
            }
        }

        # Handle both 'servers' (old format) and 'mcpServers' (new format)
        # VS Code uses 'mcpServers' in settings.json but 'mcpServers' or 'servers' in mcp.json?
        # The official docs say mcp.json uses "mcpServers" key? No, it says "mcpServers" in settings.json.
        # But for separate mcp.json file, the structure is: { "mcpServers": { ... } }

        if (-not $globalConfig.ContainsKey('mcpServers')) {
            $globalConfig['mcpServers'] = @{}
        }

        # Ensure mcpServers is a hashtable if it came from JSON
        if ($globalConfig['mcpServers'] -is [PSCustomObject]) {
            $serversHash = @{}
            foreach ($prop in $globalConfig['mcpServers'].PSObject.Properties) {
                $serversHash[$prop.Name] = $prop.Value
            }
            $globalConfig['mcpServers'] = $serversHash
        }

        $globalConfig['mcpServers']["aitherzero"] = @{
            "command"      = "node"
            "args"         = @("${WorkspaceRoot}/AitherZero/library/integrations/mcp-server/scripts/start-with-build.mjs")
            "description"  = "AitherZero infrastructure automation - run scripts, playbooks, tests"
            "capabilities" = @{ "resources" = $true; "tools" = $true }
            "env"          = @{ "AITHERZERO_ROOT" = $WorkspaceRoot; "AITHERZERO_NONINTERACTIVE" = "1" }
        }
        $globalConfig['mcpServers']["filesystem"] = @{
            "command"     = "npx"
            "args"        = @("-y", "@modelcontextprotocol/server-filesystem", $WorkspaceRoot)
            "description" = "File system access"
        }
        $globalConfig['mcpServers']["github"] = @{
            "command"     = "npx"
            "args"        = @("-y", "@modelcontextprotocol/server-github")
            "description" = "GitHub API access"
            "env"         = @{ "GITHUB_PERSONAL_ACCESS_TOKEN" = "${env:GITHUB_TOKEN}" }
        }
        $globalConfig['mcpServers']["sequential-thinking"] = @{
            "command"     = "npx"
            "args"        = @("-y", "@modelcontextprotocol/server-sequential-thinking")
            "description" = "Detailed reasoning for complex tasks"
        }

        $globalConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $globalConfigPath -Encoding UTF8
        Write-StatusMessage "Global MCP config updated successfully." -Level Success
    } catch {
        Write-StatusMessage "Failed to update global MCP config: $_" -Level Error
    }
}

# Main execution
try {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  AitherZero MCP Server Setup" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # Determine workspace root
    $workspaceRoot = $env:AITHERZERO_ROOT

    # Validate if the detected root is correct (must contain AitherZero/library/integrations)
    if ($workspaceRoot -and -not (Test-Path (Join-Path $workspaceRoot "AitherZero/library/integrations"))) {
        Write-StatusMessage "AITHERZERO_ROOT ($workspaceRoot) appears incorrect (missing AitherZero/library/integrations). Recalculating." -Level Warning
        $workspaceRoot = $null
    }

    if (-not $workspaceRoot) {
        # Fallback: Calculate from script location
        # Script is in library/automation-scripts/
        $workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Write-StatusMessage "Using calculated workspace root: $workspaceRoot" -Level Info
    }

    # Locate MCP server
    # Try new location first
    $mcpServerPath = Join-Path $workspaceRoot 'AitherZero/library/integrations/mcp-server'
    if (-not (Test-Path $mcpServerPath)) {
        # Try legacy location
        $mcpServerPath = Join-Path $workspaceRoot 'mcp-server'
    }

    if (-not (Test-Path $mcpServerPath)) {
        Write-StatusMessage "MCP server directory not found: $mcpServerPath" -Level Error
        exit 1
    }

    Write-StatusMessage "MCP server location: $mcpServerPath" -Level Info
    Write-Host ""

    # Check if build needed
    $needsBuild = $Force -or -not (Test-MCPServerBuilt -ServerPath $mcpServerPath)

    if ($needsBuild) {
        Write-StatusMessage "Building MCP server..." -Level Info
        if (-not (Build-MCPServer -ServerPath $mcpServerPath)) {
            Write-StatusMessage "MCP server build failed" -Level Error
            exit 1
        }
        Write-Host ""
    } else {
        Write-StatusMessage "MCP server already built (use -Force to rebuild)" -Level Info
        Write-Host ""
    }

    # Validate configuration
    if (-not $SkipValidation) {
        Write-StatusMessage "Validating MCP configuration..." -Level Info
        $configValid = Test-MCPConfiguration -WorkspaceRoot $workspaceRoot

        if (-not $configValid -and $FixConfig) {
            Write-Host ""
            if (Repair-MCPConfiguration -WorkspaceRoot $workspaceRoot) {
                Write-StatusMessage "Configuration repaired successfully" -Level Success
            } else {
                Write-StatusMessage "Failed to repair configuration" -Level Error
            }
        } elseif (-not $configValid) {
            Write-StatusMessage "Run with -FixConfig to automatically repair issues" -Level Warning
        }
        Write-Host ""
    }

    # Update global MCP config
    Update-GlobalMCPConfig -WorkspaceRoot $workspaceRoot

    # Show activation instructions
    Show-ActivationInstruction

    exit 0
} catch {
    Write-StatusMessage "Unexpected error: $_" -Level Error
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
