#Requires -Version 7.0

<#
.SYNOPSIS
    Toggle AitherOS inference mode between hybrid (vLLM + Ollama) and ollama-only.

.DESCRIPTION
    Sets AITHER_INFERENCE_MODE in the .env file and starts/stops the vLLM containers.
    Manages the full elastic Nemotron architecture including hot-swap of 9B/12B variants.

    Modes:
      hybrid  - vLLM at 80% VRAM (fast PagedAttention) + Ollama for embeddings/vision/fallback.
                Best throughput. ComfyUI gets ~6GB (--lowvram mode).
      ollama  - Ollama only. Full VRAM flexibility. Hot-swap any model.
                ComfyUI gets full GPU. Slower inference (no continuous batching).

    HYBRID VRAM BUDGET (RTX 5090 32GB):
      Ollama embed:  ~0.6GB (nomic-embed-text, always loaded)
      Ollama chat:   ~4.5GB GPU layers (or 0 with -OllamaCPUOnly)
      vLLM 6B:       ~7GB   (Nemotron-Elastic 6B — lightning fast neurons)
      vLLM 9B:       ~10GB  (Nemotron-Elastic 9B — balanced orchestration)
      vLLM 12B:      ~12GB  (Nemotron-Elastic 12B — max quality reasoning)
      System:        ~2GB   reserved
      Free:          varies (available for ComfyUI image generation)

    Exit Codes:
      0 - Success
      1 - Docker not available or daemon not running
      2 - Container start/stop failure

.PARAMETER Mode
    Target inference mode: hybrid or ollama. Omit to show current status.

.PARAMETER NemotronSize
    Nemotron Elastic model size for vLLM: 6b, 9b, or 12b (default: 6b).
    6b = fastest neurons, leaves most VRAM for ComfyUI.

.PARAMETER OllamaCPUOnly
    Force Ollama to CPU-only inference (no GPU layers).
    Maximizes GPU VRAM for vLLM + ComfyUI.
    Ollama uses your CPU (Ryzen 9 9950X3D) which is still fast for orchestration.

.PARAMETER NoRestart
    Set env var only, don't start/stop vLLM or restart services.

.PARAMETER DryRun
    Show what would change without making changes.

.PARAMETER Benchmark
    After switching mode, run the inference benchmark suite.
    Equivalent to: 8010_Benchmark-InferenceModes.ps1 -Modes <current>

.EXAMPLE
    .\4007_Set-InferenceMode.ps1
    # Show current mode and VRAM budget

.EXAMPLE
    .\4007_Set-InferenceMode.ps1 -Mode ollama
    # Switch to Ollama-only mode (stops vLLM, frees ~26GB VRAM)

.EXAMPLE
    .\4007_Set-InferenceMode.ps1 -Mode hybrid
    # Switch to hybrid mode (starts vLLM 6B + VLLMSwap, Ollama stays on GPU)

.EXAMPLE
    .\4007_Set-InferenceMode.ps1 -Mode hybrid -OllamaCPUOnly -NemotronSize 6b
    # Maximum GPU for vLLM: Ollama on CPU, vLLM 6B on GPU (~7GB), ~23GB free for ComfyUI

.NOTES
    Stage: Lifecycle
    Order: 4007
    Dependencies: Docker, docker-compose.aitheros.yml
    Tags: inference, vllm, ollama, gpu, hybrid, elastic, nemotron
    AllowParallel: false
    Platform: Windows, Linux, macOS
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('hybrid', 'ollama')]
    [string]$Mode,

    [ValidateSet('6b', '9b', '12b')]
    [string]$NemotronSize = '6b',

    [switch]$OllamaCPUOnly,

    [switch]$NoRestart,

    [switch]$DryRun,

    [switch]$Benchmark
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Init ─────────────────────────────────────────────────────────────────────
. "$PSScriptRoot/../_init.ps1"

$EnvFile     = Join-Path $projectRoot ".env"
$ComposeFile = Join-Path $projectRoot "docker-compose.aitheros.yml"

# ─── VRAM budget estimates (MB) ──────────────────────────────────────────────
$VRAMEstimates = @{
    'system'       = 2048
    'ollama_embed' = 600
    'ollama_chat'  = 4500
    'deepseek_14b' = 10000   # DeepSeek-R1 14B on vLLM (~10GB)
    'total'        = 32768
}

