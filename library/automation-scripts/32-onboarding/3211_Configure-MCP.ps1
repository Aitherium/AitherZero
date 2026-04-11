#Requires -Version 7.0

<#
.SYNOPSIS
    Auto-configure MCP servers for Claude Code, Cursor, OpenClaw, and VS Code.

.DESCRIPTION
    Detects installed IDEs and configures them to use AitherNode as their
    MCP server. This bridges local IDE tools to Elysium cloud services.

    Exit Codes:
        0 - At least one IDE configured
        1 - No IDEs detected

.PARAMETER NodePort
    AitherNode MCP server port. Default: 8080.

.PARAMETER DryRun
    Preview only.

.NOTES
    Stage: Onboarding
    Order: 3211
    Dependencies: 3210
    Tags: onboarding, mcp, claude-code, cursor, openclaw, ide
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$NodePort = 8080,
    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Name, [string]$Status = 'running')
    $icon = switch ($Status) { 'done' { '[OK]' } 'fail' { '[FAIL]' } 'skip' { '[SKIP]' } default { '[..]' } }
    Write-Host "$icon $Name" -ForegroundColor $(switch ($Status) { 'done' { 'Green' } 'fail' { 'Red' } 'skip' { 'Yellow' } default { 'Cyan' } })
}

$mcp_url = "http://localhost:$NodePort"
$configured = @()

# ── Claude Code ──────────────────────────────────────────────────────────

$claudeDir = Join-Path $HOME '.claude'
if (Test-Path $claudeDir) {
    Write-Step "Configure Claude Code" 'running'
    $mcpJson = Join-Path $claudeDir '.mcp.json'
    $mcpConfig = @{
        mcpServers = @{
            aitheros = @{
                command = "npx"
                args    = @("-y", "aither-mcp-server")
                disabled = $false
            }
        }
    }

    if ($DryRun) { Write-Step "Configure Claude Code (DRY RUN)" 'skip' }
    else {
        if (Test-Path $mcpJson) {
            $existing = Get-Content $mcpJson -Raw | ConvertFrom-Json -AsHashtable
            if (-not $existing.mcpServers.ContainsKey('aitheros')) {
                $existing.mcpServers['aitheros'] = $mcpConfig.mcpServers.aitheros
                $existing | ConvertTo-Json -Depth 5 | Set-Content $mcpJson
                Write-Step "Configure Claude Code (added to existing)" 'done'
            }
            else {
                Write-Step "Configure Claude Code (already configured)" 'done'
            }
        }
        else {
            $mcpConfig | ConvertTo-Json -Depth 5 | Set-Content $mcpJson
            Write-Step "Configure Claude Code ($mcpJson)" 'done'
        }
        $configured += 'claude-code'
    }
}
else {
    Write-Step "Claude Code — not detected" 'skip'
}

# ── Cursor ───────────────────────────────────────────────────────────────

$cursorDir = Join-Path $HOME '.cursor'
if (Test-Path $cursorDir) {
    Write-Step "Configure Cursor" 'running'
    $cursorMcp = Join-Path $cursorDir 'mcp.json'
    $cursorConfig = @{
        mcpServers = @{
            aitheros = @{ url = "$mcp_url/sse" }
        }
    }

    if ($DryRun) { Write-Step "Configure Cursor (DRY RUN)" 'skip' }
    else {
        if (Test-Path $cursorMcp) {
            $existing = Get-Content $cursorMcp -Raw | ConvertFrom-Json -AsHashtable
            if (-not $existing.mcpServers.ContainsKey('aitheros')) {
                $existing.mcpServers['aitheros'] = $cursorConfig.mcpServers.aitheros
                $existing | ConvertTo-Json -Depth 5 | Set-Content $cursorMcp
                Write-Step "Configure Cursor (added)" 'done'
            }
            else { Write-Step "Configure Cursor (already configured)" 'done' }
        }
        else {
            $cursorConfig | ConvertTo-Json -Depth 5 | Set-Content $cursorMcp
            Write-Step "Configure Cursor ($cursorMcp)" 'done'
        }
        $configured += 'cursor'
    }
}
else {
    Write-Step "Cursor — not detected" 'skip'
}

# ── OpenClaw ─────────────────────────────────────────────────────────────

$openclawDir = Join-Path $HOME '.openclaw'
$openclawConfig = Join-Path $openclawDir 'openclaw.json'
if (Test-Path $openclawConfig) {
    Write-Step "Configure OpenClaw" 'running'

    if ($DryRun) { Write-Step "Configure OpenClaw (DRY RUN)" 'skip' }
    else {
        $oc = Get-Content $openclawConfig -Raw | ConvertFrom-Json -AsHashtable
        $servers = $oc['mcpServers'] ?? @{}
        $hasAither = $servers.Keys | Where-Object { $_ -match 'aither' }
        if (-not $hasAither) {
            $servers['aither_mcp_configured'] = @{
                command  = "npx"
                args     = @("-y", "aither-mcp-server")
                disabled = $false
            }
            $oc['mcpServers'] = $servers
            $oc | ConvertTo-Json -Depth 5 | Set-Content $openclawConfig
            Write-Step "Configure OpenClaw (integrated)" 'done'
        }
        else { Write-Step "Configure OpenClaw (already integrated)" 'done' }
        $configured += 'openclaw'
    }
}
else {
    Write-Step "OpenClaw — not detected" 'skip'
}

# ── VS Code (current project) ───────────────────────────────────────────

$vscodeDir = Join-Path (Get-Location) '.vscode'
if (Test-Path $vscodeDir) {
    Write-Step "Configure VS Code" 'running'
    $vscodeMcp = Join-Path $vscodeDir 'mcp.json'
    if (-not (Test-Path $vscodeMcp)) {
        if (-not $DryRun) {
            @{ servers = @{ aitheros = @{ url = "$mcp_url/sse" } } } | ConvertTo-Json -Depth 5 | Set-Content $vscodeMcp
            Write-Step "Configure VS Code (.vscode/mcp.json)" 'done'
            $configured += 'vscode'
        }
    }
    else { Write-Step "Configure VS Code (already exists)" 'done'; $configured += 'vscode' }
}

# ── Summary ──────────────────────────────────────────────────────────────

Write-Host ""
if ($configured.Count -gt 0) {
    Write-Host "MCP configured for: $($configured -join ', ')" -ForegroundColor Green
    Write-Host "  Server: $mcp_url"
}
else {
    Write-Host "No IDEs detected. Configure manually:" -ForegroundColor Yellow
    Write-Host "  MCP server: $mcp_url/sse"
}
Write-Host ""

exit 0
