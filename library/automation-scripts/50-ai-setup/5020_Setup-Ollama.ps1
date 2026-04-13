#Requires -Version 7.0
<#
.SYNOPSIS
    Install Ollama and pull models required by the active model stack.

.DESCRIPTION
    Automated Ollama setup for AitherOS hybrid inference:
    1. Installs Ollama via winget (Windows) or curl (Linux)
    2. Starts the Ollama service
    3. Configures CPU-only mode (OLLAMA_NUM_GPU=0) so GPU stays for vLLM
    4. Pulls models required by the active model stack (from model-stacks.yaml)
    5. Validates inference with a test prompt

    This script is idempotent — safe to run multiple times.

.PARAMETER Models
    Override: specific models to pull (comma-separated).
    Default: reads from active stack in model-stacks.yaml.

.PARAMETER GpuLayers
    Number of GPU layers for Ollama. Default: 0 (pure CPU).
    Set >0 only if you have VRAM headroom beyond orchestrator.

.PARAMETER SkipInstall
    Skip installation, only pull models and configure.

.PARAMETER SkipPull
    Skip model pulling, only install and configure.

.EXAMPLE
    .\5020_Setup-Ollama.ps1
    # Full setup: install + configure + pull models from active stack

.EXAMPLE
    .\5020_Setup-Ollama.ps1 -Models "nemotron-elastic:12b,llama3.2:3b"
    # Pull specific models

.EXAMPLE
    .\5020_Setup-Ollama.ps1 -SkipInstall
    # Just pull models (Ollama already installed)

.NOTES
    Category: ai-setup
    Dependencies: winget (Windows) or curl (Linux)
    Platform: Windows, Linux
#>

[CmdletBinding()]
param(
    [string]$Models,
    [int]$GpuLayers = 0,
    [switch]$SkipInstall,
    [switch]$SkipPull
)

$ErrorActionPreference = 'Stop'

# ── Paths ────────────────────────────────────────────────────────────────────
$ProjectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$ModelStacksYaml = Join-Path $ProjectRoot "AitherOS" "config" "model-stacks.yaml"
$ActiveStackFile = Join-Path $ProjectRoot "AitherOS" "config" ".active-model-stack"

Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  AitherOS — Ollama Setup (CPU Inference Backend)            ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# ── Step 1: Install Ollama ───────────────────────────────────────────────────
if (-not $SkipInstall) {
    $ollamaPath = Get-Command ollama -ErrorAction SilentlyContinue

    if ($ollamaPath) {
        $version = & ollama --version 2>&1 | Select-Object -First 1
        Write-Host "  ✓ Ollama already installed: $version" -ForegroundColor Green
    } else {
        Write-Host "  → Installing Ollama..." -ForegroundColor Yellow

        if ($IsWindows -or $env:OS -match 'Windows') {
            # Windows: winget
            try {
                & winget install --id Ollama.Ollama --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
                Write-Host "  ✓ Ollama installed via winget" -ForegroundColor Green
            } catch {
                Write-Warning "winget install failed. Trying direct download..."
                $installerUrl = "https://ollama.com/download/OllamaSetup.exe"
                $installerPath = Join-Path $env:TEMP "OllamaSetup.exe"
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
                Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
                Write-Host "  ✓ Ollama installed via direct download" -ForegroundColor Green
            }
        } else {
            # Linux/macOS: curl
            & bash -c "curl -fsSL https://ollama.com/install.sh | sh" 2>&1
            Write-Host "  ✓ Ollama installed via install script" -ForegroundColor Green
        }

        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    }
}

# ── Step 2: Configure CPU-only mode ─────────────────────────────────────────
Write-Host "`n  → Configuring Ollama for CPU-only inference (GPU reserved for vLLM)..." -ForegroundColor Yellow

# Set environment variables for Ollama
$ollamaEnvVars = @{
    'OLLAMA_NUM_GPU'    = "$GpuLayers"     # 0 = pure CPU
    'OLLAMA_HOST'       = '0.0.0.0:11434'  # Listen on all interfaces
    'OLLAMA_KEEP_ALIVE' = '30m'            # Keep models loaded 30 min
}

foreach ($kv in $ollamaEnvVars.GetEnumerator()) {
    [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, "User")
    $env:($kv.Key) = $kv.Value
}

Write-Host "  ✓ OLLAMA_NUM_GPU=$GpuLayers (CPU-only)" -ForegroundColor Green
Write-Host "  ✓ OLLAMA_HOST=0.0.0.0:11434" -ForegroundColor Green
Write-Host "  ✓ OLLAMA_KEEP_ALIVE=30m" -ForegroundColor Green

# ── Step 3: Start Ollama service ─────────────────────────────────────────────
Write-Host "`n  → Starting Ollama service..." -ForegroundColor Yellow

$ollamaProcess = Get-Process ollama -ErrorAction SilentlyContinue
if ($ollamaProcess) {
    Write-Host "  ✓ Ollama already running (PID: $($ollamaProcess.Id))" -ForegroundColor Green
} else {
    if ($IsWindows -or $env:OS -match 'Windows') {
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    } else {
        & bash -c "nohup ollama serve > /dev/null 2>&1 &"
    }
    Start-Sleep -Seconds 3
    Write-Host "  ✓ Ollama service started" -ForegroundColor Green
}

# Wait for API
$maxRetries = 10
for ($i = 0; $i -lt $maxRetries; $i++) {
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -Method Get -TimeoutSec 3
        Write-Host "  ✓ Ollama API responding on :11434" -ForegroundColor Green
        break
    } catch {
        if ($i -eq $maxRetries - 1) {
            Write-Error "Ollama API not responding after $maxRetries attempts"
        }
        Start-Sleep -Seconds 2
    }
}