# ─── Helper: Show VRAM breakdown ─────────────────────────────────────────────
function Show-VRAMBudget {
    param([string]$InferenceMode, [string]$Size, [bool]$CpuOnly)

    $vllm   = $VRAMEstimates["deepseek_14b"]
    $ollama = if ($CpuOnly) { $VRAMEstimates.ollama_embed } else { $VRAMEstimates.ollama_embed + $VRAMEstimates.ollama_chat }
    $system = $VRAMEstimates.system
    $total  = $VRAMEstimates.total

    if ($InferenceMode -eq 'ollama') {
        $used = $system + $ollama
        $free = $total - $used
        Write-Host "  VRAM Budget (RTX 5090 32GB):" -ForegroundColor Cyan
        Write-Host "    Ollama:  ~${ollama}MB (dynamic, hot-swap)" -ForegroundColor Green
        Write-Host "    System:  ~${system}MB reserved"
        Write-Host "    Free:    ~${free}MB" -ForegroundColor Green
    } else {
        $used = $system + $vllm + $ollama
        $free = $total - $used
        Write-Host "  VRAM Budget (RTX 5090 32GB):" -ForegroundColor Cyan
        Write-Host "    vLLM:    ~${vllm}MB (DeepSeek-R1 14B)" -ForegroundColor Yellow
        if ($CpuOnly) {
            Write-Host "    Ollama:  ~$($VRAMEstimates.ollama_embed)MB (embed only, CPU inference)" -ForegroundColor Cyan
        } else {
            Write-Host "    Ollama:  ~${ollama}MB (embed + chat GPU layers)" -ForegroundColor Cyan
        }
        Write-Host "    System:  ~${system}MB reserved"
        $color = if ($free -gt 10000) { 'Green' } elseif ($free -gt 5000) { 'Yellow' } else { 'Red' }
        Write-Host "    Free:    ~${free}MB (available for ComfyUI)" -ForegroundColor $color
    }
    Write-Host ""
}

# ─── Helper: Read current mode from .env ─────────────────────────────────────
function Get-CurrentMode {
    if (Test-Path $EnvFile) {
        $envContent = Get-Content $EnvFile -Raw
        if ($envContent -match 'AITHER_INFERENCE_MODE\s*=\s*(\w+)') {
            return $Matches[1].Trim().ToLower()
        }
    }
    $envVar = $env:AITHER_INFERENCE_MODE
    if ($envVar) { return $envVar.Trim().ToLower() }
    return "hybrid"  # default
}

# ─── Helper: Update a key=value in .env ──────────────────────────────────────
function Set-EnvValue {
    param([string]$Key, [string]$Value, [string]$Content)

    if ($Content -match "$Key\s*=") {
        return $Content -replace "$Key\s*=\s*\S+", "$Key=$Value"
    } else {
        return $Content + "`n$Key=$Value`n"
    }
}

# ─── Helper: Verify Docker is available ──────────────────────────────────────
function Test-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "  ❌ Docker is not installed." -ForegroundColor Red
        return $false
    }
    try {
        docker info 2>&1 | Out-Null
        return $true
    } catch {
        Write-Host "  ❌ Docker daemon is not running." -ForegroundColor Red
        return $false
    }
}

# ============================================================================
# STATUS DISPLAY (no -Mode specified)
# ============================================================================

$currentMode = Get-CurrentMode

