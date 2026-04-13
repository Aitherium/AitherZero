<#
.SYNOPSIS
    Deploys AitherOS Edge Node with Cloudflare Tunnel redundancy.

.DESCRIPTION
    Sets up a secondary AitherNode + Cloudflare Tunnel connector on a remote machine
    for disaster recovery and worker usage reduction.

    The same tunnel token creates a multi-connector HA setup where Cloudflare
    automatically load-balances and fails over between connectors.

    Components deployed:
      - cloudflared (tunnel connector, same token = automatic HA)
      - Ollama (local LLM inference)
      - AitherNode (standalone MCP server, 30+ tools)
      - AitherVeil (optional, --WithDashboard)

.PARAMETER ComputerName
    Target host (IP or hostname). Default: localhost (local deployment).

.PARAMETER TunnelToken
    Cloudflare Tunnel token. Uses CLOUDFLARE_TUNNEL_TOKEN env if not provided.

.PARAMETER Identity
    Agent identity from config/identities/. Default: genesis.

.PARAMETER RemoteLLMUrl
    Primary cluster MicroScheduler URL for remote-first LLM routing.
    If set, EdgeLLMRouter tries remote first, falls back to local Ollama.

.PARAMETER WithDashboard
    Also deploy AitherVeil dashboard for web DR.

.PARAMETER PrimaryGenesisUrl
    Genesis URL for Veil to connect to. Only used with -WithDashboard.

.PARAMETER Pull
    Pull latest images before starting.

.PARAMETER Down
    Stop and remove edge services.

.PARAMETER Status
    Show status of edge services.

.EXAMPLE
    # Local edge deployment
    .\3106_Deploy-EdgeNode.ps1 -TunnelToken $token

    # Remote deployment with LLM fallback
    .\3106_Deploy-EdgeNode.ps1 -ComputerName edge-box -TunnelToken $token `
        -RemoteLLMUrl http://primary:8150

    # With web dashboard
    .\3106_Deploy-EdgeNode.ps1 -WithDashboard -PrimaryGenesisUrl https://demo.aitherium.com

    # Check status
    .\3106_Deploy-EdgeNode.ps1 -Status

    # Tear down
    .\3106_Deploy-EdgeNode.ps1 -Down
#>

[CmdletBinding(DefaultParameterSetName = 'Deploy')]
param(
    [string]$ComputerName = "localhost",

    [Parameter(ParameterSetName = 'Deploy')]
    [string]$TunnelToken = $env:CLOUDFLARE_TUNNEL_TOKEN,

    [Parameter(ParameterSetName = 'Deploy')]
    [string]$Identity = "genesis",

    [Parameter(ParameterSetName = 'Deploy')]
    [string]$RemoteLLMUrl = "",

    [Parameter(ParameterSetName = 'Deploy')]
    [switch]$WithDashboard,

    [Parameter(ParameterSetName = 'Deploy')]
    [string]$PrimaryGenesisUrl = "http://localhost:8001",

    [Parameter(ParameterSetName = 'Deploy')]
    [switch]$Pull,

    [Parameter(ParameterSetName = 'Down')]
    [switch]$Down,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot/../../../../").Path
$composeFile = Join-Path $repoRoot "docker-compose.edge.yml"

if (-not (Test-Path $composeFile)) {
    Write-Error "docker-compose.edge.yml not found at $composeFile"
    return
}

# ── Build command base ─────────────────────────────────────────────────────
function Get-ComposeCmd {
    $cmd = "docker compose -f `"$composeFile`""
    if ($WithDashboard) {
        $cmd += " --profile dashboard"
    }
    return $cmd
}

# ── Status ─────────────────────────────────────────────────────────────────
if ($Status) {
    Write-Host "`n=== AitherOS Edge Node Status ===" -ForegroundColor Cyan

    $base = Get-ComposeCmd
    Invoke-Expression "$base ps"

    Write-Host "`n--- Health Checks ---" -ForegroundColor Yellow

    # Check AitherNode
    try {
        $nodeHealth = Invoke-RestMethod -Uri "http://${ComputerName}:8090/health" -TimeoutSec 5 -ErrorAction Stop
        $status = if ($nodeHealth.healthy) { "HEALTHY" } else { "DEGRADED" }
        $color = if ($nodeHealth.healthy) { "Green" } else { "Yellow" }
        Write-Host "  AitherNode: $status (identity=$($nodeHealth.identity), backend=$($nodeHealth.backend))" -ForegroundColor $color
    } catch {
        Write-Host "  AitherNode: UNREACHABLE" -ForegroundColor Red
    }

    # Check Ollama
    try {
        $ollamaResp = Invoke-RestMethod -Uri "http://${ComputerName}:11434/api/tags" -TimeoutSec 5 -ErrorAction Stop
        $modelCount = ($ollamaResp.models | Measure-Object).Count
        Write-Host "  Ollama:     HEALTHY ($modelCount models loaded)" -ForegroundColor Green
    } catch {
        Write-Host "  Ollama:     UNREACHABLE" -ForegroundColor Red
    }

    # Check cloudflared
    try {
        $tunnelInfo = docker compose -f $composeFile exec cloudflared cloudflared tunnel info 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Tunnel:     CONNECTED" -ForegroundColor Green
        } else {
            Write-Host "  Tunnel:     DISCONNECTED" -ForegroundColor Red
        }
    } catch {
        Write-Host "  Tunnel:     UNKNOWN" -ForegroundColor Yellow
    }

    return
}

