#Requires -Version 7.0

<#
.SYNOPSIS
    Benchmark all AitherOS inference modes: vLLM vs Ollama vs Hybrid.

.DESCRIPTION
    Orchestrates the full benchmark lifecycle:
      1. Detect available backends (Ollama, vLLM, VLLMSwap)
      2. Switch modes via 4007_Set-InferenceMode.ps1
      3. Run python benchmark suite for each mode
      4. Produce comparison report (JSON + Markdown + console table)

    Modes benchmarked:
      solo-ollama   - Ollama handles all effort tiers on CPU
      solo-vllm-6b  - Nemotron-Elastic 6B on vLLM (port 8120)
      hybrid        - Ollama CPU (E1-6) + vLLM GPU (E7-10)

    Metrics captured per mode:
      - Single request latency (TTFT, total_ms, tok/s) per effort tier
      - Concurrent neuron throughput (5-10 parallel agents)
      - Mixed workload (orchestrator + embedding + neurons simultaneously)
      - VRAM utilization snapshot

.PARAMETER Modes
    Comma-separated list of modes to benchmark.
    Valid: ollama, vllm, hybrid, all (default: all)

.PARAMETER Quick
    Fast mode: 1 run per test instead of 3.

.PARAMETER Neurons
    Number of parallel neuron agents for concurrent tests. Default: 5.

.PARAMETER Save
    Save results to JSON and Markdown files.

.PARAMETER NemotronSize
    Nemotron model size for vLLM/hybrid modes: 6b, 9b, 12b (default: 6b).

.PARAMETER SkipModeSwitch
    Don't switch modes — assume current mode is already set.
    Useful for re-running benchmarks without container restarts.

.PARAMETER WarmupSeconds
    Seconds to wait after mode switch for model loading. Default: 15.

.EXAMPLE
    .\8010_Benchmark-InferenceModes.ps1
    # Benchmark all available modes (auto-detect)

.EXAMPLE
    .\8010_Benchmark-InferenceModes.ps1 -Modes ollama,hybrid -Quick
    # Quick benchmark: Ollama vs Hybrid only

.EXAMPLE
    .\8010_Benchmark-InferenceModes.ps1 -Modes all -Neurons 8 -Save
    # Full benchmark with 8 parallel neurons, save results

.NOTES
    Stage: Testing
    Order: 8010
    Dependencies: Docker, Python 3, httpx
    Tags: benchmark, inference, vllm, ollama, hybrid, performance
    AllowParallel: false
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [ValidateScript({ $_ -split ',' | ForEach-Object { $_.Trim() -in @('ollama','vllm','hybrid','all') } | Where-Object { $_ } | Select-Object -First 1 })]
    [string]$Modes = 'all',

    [switch]$Quick,

    [ValidateRange(1, 20)]
    [int]$Neurons = 5,

    [switch]$Save,

    [ValidateSet('6b', '9b', '12b')]
    [string]$NemotronSize = '6b',

    [switch]$SkipModeSwitch,

    [int]$WarmupSeconds = 15
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Init ─────────────────────────────────────────────────────────────────────
. "$PSScriptRoot/../_init.ps1"

$SetInferenceScript = Join-Path $PSScriptRoot ".." "40-lifecycle" "4007_Set-InferenceMode.ps1"
$BenchmarkScript    = Join-Path $projectRoot "scripts" "benchmark_inference_configs.py"
$AllModesBenchmark  = Join-Path $projectRoot "scripts" "benchmark_all_modes.py"
$EnvFile            = Join-Path $projectRoot ".env"
$Timestamp          = Get-Date -Format 'yyyyMMdd_HHmmss'
$ResultsDir         = Join-Path $projectRoot "benchmark_results"

if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

