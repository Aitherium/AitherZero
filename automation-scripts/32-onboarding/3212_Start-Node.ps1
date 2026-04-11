#Requires -Version 7.0

<#
.SYNOPSIS
    Start AitherNode MCP server as a background process.

.DESCRIPTION
    Starts the AitherNode MCP server which bridges local IDE tools
    to Elysium cloud services. Runs via the ADK server command.

    Exit Codes:
        0 - Node started
        1 - ADK not installed
        2 - Failed to start

.PARAMETER ApiKey
    ACTA API key for cloud auth.

.PARAMETER TenantSlug
    Tenant slug for identity.

.PARAMETER Port
    MCP server port. Default: 8080.

.PARAMETER DryRun
    Preview only.

.NOTES
    Stage: Onboarding
    Order: 3212
    Dependencies: 3210
    Tags: onboarding, node, mcp, start
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ApiKey = '',
    [string]$TenantSlug = '',
    [int]$Port = 8080,
    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Name, [string]$Status = 'running')
    $icon = switch ($Status) { 'done' { '[OK]' } 'fail' { '[FAIL]' } 'skip' { '[SKIP]' } default { '[..]' } }
    Write-Host "$icon $Name" -ForegroundColor $(switch ($Status) { 'done' { 'Green' } 'fail' { 'Red' } 'skip' { 'Yellow' } default { 'Cyan' } })
}

# ── Check ADK installed ──────────────────────────────────────────────────

$adk = Get-Command aither -ErrorAction SilentlyContinue
if (-not $adk) {
    $adk = Get-Command adk-serve -ErrorAction SilentlyContinue
}
if (-not $adk) {
    Write-Step "Check ADK" 'fail'
    Write-Error "aither-adk not installed. Run: pip install aither-adk"
    exit 1
}

Write-Step "Check ADK" 'done'

# ── Check if already running ─────────────────────────────────────────────

try {
    $health = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 2 -ErrorAction Stop
    Write-Step "AitherNode already running on port $Port" 'done'
    Write-Host "  Service: $($health.service ?? 'AitherNode')"
    exit 0
}
catch {
    # Not running — we'll start it
}

# ── Start node ─���─────────────────────────────────────────────────────────

Write-Step "Start AitherNode" 'running'

if ($DryRun) { Write-Step "Start AitherNode (DRY RUN)" 'skip'; exit 0 }

# Set env vars
$env:AITHER_API_KEY = $ApiKey
$env:AITHER_TENANT_ID = "tnt_$($TenantSlug.Replace('-', '_'))"
$env:AITHER_STANDALONE = "1"
$env:MCP_PORT = "$Port"

# Start as background process
try {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        Start-Process -FilePath "adk-serve" -ArgumentList "--port", "$Port" -WindowStyle Hidden -PassThru | Out-Null
    }
    else {
        Start-Process -FilePath "nohup" -ArgumentList "adk-serve", "--port", "$Port" -RedirectStandardOutput "/dev/null" -PassThru | Out-Null
    }

    # Wait for health
    Start-Sleep -Seconds 3
    $maxRetries = 5
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $health = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 2 -ErrorAction Stop
            Write-Step "Start AitherNode (port $Port)" 'done'
            Write-Host "  MCP server: http://localhost:$Port"
            Write-Host "  SSE endpoint: http://localhost:$Port/sse"
            exit 0
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }
    Write-Step "Start AitherNode (started but health check pending)" 'skip'
    Write-Host "  Node may still be starting. Check: http://localhost:$Port/health"
}
catch {
    Write-Step "Start AitherNode" 'fail'
    Write-Error "Failed to start: $_"
    exit 2
}

exit 0