if (-not $Mode) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                  INFERENCE MODE STATUS                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Current mode: " -NoNewline -ForegroundColor White
    if ($currentMode -eq "hybrid") {
        Write-Host "hybrid" -ForegroundColor Green -NoNewline
        Write-Host " (vLLM + Ollama)" -ForegroundColor Gray
    } else {
        Write-Host "ollama" -ForegroundColor Yellow -NoNewline
        Write-Host " (Ollama only)" -ForegroundColor Gray
    }

    # Check container status
    $vllmStatus = docker ps --filter "name=aither-vllm" --filter "name=aither-vllm$" --format "{{.Status}}" 2>$null
    $swapStatus = docker ps --filter "name=aither-vllm-swap" --format "{{.Status}}" 2>$null

    Write-Host "  vLLM 6B:      " -NoNewline -ForegroundColor White
    if ($vllmStatus) {
        Write-Host "running ($vllmStatus)" -ForegroundColor Green
    } else {
        Write-Host "stopped" -ForegroundColor DarkGray
    }

    Write-Host "  VLLMSwap:     " -NoNewline -ForegroundColor White
    if ($swapStatus) {
        Write-Host "running ($swapStatus)" -ForegroundColor Green
    } else {
        Write-Host "stopped" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  Usage:" -ForegroundColor Yellow
    Write-Host "    4007_Set-InferenceMode.ps1 -Mode hybrid     # vLLM + Ollama (fast)" -ForegroundColor Gray
    Write-Host "    4007_Set-InferenceMode.ps1 -Mode ollama     # Ollama only (flexible)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Hybrid options:" -ForegroundColor Yellow
    Write-Host "    -NemotronSize 6b|9b|12b   # vLLM model size (default: 6b)" -ForegroundColor Gray
    Write-Host "    -OllamaCPUOnly            # Force Ollama to CPU (max GPU for vLLM)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  VRAM management:" -ForegroundColor Yellow
    Write-Host "    python scripts/vllm_vram_manager.py pause    # Free GPU for ComfyUI" -ForegroundColor Gray
    Write-Host "    python scripts/vllm_vram_manager.py resume   # Restart vLLM after images" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Benchmark all modes:" -ForegroundColor Yellow
    Write-Host "    .\8010_Benchmark-InferenceModes.ps1              # All modes (PowerShell)" -ForegroundColor Gray
    Write-Host "    .\8010_Benchmark-InferenceModes.ps1 -Quick       # Fast (1 run)" -ForegroundColor Gray
    Write-Host "    python scripts/benchmark_all_modes.py --quick    # Python direct" -ForegroundColor Gray
    Write-Host "    python scripts/benchmark_all_modes.py --modes 1,5  # Ollama vs Hybrid" -ForegroundColor Gray
    Write-Host ""
    Show-VRAMBudget -InferenceMode $currentMode -Size $NemotronSize -CpuOnly:$OllamaCPUOnly
    exit 0
}

# ============================================================================
# MODE SWITCH
# ============================================================================

# No-op if already in target mode
if ($Mode -eq $currentMode) {
    Write-Host "✅ Already in '$Mode' mode. Nothing to do." -ForegroundColor Green
    exit 0
}

# DryRun / WhatIf guard
if ($DryRun -or -not $PSCmdlet.ShouldProcess("Inference mode", "Switch from '$currentMode' to '$Mode'")) {
    Write-Host ""
    Write-Host "  DRY RUN: Would switch $currentMode → $Mode" -ForegroundColor Yellow
    Write-Host "           NemotronSize=$NemotronSize, OllamaCPUOnly=$OllamaCPUOnly" -ForegroundColor Gray
    Show-VRAMBudget -InferenceMode $Mode -Size $NemotronSize -CpuOnly:$OllamaCPUOnly
    exit 0
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║              SWITCHING INFERENCE MODE                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  $currentMode → $Mode" -ForegroundColor White
Write-Host ""

# ─── Update .env file ────────────────────────────────────────────────────────
Write-Host "📝 Updating .env file..." -ForegroundColor Yellow

if (Test-Path $EnvFile) {
    $envContent = Get-Content $EnvFile -Raw
    $envContent = Set-EnvValue -Key 'AITHER_INFERENCE_MODE' -Value $Mode -Content $envContent

    if ($Mode -eq 'hybrid') {
        $envContent = Set-EnvValue -Key 'NEMOTRON_SIZE' -Value $NemotronSize -Content $envContent
    }

    Set-Content $EnvFile -Value $envContent.TrimEnd() -NoNewline
} else {
    "AITHER_INFERENCE_MODE=$Mode`nNEMOTRON_SIZE=$NemotronSize" | Set-Content $EnvFile
}

$env:AITHER_INFERENCE_MODE = $Mode
Write-Host "   ✅ .env updated (mode=$Mode, nemotron=$NemotronSize)" -ForegroundColor Green

# ─── Ollama CPU-only (ALWAYS — vLLM exclusively owns GPU) ─────────────────
# In both hybrid AND ollama modes, Ollama runs on CPU.
# vLLM owns the GPU for DeepSeek-R1 reasoning.
Write-Host "   Setting OLLAMA_NUM_GPU=0 (CPU-only Ollama, vLLM owns GPU)..." -ForegroundColor Yellow
[System.Environment]::SetEnvironmentVariable("OLLAMA_NUM_GPU", "0", "User")
$env:OLLAMA_NUM_GPU = "0"
Write-Host "   ✅ Ollama will use CPU only (restart Ollama to apply)" -ForegroundColor Green

# ─── Show VRAM budget ────────────────────────────────────────────────────────
Write-Host ""
Show-VRAMBudget -InferenceMode $Mode -Size $NemotronSize -CpuOnly:$OllamaCPUOnly

if ($NoRestart) {
    Write-Host ""
    Write-Host "⚠️  -NoRestart specified. Containers NOT changed." -ForegroundColor Yellow
    Write-Host "   Restart services manually for the change to take effect:" -ForegroundColor Gray
    Write-Host "   docker compose -f docker-compose.aitheros.yml up -d --build" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# ─── Verify Docker ───────────────────────────────────────────────────────────
if (-not (Test-DockerReady)) {
    exit 1
}

# ─── Start or stop vLLM containers ──────────────────────────────────────────
if ($Mode -eq "hybrid") {
    Write-Host "🚀 Starting vLLM containers..." -ForegroundColor Yellow
    Write-Host "   (Model loading takes ~6 minutes on first start)" -ForegroundColor Gray

    docker compose -f $ComposeFile --profile vllm up -d aither-vllm
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   ❌ Failed to start aither-vllm" -ForegroundColor Red
        exit 2
    }
    Write-Host "   ✅ vLLM DeepSeek-R1 14B (reasoning, port 8120)" -ForegroundColor Green

    docker compose -f $ComposeFile --profile vllm up -d aither-vllm-swap
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   ⚠️  VLLMSwap failed to start (non-fatal)" -ForegroundColor Yellow
    } else {
        Write-Host "   ✅ VLLMSwap (hot-swap 9B/12B, port 8176)" -ForegroundColor Green
    }
} else {
    # ollama mode — stop all vLLM to free VRAM
    $vllmRunning = docker ps --filter "name=aither-vllm" --format "{{.Names}}" 2>$null
    if ($vllmRunning) {
        Write-Host "🛑 Stopping vLLM containers (freeing VRAM)..." -ForegroundColor Yellow
        docker stop aither-vllm-swap 2>$null
        docker rm aither-vllm-swap 2>$null
        docker stop aither-vllm 2>$null
        docker rm aither-vllm 2>$null
        Write-Host "   ✅ vLLM + VLLMSwap stopped and removed" -ForegroundColor Green
    } else {
        Write-Host "   vLLM was not running" -ForegroundColor DarkGray
    }
}