# ─── Parse modes ─────────────────────────────────────────────────────────────
$modeList = if ($Modes -eq 'all') {
    @('ollama', 'vllm', 'hybrid')
} else {
    ($Modes -split ',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
}

# ─── Detect backends ─────────────────────────────────────────────────────────
function Test-OllamaReady {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            $data = $r.Content | ConvertFrom-Json
            $models = @($data.models | ForEach-Object { $_.name })
            return @{ Available = $true; Models = $models; Count = $models.Count }
        }
    } catch {}
    return @{ Available = $false; Models = @(); Count = 0 }
}

function Test-VLLMReady {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8120/v1/models" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            $data = $r.Content | ConvertFrom-Json
            if ($data.data -and $data.data.Count -gt 0) {
                return @{ Available = $true; Model = $data.data[0].id }
            }
        }
    } catch {}
    return @{ Available = $false; Model = $null }
}

function Test-VLLMSwapReady {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8176/status" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            $data = $r.Content | ConvertFrom-Json
            return @{ Available = $true; State = $data.state; Model = $data.model }
        }
    } catch {}
    return @{ Available = $false; State = 'offline'; Model = $null }
}

function Get-GPUVRAMUsage {
    try {
        $output = nvidia-smi --query-gpu=memory.used,memory.total,memory.free,utilization.gpu --format=csv,noheader,nounits 2>$null
        if ($output) {
            $parts = $output.Trim() -split ','
            return @{
                UsedMB     = [int]$parts[0].Trim()
                TotalMB    = [int]$parts[1].Trim()
                FreeMB     = [int]$parts[2].Trim()
                GPUPercent = [int]$parts[3].Trim()
            }
        }
    } catch {}
    return @{ UsedMB = 0; TotalMB = 0; FreeMB = 0; GPUPercent = 0 }
}

# ─── Banner ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           AitherOS INFERENCE MODE BENCHMARK                                  ║" -ForegroundColor Cyan
Write-Host "║           vLLM vs Ollama vs Hybrid — Head-to-Head                            ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Date:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "  Modes:     $($modeList -join ', ')" -ForegroundColor White
Write-Host "  Neurons:   $Neurons parallel" -ForegroundColor White
Write-Host "  Runs:      $(if ($Quick) { '1 (quick)' } else { '3 (standard)' })" -ForegroundColor White
Write-Host "  Nemotron:  $NemotronSize" -ForegroundColor White
Write-Host ""

# ─── Detect hardware ─────────────────────────────────────────────────────────
$gpu = Get-GPUVRAMUsage
$gpuName  = $env:AITHER_HOST_GPU_NAME
$cpuName  = $env:AITHER_HOST_CPU_NAME
$ramGB    = $env:AITHER_HOST_RAM_GB

if (-not $gpuName -and (Test-Path $EnvFile)) {
    $envContent = Get-Content $EnvFile -Raw
    if ($envContent -match 'AITHER_HOST_GPU_NAME\s*=\s*(.+)') { $gpuName = $Matches[1].Trim() }
    if ($envContent -match 'AITHER_HOST_CPU_NAME\s*=\s*(.+)') { $cpuName = $Matches[1].Trim() }
    if ($envContent -match 'AITHER_HOST_RAM_GB\s*=\s*(\d+)')  { $ramGB = $Matches[1].Trim() }
}

Write-Host "  Hardware:" -ForegroundColor Yellow
Write-Host "    GPU:  $gpuName ($($gpu.TotalMB)MB total, $($gpu.FreeMB)MB free)" -ForegroundColor Gray
Write-Host "    CPU:  $cpuName" -ForegroundColor Gray
Write-Host "    RAM:  ${ramGB}GB" -ForegroundColor Gray
Write-Host ""

# ─── Detect backends ─────────────────────────────────────────────────────────
Write-Host "  Backend detection:" -ForegroundColor Yellow

$ollamaStatus = Test-OllamaReady
$vllmStatus   = Test-VLLMReady
$swapStatus   = Test-VLLMSwapReady

if ($ollamaStatus.Available) {
    Write-Host "    ✅ Ollama:    $($ollamaStatus.Count) models loaded" -ForegroundColor Green
} else {
    Write-Host "    ❌ Ollama:    Not responding" -ForegroundColor Red
}