# ── Down ───────────────────────────────────────────────────────────────────
if ($Down) {
    Write-Host "Stopping edge services..." -ForegroundColor Yellow
    $base = Get-ComposeCmd
    Invoke-Expression "$base down"
    Write-Host "Edge services stopped." -ForegroundColor Green
    return
}

# ── Deploy ─────────────────────────────────────────────────────────────────
if (-not $TunnelToken) {
    Write-Error @"
Cloudflare Tunnel token is required.

Get it from: Cloudflare Dashboard → Zero Trust → Networks → Tunnels → aitheros-demo → Configure → Token

Then run:
  `$env:CLOUDFLARE_TUNNEL_TOKEN = 'your-token'
  .\3106_Deploy-EdgeNode.ps1

Or pass directly:
  .\3106_Deploy-EdgeNode.ps1 -TunnelToken 'your-token'
"@
    return
}

Write-Host "`n=== Deploying AitherOS Edge Node ===" -ForegroundColor Cyan
Write-Host "  Target:    $ComputerName"
Write-Host "  Identity:  $Identity"
Write-Host "  Dashboard: $WithDashboard"
Write-Host "  Remote LLM: $(if ($RemoteLLMUrl) { $RemoteLLMUrl } else { 'disabled (local only)' })"
Write-Host ""

# Set environment
$env:CLOUDFLARE_TUNNEL_TOKEN = $TunnelToken
$env:AGENT_IDENTITY = $Identity
$env:AITHER_REMOTE_LLM_URL = $RemoteLLMUrl
$env:PRIMARY_GENESIS_URL = $PrimaryGenesisUrl

$base = Get-ComposeCmd

# Pull if requested
if ($Pull) {
    Write-Host "Pulling latest images..." -ForegroundColor Yellow
    Invoke-Expression "$base pull"
}

# Build and start
Write-Host "Building and starting edge services..." -ForegroundColor Yellow
Invoke-Expression "$base up -d --build"

# Wait for health
Write-Host "`nWaiting for services to become healthy..." -ForegroundColor Yellow
$attempts = 0
$maxAttempts = 30
$healthy = $false

while ($attempts -lt $maxAttempts -and -not $healthy) {
    Start-Sleep -Seconds 5
    $attempts++
    try {
        $resp = Invoke-RestMethod -Uri "http://${ComputerName}:8090/health" -TimeoutSec 3 -ErrorAction Stop
        if ($resp.healthy) {
            $healthy = $true
        }
    } catch {
        Write-Host "  Attempt $attempts/$maxAttempts — waiting..." -ForegroundColor Gray
    }
}

if ($healthy) {
    Write-Host "`nEdge node deployed successfully!" -ForegroundColor Green
    Write-Host @"

  Services running:
    - cloudflared: Tunnel connector (auto-HA with primary)
    - Ollama:      http://${ComputerName}:11434
    - AitherNode:  http://${ComputerName}:8090
$(if ($WithDashboard) { "    - AitherVeil:  http://${ComputerName}:3000" })

  Next steps:
    1. Sync tunnel routes:  pwsh 3040_Sync-CloudflareTunnel.ps1
    2. Create DNS CNAME:    edge.aitherium.com → tunnel-id.cfargotunnel.com
    3. Pull an Ollama model: docker compose -f docker-compose.edge.yml exec ollama ollama pull llama3.2
    4. Test MCP endpoint:   curl http://${ComputerName}:8090/health

  Tunnel HA:
    Both connectors share the same tunnel. Cloudflare auto-distributes
    traffic and fails over if either connector goes down.
"@
} else {
    Write-Warning "Edge node started but health check not yet passing. Check logs:"
    Write-Host "  docker compose -f docker-compose.edge.yml logs -f aithernode" -ForegroundColor Yellow
}