# ─── Restart LLM-dependent services ─────────────────────────────────────────
Write-Host ""
Write-Host "♻️  Restarting LLM-dependent services..." -ForegroundColor Yellow

$llmServices = @(
    "aither-llm",
    "aither-microscheduler",
    "aither-mind",
    "aither-moltbook"
)

$running = docker ps --format "{{.Names}}" 2>$null
foreach ($svc in $llmServices) {
    $containerName = $svc -replace '^aither-', 'aitheros-'
    if ($running -match [regex]::Escape($containerName)) {
        docker compose -f $ComposeFile up -d $svc 2>$null
        Write-Host "   ♻️  $svc" -ForegroundColor Gray
    }
}

# ─── Done ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    MODE SWITCH COMPLETE                      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Active mode: " -NoNewline -ForegroundColor White
if ($Mode -eq "hybrid") {
    Write-Host "hybrid" -ForegroundColor Green -NoNewline
    Write-Host " — vLLM (fast) + Ollama (flexible)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  vLLM health:     curl http://localhost:8120/health" -ForegroundColor Cyan
    Write-Host "  VLLMSwap status: curl http://localhost:8176/status" -ForegroundColor Cyan
} else {
    Write-Host "ollama" -ForegroundColor Yellow -NoNewline
    Write-Host " — Ollama only (full VRAM flexibility)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  ~26GB VRAM freed for Ollama + ComfyUI" -ForegroundColor Cyan
}
Write-Host ""

# ─── Run benchmark if requested ───────────────────────────────────────────────
if ($Benchmark) {
    Write-Host "" 
    Write-Host "📊 Running benchmark for '$Mode' mode..." -ForegroundColor Yellow
    $benchScript = Join-Path $PSScriptRoot ".." "80-testing" "8010_Benchmark-InferenceModes.ps1"
    if (Test-Path $benchScript) {
        $benchConfigMap = @{ 'ollama' = 'ollama'; 'hybrid' = 'hybrid' }
        $benchMode = $benchConfigMap[$Mode]
        & $benchScript -Modes $benchMode -SkipModeSwitch -Save
    } else {
        Write-Host "  Falling back to Python benchmark..." -ForegroundColor Gray
        $configArg = if ($Mode -eq 'ollama') { 'solo-ollama' } else { 'hybrid' }
        python (Join-Path $projectRoot "scripts" "benchmark_inference_configs.py") --config $configArg --save
    }
}

exit 0