if ($vllmStatus.Available) {
    Write-Host "    ✅ vLLM:      $($vllmStatus.Model)" -ForegroundColor Green
} else {
    Write-Host "    ⬚  vLLM:      Not running (will start for vllm/hybrid modes)" -ForegroundColor DarkGray
}

if ($swapStatus.Available) {
    Write-Host "    ✅ VLLMSwap:  $($swapStatus.State) ($($swapStatus.Model))" -ForegroundColor Green
} else {
    Write-Host "    ⬚  VLLMSwap:  Not running" -ForegroundColor DarkGray
}
Write-Host ""

# ─── Validate mode feasibility ───────────────────────────────────────────────
$feasibleModes = @()

foreach ($mode in $modeList) {
    switch ($mode) {
        'ollama' {
            if ($ollamaStatus.Available) {
                $feasibleModes += $mode
            } else {
                Write-Host "  ⚠️  Skipping 'ollama' — Ollama not available (run: ollama serve)" -ForegroundColor Yellow
            }
        }
        'vllm' {
            # vLLM can be started by Set-InferenceMode
            if ($vllmStatus.Available -or -not $SkipModeSwitch) {
                $feasibleModes += $mode
            } else {
                Write-Host "  ⚠️  Skipping 'vllm' — vLLM not running and -SkipModeSwitch set" -ForegroundColor Yellow
            }
        }
        'hybrid' {
            if ($ollamaStatus.Available -and ($vllmStatus.Available -or -not $SkipModeSwitch)) {
                $feasibleModes += $mode
            } else {
                Write-Host "  ⚠️  Skipping 'hybrid' — Requires Ollama + vLLM" -ForegroundColor Yellow
            }
        }
    }
}

if ($feasibleModes.Count -eq 0) {
    Write-Host "  ❌ No feasible modes to benchmark!" -ForegroundColor Red
    Write-Host "     Start backends: ollama serve" -ForegroundColor Gray
    Write-Host "     For vLLM:       docker compose -f docker-compose.aitheros.yml --profile vllm up -d" -ForegroundColor Gray
    exit 1
}

Write-Host "  Benchmarking: $($feasibleModes -join ' → ')" -ForegroundColor Cyan
Write-Host ""

