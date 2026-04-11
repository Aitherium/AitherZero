function Set-AitherMCPConfig {
    <#
    .SYNOPSIS
        Registers an MCP server in the configuration
    .PARAMETER Name
        Server name (e.g., "aitherzero")
    .PARAMETER Command
        Executable command (e.g., "node")
    .PARAMETER Args
        Arguments array
    .PARAMETER Env
        Environment variables hashtable
    .PARAMETER ConfigFile
        Path to config file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [string[]]$Args,
        
        [hashtable]$Env,
        
        [string]$ConfigFile
    )

    if (-not $ConfigFile) {
        $ConfigFile = Join-Path $env:AITHERZERO_ROOT ".vscode/mcp.json"
    }

    $config = @{ mcpServers = @{} }
    if (Test-Path $ConfigFile) {
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        if (-not $config.mcpServers) { $config.mcpServers = @{} }
    }

    $serverConfig = @{
        command = $Command
        args = $Args
    }
    if ($Env) {
        $serverConfig.env = $Env
    }

    $config.mcpServers[$Name] = $serverConfig

    $dir = Split-Path $ConfigFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $config | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile
    Write-Verbose "Registered MCP server '$Name' in $ConfigFile"
}

