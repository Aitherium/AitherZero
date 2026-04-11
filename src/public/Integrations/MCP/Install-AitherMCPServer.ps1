function Install-AitherMCPServer {
    <#
    .SYNOPSIS
        Installs and builds the local AitherZero MCP Server
    .DESCRIPTION
        Checks for Node.js, installs dependencies, and builds the MCP server
        located in library/integrations/mcp-server.
    .PARAMETER Force
        Force reinstall/rebuild
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $mcpPath = Join-Path $env:AITHERZERO_ROOT "AitherZero/library/integrations/mcp-server"

    if (-not (Test-Path $mcpPath)) {
        throw "MCP Server source not found at $mcpPath"
    }

    # Check Node.js
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Verbose "Node.js not found. Installing..."
        Install-AitherPackage -SoftwareName "nodejs"

        # Refresh env if needed (in same process might be hard, but Install-AitherPackage tries)
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            throw "Node.js installed but npm command not found. Restart shell."
        }
    }

    Push-Location $mcpPath
    try {
        Write-Verbose "Installing dependencies in $mcpPath..."
        if ($Force) {
            npm install --force
        } else {
            npm install
        }

        if ($LASTEXITCODE -ne 0) { throw "npm install failed" }

        Write-Verbose "Building MCP server..."
        npm run build

        if ($LASTEXITCODE -ne 0) { throw "npm build failed" }

        $entryPoint = Join-Path $mcpPath "dist/index.js"
        if (-not (Test-Path $entryPoint)) {
            throw "Build succeeded but $entryPoint not found."
        }

        Write-Verbose "MCP Server installed successfully."

        # Auto-Register
        Write-Verbose "Registering AitherZero.McpServer..."
        $azRoot = $env:AITHERZERO_ROOT
        if (-not $azRoot) { $azRoot = $PWD.Path } # Fallback

        Set-AitherMCPConfig -Name "AitherZero.McpServer" `
                            -Command "node" `
                            -Args @($entryPoint) `
                            -Env @{ "AITHERZERO_ROOT" = $azRoot } `
                            -Verbose

    }
    finally {
        Pop-Location
    }
}