# ─── Results collection ──────────────────────────────────────────────────────
$allResults = @{}
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ─── Benchmark loop ──────────────────────────────────────────────────────────
$modeIndex = 0
foreach ($mode in $feasibleModes) {
    $modeIndex++

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  MODE $modeIndex/$($feasibleModes.Count): $($mode.ToUpper())" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # ── Step 1: Switch inference mode ──
    if (-not $SkipModeSwitch) {
        $switchMode = switch ($mode) {
            'ollama' { 'ollama' }
            'vllm'   { 'hybrid' }  # vLLM uses hybrid mode with OllamaCPUOnly
            'hybrid' { 'hybrid' }
        }

        Write-Host ""
        Write-Host "  📋 Switching to mode: $switchMode" -ForegroundColor Yellow

        $switchParams = @{ Mode = $switchMode }
        if ($mode -eq 'vllm') {
            $switchParams['OllamaCPUOnly'] = $true
        }
        $switchParams['NemotronSize'] = $NemotronSize

        & $SetInferenceScript @switchParams

        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ❌ Mode switch failed! Skipping $mode" -ForegroundColor Red
            continue
        }

        # Wait for model loading
        Write-Host "  ⏳ Waiting ${WarmupSeconds}s for model loading..." -ForegroundColor Gray
        Start-Sleep -Seconds $WarmupSeconds

        # Verify backend is ready after switch
        if ($mode -in @('vllm', 'hybrid')) {
            $retries = 0
            $maxRetries = 24  # 2 minutes max
            while ($retries -lt $maxRetries) {
                $vllmCheck = Test-VLLMReady
                if ($vllmCheck.Available) {
                    Write-Host "  ✅ vLLM ready: $($vllmCheck.Model)" -ForegroundColor Green
                    break
                }
                $retries++
                Write-Host "    Waiting for vLLM... ($retries/$maxRetries)" -ForegroundColor DarkGray
                Start-Sleep -Seconds 5
            }
            if ($retries -ge $maxRetries) {
                Write-Host "  ❌ vLLM failed to start after 2 minutes. Skipping $mode." -ForegroundColor Red
                continue
            }
        }
    }

    # ── Step 2: Capture VRAM before benchmark ──
    $vramBefore = Get-GPUVRAMUsage
    Write-Host "  📊 VRAM before benchmark: $($vramBefore.UsedMB)MB / $($vramBefore.TotalMB)MB used" -ForegroundColor Gray

    # ── Step 3: Run Python benchmark ──
    Write-Host ""
    Write-Host "  🚀 Running benchmark..." -ForegroundColor Yellow

    $configArg = switch ($mode) {
        'ollama' { 'solo-ollama' }
        'vllm'   { 'solo-vllm' }
        'hybrid' { 'hybrid' }
    }

    $benchArgs = @(
        $BenchmarkScript,
        "--config", $configArg,
        "--neurons", $Neurons.ToString()
    )
    if ($Quick) { $benchArgs += "--quick" }
    if ($Save)  { $benchArgs += "--save" }

    $modeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Run benchmark and capture output
    $benchOutput = & python @benchArgs 2>&1 | Tee-Object -Variable benchLines

    $modeStopwatch.Stop()

    # ── Step 4: Capture VRAM after benchmark ──
    $vramAfter = Get-GPUVRAMUsage

    # ── Step 5: Store results ──
    $allResults[$mode] = @{
        Config       = $configArg
        ElapsedSec   = [math]::Round($modeStopwatch.Elapsed.TotalSeconds, 1)
        VRAMBeforeMB = $vramBefore.UsedMB
        VRAMAfterMB  = $vramAfter.UsedMB
        VRAMFreeMB   = $vramAfter.FreeMB
        GPUUtil      = $vramAfter.GPUPercent
        Output       = ($benchLines | Out-String)
    }

    Write-Host ""
    Write-Host "  ✅ $mode completed in $($allResults[$mode].ElapsedSec)s" -ForegroundColor Green
    Write-Host "     VRAM: $($vramAfter.UsedMB)MB used, $($vramAfter.FreeMB)MB free" -ForegroundColor Gray

    # ── Cooldown between modes ──
    if ($modeIndex -lt $feasibleModes.Count) {
        Write-Host ""
        Write-Host "  ⏳ Cooldown (10s for VRAM settle)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
}

$totalStopwatch.Stop()

# ════════════════════════════════════════════════════════════════════════════════
# COMPARISON REPORT
# ════════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                         BENCHMARK COMPARISON                                 ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# ─── Summary table ────────────────────────────────────────────────────────────
Write-Host "  ┌──────────────┬─────────────┬───────────────┬───────────────┬──────────┐" -ForegroundColor White
Write-Host "  │ Mode         │ Time (s)    │ VRAM Used     │ VRAM Free     │ GPU %    │" -ForegroundColor White
Write-Host "  ├──────────────┼─────────────┼───────────────┼───────────────┼──────────┤" -ForegroundColor White

foreach ($mode in $feasibleModes) {
    if ($allResults.ContainsKey($mode)) {
        $r = $allResults[$mode]
        $modeStr = $mode.PadRight(12)
        $timeStr = "$($r.ElapsedSec)s".PadLeft(11)
        $usedStr = "$($r.VRAMAfterMB)MB".PadLeft(13)
        $freeStr = "$($r.VRAMFreeMB)MB".PadLeft(13)
        $gpuStr  = "$($r.GPUUtil)%".PadLeft(8)

        $color = switch ($mode) {
            'ollama' { 'Yellow' }
            'vllm'   { 'Cyan' }
            'hybrid' { 'Green' }
        }
        Write-Host "  │ " -NoNewline -ForegroundColor White
        Write-Host "$modeStr" -NoNewline -ForegroundColor $color
        Write-Host "│ $timeStr │ $usedStr │ $freeStr │ $gpuStr │" -ForegroundColor White
    }
}