# ── Step 4: Determine models to pull ─────────────────────────────────────────
if (-not $SkipPull) {
    $modelsToPull = @()

    if ($Models) {
        $modelsToPull = $Models -split ','  | ForEach-Object { $_.Trim() }
    } else {
        # Read from active model stack
        Write-Host "`n  → Reading models from active model stack..." -ForegroundColor Yellow

        $activeStack = $null
        if (Test-Path $ActiveStackFile) {
            $activeStack = (Get-Content $ActiveStackFile -Raw).Trim()
        }
        if (-not $activeStack -and (Test-Path $ModelStacksYaml)) {
            # Parse active field from YAML (simple grep)
            $activeStack = (Select-String -Path $ModelStacksYaml -Pattern '^active:\s*(.+)$' |
                ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
        }

        Write-Host "  Active stack: $activeStack" -ForegroundColor Cyan

        if (Test-Path $ModelStacksYaml) {
            # Extract ollama models from the YAML
            # Look for pull_ollama_models and backend: ollama entries
            $yamlContent = Get-Content $ModelStacksYaml -Raw

            # Simple extraction: find all ollama model references
            $ollamaModels = @()
            $inActiveStack = $false
            foreach ($line in (Get-Content $ModelStacksYaml)) {
                if ($line -match "^\s{2}\w" -and $line -notmatch '^\s{2}-') {
                    $inActiveStack = $line -match "^\s{2}${activeStack}:"
                }
                if ($inActiveStack) {
                    # pull_ollama_models entries
                    if ($line -match '^\s+-\s+"?([^"]+)"?\s*$') {
                        $model = $Matches[1].Trim()
                        if ($model -match ':' -or $model -match 'nemotron|llama|qwen|mistral') {
                            $ollamaModels += $model
                        }
                    }
                    # backend: ollama + model: xxx patterns
                    if ($line -match 'model:\s+(.+)$' -and $prevLine -match 'backend:\s+ollama') {
                        $ollamaModels += $Matches[1].Trim()
                    }
                }
                $prevLine = $line
            }

            $modelsToPull = $ollamaModels | Select-Object -Unique

            if ($modelsToPull.Count -eq 0) {
                # Fallback: pull the standard elastic model
                Write-Host "  No Ollama models found in stack config, using defaults" -ForegroundColor Yellow
                $modelsToPull = @("nemotron-elastic:12b")
            }
        } else {
            $modelsToPull = @("nemotron-elastic:12b")
        }
    }

    # ── Step 5: Pull models ──────────────────────────────────────────────────
    Write-Host "`n  → Pulling $($modelsToPull.Count) model(s)..." -ForegroundColor Yellow

    foreach ($model in $modelsToPull) {
        # Check if already pulled
        try {
            $tags = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -Method Get -TimeoutSec 5
            $existing = $tags.models | Where-Object { $_.name -like "$($model.Split(':')[0])*" }
            if ($existing) {
                Write-Host "  ✓ $model — already pulled ($([math]::Round($existing[0].size / 1GB, 1)) GB)" -ForegroundColor Green
                continue
            }
        } catch {}

        Write-Host "  ↓ Pulling $model (this may take a few minutes)..." -ForegroundColor Yellow
        try {
            & ollama pull $model 2>&1 | ForEach-Object {
                if ($_ -match '\d+%') { Write-Host "`r    $($_)" -NoNewline }
            }
            Write-Host "`n  ✓ $model pulled successfully" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to pull $model`: $_"
        }
    }
}

# ── Step 6: Validate inference ───────────────────────────────────────────────
Write-Host "`n  → Validating inference..." -ForegroundColor Yellow

$testModel = if ($modelsToPull.Count -gt 0) { $modelsToPull[0] } else { "nemotron-elastic:12b" }

try {
    $body = @{
        model  = $testModel
        prompt = "What is 2+2? Answer with just the number."
        stream = $false
        options = @{ num_predict = 10; num_gpu = $GpuLayers }
    } | ConvertTo-Json

    $result = Invoke-RestMethod -Uri "http://localhost:11434/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 60
    $response = $result.response.Trim()
    Write-Host "  ✓ Inference test passed: '$response' (model: $testModel)" -ForegroundColor Green

    # Show performance
    $tokPerSec = if ($result.eval_count -and $result.eval_duration) {
        [math]::Round($result.eval_count / ($result.eval_duration / 1e9), 1)
    } else { "N/A" }
    Write-Host "  ✓ Performance: $tokPerSec tok/s (CPU)" -ForegroundColor Green
} catch {
    Write-Warning "Inference test failed: $_"
    Write-Host "  Model may still be loading. Try manually: ollama run $testModel" -ForegroundColor Yellow
}

# ── Step 7: Summary ──────────────────────────────────────────────────────────
Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Ollama Setup Complete                                       ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  API:         http://localhost:11434                         ║" -ForegroundColor Green
Write-Host "║  GPU layers:  $GpuLayers (CPU-only for vLLM coexistence)              ║" -ForegroundColor Green
Write-Host "║  Models:      $($modelsToPull -join ', ')  ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║  To switch to elastic-hybrid stack:                          ║" -ForegroundColor Green
Write-Host "║  curl -X POST localhost:8001/model-stacks/switch \           ║" -ForegroundColor Green
Write-Host "║       -d '{`"stack`": `"elastic-hybrid`"}'                      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green
