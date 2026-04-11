function Get-AitherMCPConfig {
    <#
    .SYNOPSIS
        Reads MCP server configuration
    .PARAMETER ConfigFile
        Path to the config file (defaults to .vscode/mcp.json)
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigFile
    )

    if (-not $ConfigFile) {
        $ConfigFile = Join-Path $env:AITHERZERO_ROOT ".vscode/mcp.json"
    }

    if (Test-Path $ConfigFile) {
        return Get-Content $ConfigFile -Raw | ConvertFrom-Json
    } else {
        Write-Verbose "Config file not found: $ConfigFile"
        return @{ mcpServers = @{} }
    }
}