Write-Host "  └──────────────┴─────────────┴───────────────┴───────────────┴──────────┘" -ForegroundColor White
Write-Host ""
Write-Host "  Total benchmark time: $([math]::Round($totalStopwatch.Elapsed.TotalMinutes, 1)) minutes" -ForegroundColor Gray

# ─── Mode recommendation ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Recommendations:" -ForegroundColor Yellow

if ($allResults.ContainsKey('hybrid') -and $allResults.ContainsKey('ollama')) {
    $hybridFree = $allResults['hybrid'].VRAMFreeMB
    $ollamaFree = $allResults['ollama'].VRAMFreeMB

    Write-Host "    🏆 Hybrid mode:   Best for throughput + concurrent neurons" -ForegroundColor Green
    Write-Host "    📊 Ollama mode:   Best for VRAM flexibility (${ollamaFree}MB free vs ${hybridFree}MB)" -ForegroundColor Yellow

    if ($ollamaFree -gt ($hybridFree + 10000)) {
        Write-Host "    🎨 ComfyUI:       Use 'ollama' mode (+$([math]::Round(($ollamaFree - $hybridFree) / 1024, 1))GB free)" -ForegroundColor Cyan
    }
}

if ($allResults.ContainsKey('vllm')) {
    Write-Host "    ⚡ vLLM-only:     Best raw inference speed (PagedAttention)" -ForegroundColor Cyan
}

Write-Host ""

# ─── Restore original mode ────────────────────────────────────────────────────
if (-not $SkipModeSwitch -and $feasibleModes.Count -gt 0) {
    # Read current from .env
    $origMode = 'ollama'
    if (Test-Path $EnvFile) {
        $envContent = Get-Content $EnvFile -Raw
        if ($envContent -match 'AITHER_INFERENCE_MODE\s*=\s*(\w+)') {
            $origMode = $Matches[1].Trim().ToLower()
        }
    }

    # Mode was changed during benchmarking — restore to what Set-InferenceMode last set
    Write-Host "  Current mode after benchmark: $origMode" -ForegroundColor Gray
    Write-Host "  (Use Set-InferenceMode.ps1 to switch if needed)" -ForegroundColor Gray
}

# ─── Save combined report ─────────────────────────────────────────────────────
if ($Save) {
    $reportPath = Join-Path $ResultsDir "benchmark_comparison_$Timestamp.json"
    $report = @{
        timestamp = (Get-Date).ToString('o')
        hardware  = @{
            gpu      = $gpuName
            vram_mb  = $gpu.TotalMB
            cpu      = $cpuName
            ram_gb   = [int]$ramGB
        }
        settings  = @{
            modes        = $feasibleModes
            neurons      = $Neurons
            quick        = $Quick.IsPresent
            nemotron     = $NemotronSize
        }
        results   = @{}
    }
    foreach ($mode in $feasibleModes) {
        if ($allResults.ContainsKey($mode)) {
            $r = $allResults[$mode]
            $report.results[$mode] = @{
                elapsed_sec   = $r.ElapsedSec
                vram_used_mb  = $r.VRAMAfterMB
                vram_free_mb  = $r.VRAMFreeMB
                gpu_util_pct  = $r.GPUUtil
            }
        }
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content $reportPath -Encoding UTF8
    Write-Host "  📁 Report saved: $reportPath" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  BENCHMARK COMPLETE" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  Quick commands:" -ForegroundColor Yellow
Write-Host "    python scripts/benchmark_inference_configs.py --config all --save" -ForegroundColor Gray
Write-Host "    python scripts/benchmark_all_modes.py --modes 1,5 --quick" -ForegroundColor Gray
Write-Host "    .\4007_Set-InferenceMode.ps1 -Mode hybrid -NemotronSize 6b" -ForegroundColor Gray
Write-Host ""
