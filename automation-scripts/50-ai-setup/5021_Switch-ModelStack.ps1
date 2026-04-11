#Requires -Version 7.0
<#
.SYNOPSIS
    Switch between AitherOS model inference stacks.

.DESCRIPTION
    Orchestrates the full stack switch lifecycle:
    1. Validates the target stack requirements (GPU, Ollama, cloud)
    2. Stops containers that aren't needed
    3. Pulls/ensures Ollama models if required
    4. Calls Genesis /model-stacks/switch to hot-reload routing
    5. Verifies health of all components

    Available stacks (from config/model-stacks.yaml):
      cloud-offload    - Orchestrator GPU + cloud reasoning (DEFAULT)
      elastic-hybrid   - Orchestrator GPU + Elastic CPU (Ollama) + cloud
      ollama-hybrid    - Ollama CPU reflex/reasoning + GPU orchestrator + cloud
      ollama-only      - All CPU (GPU free for other workloads) + cloud

.PARAMETER Stack
    Name of the model stack to activate.

.PARAMETER List
    List all available stacks with details.

.PARAMETER Status
    Show current stack status and health.

.PARAMETER Force
    Skip validation checks.

.EXAMPLE
    .\5021_Switch-ModelStack.ps1 -List

.EXAMPLE
    .\5021_Switch-ModelStack.ps1 -Stack elastic-hybrid

.EXAMPLE
    .\5021_Switch-ModelStack.ps1 -Status

.NOTES
    Category: ai-setup
    Dependencies: Genesis running on port 8001
    Platform: Windows, Linux
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Stack,

    [switch]$List,
    [switch]$Status,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$GenesisUrl = $env:GENESIS_URL ?? "http://localhost:8001"

Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  AitherOS — Model Stack Manager                             ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# ── Helper: Call Genesis API ─────────────────────────────────────────────────
function Invoke-Genesis {
    param([string]$Path, [string]$Method = "Get", $Body)
    $params = @{
        Uri = "$GenesisUrl$Path"
        Method = $Method
        TimeoutSec = 30
        ContentType = "application/json"
    }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json) }
    try {
        return Invoke-RestMethod @params
    } catch {
        Write-Error "Genesis API error ($Path): $_"
        return $null
    }
}

# ── LIST ─────────────────────────────────────────────────────────────────────
if ($List) {
    $data = Invoke-Genesis "/model-stacks"
    if (-not $data) { return }

    Write-Host "  Active: $($data.active)`n" -ForegroundColor Green

    foreach ($s in $data.stacks) {
        $marker = if ($s.active) { " ◄ ACTIVE" } else { "" }
        $color = if ($s.active) { "Green" } else { "White" }

        Write-Host "  ┌─ $($s.name)$marker" -ForegroundColor $color
        Write-Host "  │  $($s.description)" -ForegroundColor Gray
        Write-Host "  │  GPU: $(if ($s.requires_gpu) { "$($s.vram_estimate_gb)GB VRAM" } else { 'none' })  RAM: $(if ($s.ram_estimate_gb) { "$($s.ram_estimate_gb)GB" } else { '-' })  Ollama: $($s.requires_ollama)" -ForegroundColor DarkGray
        Write-Host "  │  Tiers: $($s.tiers -join ' → ')" -ForegroundColor DarkGray
        if ($s.tool_backends.Count -gt 0) {
            Write-Host "  │  Tools: $($s.tool_backends -join ', ')" -ForegroundColor DarkGray
        }
        Write-Host "  └────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
    }
    return
}

# ── STATUS ───────────────────────────────────────────────────────────────────
if ($Status) {
    $status = Invoke-Genesis "/model-stacks/status"
    if (-not $status) { return }

    Write-Host "  Stack:  $($status.active_stack)" -ForegroundColor Green

    if ($null -ne $status.ollama_running) {
        $ollamaColor = if ($status.ollama_running) { "Green" } else { "Red" }
        Write-Host "  Ollama: $(if ($status.ollama_running) { 'running' } else { 'NOT RUNNING' })" -ForegroundColor $ollamaColor
    }

    foreach ($kv in $status.ollama_models.GetEnumerator()) {
        $modelColor = if ($kv.Value) { "Green" } else { "Red" }
        Write-Host "  Model:  $($kv.Key) — $(if ($kv.Value) { 'ready' } else { 'NOT PULLED' })" -ForegroundColor $modelColor
    }

    # Check core services
    $services = @(
        @{ Name = "Orchestrator"; Url = "http://localhost:8120/health" },
        @{ Name = "Genesis";      Url = "http://localhost:8001/health" },
        @{ Name = "MicroScheduler"; Url = "http://localhost:8150/health" },
        @{ Name = "Embeddings";   Url = "http://localhost:8209/health" }
    )

    Write-Host ""
    foreach ($svc in $services) {
        try {
            $null = Invoke-RestMethod -Uri $svc.Url -TimeoutSec 3
            Write-Host "  $($svc.Name): healthy" -ForegroundColor Green
        } catch {
            Write-Host "  $($svc.Name): DOWN" -ForegroundColor Red
        }
    }
    return
}

# ── SWITCH ───────────────────────────────────────────────────────────────────
if (-not $Stack) {
    Write-Host "  Usage:" -ForegroundColor Yellow
    Write-Host "    .\5021_Switch-ModelStack.ps1 -List              # Show stacks"
    Write-Host "    .\5021_Switch-ModelStack.ps1 -Stack <name>      # Switch stack"
    Write-Host "    .\5021_Switch-ModelStack.ps1 -Status            # Health check"
    return
}

Write-Host "  → Switching to stack: $Stack" -ForegroundColor Yellow

# Pre-flight: check if target stack needs Ollama
$stacks = Invoke-Genesis "/model-stacks"
$target = $stacks.stacks | Where-Object { $_.name -eq $Stack }

if (-not $target) {
    Write-Error "Unknown stack '$Stack'. Available: $($stacks.stacks.name -join ', ')"
    return
}

if ($target.requires_ollama -and -not $Force) {
    $ollamaRunning = $false
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 3
        $ollamaRunning = $true
    } catch {}

    if (-not $ollamaRunning) {
        Write-Host "  ⚠ Stack '$Stack' requires Ollama but it's not running." -ForegroundColor Yellow
        Write-Host "  → Run: .\5020_Setup-Ollama.ps1" -ForegroundColor Yellow
        Write-Host "  → Or use -Force to skip this check" -ForegroundColor Yellow
        return
    }
}

# Execute switch via Genesis API
$result = Invoke-Genesis "/model-stacks/switch" -Method "Post" -Body @{ stack = $Stack }

if (-not $result -or -not $result.success) {
    Write-Error "Stack switch failed: $($result.message ?? 'no response from Genesis')"
    return
}

Write-Host "`n  ✓ Switched: $($result.previous) → $($result.stack)" -ForegroundColor Green

if ($result.lifecycle) {
    Write-Host "`n  Lifecycle:" -ForegroundColor DarkGray
    foreach ($entry in $result.lifecycle) {
        $color = if ($entry -match 'FAILED|WARNING') { "Yellow" } else { "DarkGray" }
        Write-Host "    $entry" -ForegroundColor $color
    }
}

Write-Host "`n  ✓ Routing applied: $($result.routing_applied)" -ForegroundColor Green
Write-Host ""
