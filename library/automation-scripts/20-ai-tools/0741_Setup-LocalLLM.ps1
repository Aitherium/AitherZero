#Requires -Version 7.0

<#
.SYNOPSIS
    Installs and configures local LLM models via Ollama.
.DESCRIPTION
    Sets up Ollama with local models. Supports:
    - General purpose models (Mistral, LLaMA, Qwen, etc.)
    - Vision models for image analysis

    The script ensures Ollama is running, pulls the requested model,
    and optionally pulls vision models.
.PARAMETER Model
    The local model to use. Categories:

    LIGHTWEIGHT (2-4GB RAM):
    - llama3.2 (Meta LLaMA 3.2 3B - Fast, general purpose)
    - phi3.5 (Microsoft Phi 3.5 Mini - Efficient, coding)
    - qwen2.5:3b (Alibaba Qwen 2.5 3B - Multilingual)

    BALANCED (6-10GB RAM):
    - mistral-nemo (Mistral Nemo 12B - Recommended, balanced)
    - llama3.1:8b (Meta LLaMA 3.1 8B - Strong general model)
    - gemma2:9b (Google Gemma 2 9B - Efficient)
    - gemma3 (Google Gemma 3 - Latest Gemma)
    - qwen2.5:7b (Alibaba Qwen 2.5 7B - Multilingual, strong)
    - sealion (SEA-LION v4 - Southeast Asian languages)

    CREATIVE/ROLEPLAY (6-14GB RAM):
    - dolphin-mistral (Dolphin Mistral 7B - Creative, fiction)
    - mythomax (MythoMax 13B - Roleplay, storytelling)
    - midnight-rose (Midnight Rose 70B quantized - Fiction)
    - nous-hermes2 (Nous Hermes 2 - Instruction following)

    LARGE/POWERFUL (20-80GB RAM):
    - llama3.1:70b (Meta LLaMA 3.1 70B - Most capable)
    - qwen2.5:72b (Alibaba Qwen 2.5 72B - Very strong)
    - mixtral:8x7b (Mistral Mixtral 8x7B - MoE architecture)

    SPECIALIZED:
    - codellama:13b (Meta Code Llama - Programming)
    - deepseek-coder:6.7b (DeepSeek Coder - Code generation)
    - solar:10.7b (Upstage Solar - Instruction following)
    - yi:34b (01.AI Yi 34B - Strong reasoning)

    VISION:
    - llama3.2-vision (Meta LLaMA 3.2 Vision - Image analysis)
    - llava:13b (LLaVA 13B - Vision-language model)

    Default: llama3.2
.PARAMETER SkipVision
    Skip pulling vision models (llama3.2-vision).
.EXAMPLE
    # Pull default model (llama3.2) for quick setup
    .\0741_Setup-LocalLLM.ps1
.EXAMPLE
    # Pull specific balanced model
    .\0741_Setup-LocalLLM.ps1 -Model mistral-nemo
.NOTES
    Stage: AI Tools
    Order: 0741
#>

[CmdletBinding()]
param(
    [ValidateSet(
        # === LIGHTWEIGHT (2-4GB RAM) ===
        "llama3.2", "phi3.5", "qwen2.5:3b",
        # === BALANCED (6-10GB RAM) ===
        "mistral-nemo", "llama3.1:8b", "gemma2:9b", "gemma3", "qwen2.5:7b", "sealion",
        # === CREATIVE/ROLEPLAY (6-14GB RAM) ===
        "dolphin-mistral", "mythomax", "midnight-rose", "nous-hermes2",
        # === LARGE/POWERFUL (20-80GB RAM) ===
        "llama3.1:70b", "qwen2.5:72b", "mixtral:8x7b",
        # === SPECIALIZED ===
        "codellama:13b", "deepseek-coder:6.7b", "solar:10.7b", "yi:34b",
        # === VISION MODELS ===
        "llama3.2-vision", "llava:13b",
        # === NEMOTRON RAW ===
        "nemotron:8b-instruct", "nemotron:51b-instruct-q4_k_m", "nemotron:70b-instruct-q4_k_m"
    )]
    [string]$Model = "llama3.2",

    [switch]$SkipVision         # Skip vision models
)

. "$PSScriptRoot/_init.ps1"

Write-Host "Setting up local LLM models..." -ForegroundColor Cyan
Write-Host ""

# 1. Ensure Ollama is installed
Write-Host "📦 Checking Ollama installation..." -ForegroundColor Cyan
if (-not (Get-Command "ollama" -ErrorAction SilentlyContinue)) {
    Write-Host "   Ollama not found. Installing..." -ForegroundColor Yellow

    # Run the Ollama installation script
    $ollamaScript = Join-Path $PSScriptRoot "0740_Install-Ollama.ps1"
    if (Test-Path $ollamaScript) {
        & $ollamaScript -Model $Model
    }
    else {
        Write-Error "❌ Ollama installation script not found: $ollamaScript"
        exit 1
    }
}
else {
    Write-Host "✅ Ollama is installed" -ForegroundColor Green
}

# 1.5 Ensure Ollama Service is Running
Write-Host "🔄 Checking Ollama service status..." -ForegroundColor Cyan

function Test-OllamaService {
    try {
        $resp = Invoke-WebRequest "http://localhost:11434" -Method Get -ErrorAction SilentlyContinue
        return ($resp.StatusCode -eq 200)
    } catch { return $false }
}

if (-not (Test-OllamaService)) {
    Write-Host "🚀 Starting Ollama service..." -ForegroundColor Yellow

    # Attempt 1: Systemd (Linux only)
    if ($IsLinux -and (Get-Command "systemctl" -ErrorAction SilentlyContinue)) {
        try {
            # Check if systemd is usable (not a stub)
            $systemdStatus = systemctl is-system-running 2>&1
            if ($LASTEXITCODE -eq 0 -and ($systemdStatus -match "running" -or $systemdStatus -match "degraded")) {
                sudo systemctl start ollama
                Start-Sleep -Seconds 2
            }
        } catch {}
    }

    # Verify if started, if not try background process
    if (-not (Test-OllamaService)) {
        Write-Host "   Systemd failed or unavailable. Starting background process..." -ForegroundColor Yellow

        if ($IsLinux) {
            # Start in background, redirecting output to prevent hanging
            # Note: RedirectStandardOutput and RedirectStandardError must point to different files in PowerShell Core on Linux sometimes
            Start-Process -FilePath "ollama" -ArgumentList "serve" -NoNewWindow -RedirectStandardOutput "/dev/null" -RedirectStandardError "/tmp/ollama_error.log"
        } elseif ($IsWindows) {
            Start-Process -FilePath "ollama" -ArgumentList "serve" -NoNewWindow
        }

        # Wait for startup
        $retries = 0
        while ($retries -lt 15) {
            if (Test-OllamaService) {
                Write-Host "✅ Ollama service started." -ForegroundColor Green
                break
            }
            Start-Sleep -Seconds 2
            $retries++
            Write-Host "   Waiting for service... ($retries/15)"
        }
    }
}

if (-not (Test-OllamaService)) {
    Write-Error "❌ Failed to start Ollama service. Please run 'ollama serve' manually in a separate terminal."
    exit 1
}
else {
    Write-Host "✅ Ollama service is active." -ForegroundColor Green
}

# 2. Display model information
Write-Host ""
Write-Host "📊 Model Information:" -ForegroundColor Cyan
switch ($Model) {
    "llama3.2" {
        Write-Host "   Category: Lightweight"
        Write-Host "   Name: Meta LLaMA 3.2 3B Instruct"
        Write-Host "   RAM Required: ~4GB"
        Write-Host "   Speed: Very Fast"
        Write-Host "   Best For: Resource-constrained systems, quick responses"
    }
    "phi3.5" {
        Write-Host "   Category: Lightweight"
        Write-Host "   Name: Microsoft Phi 3.5 Mini"
        Write-Host "   RAM Required: ~3GB"
        Write-Host "   Speed: Very Fast"
        Write-Host "   Best For: Coding, efficient reasoning, low memory"
    }
    "qwen2.5:3b" {
        Write-Host "   Category: Lightweight"
        Write-Host "   Name: Alibaba Qwen 2.5 3B"
        Write-Host "   RAM Required: ~3GB"
        Write-Host "   Speed: Very Fast"
        Write-Host "   Best For: Multilingual, efficient general tasks"
    }

    # Balanced Models
    "mistral-nemo" {
        Write-Host "   Category: Balanced (Recommended)"
        Write-Host "   Name: Mistral Nemo 12B Instruct"
        Write-Host "   RAM Required: ~8GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: General use, balanced performance"
    }
    "llama3.1:8b" {
        Write-Host "   Category: Balanced"
        Write-Host "   Name: Meta LLaMA 3.1 8B Instruct"
        Write-Host "   RAM Required: ~6GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: Strong general-purpose model"
    }
    "gemma2:9b" {
        Write-Host "   Category: Balanced"
        Write-Host "   Name: Google Gemma 2 9B"
        Write-Host "   RAM Required: ~7GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: Efficient, instruction following"
    }
    "gemma3" {
        Write-Host "   Category: Balanced"
        Write-Host "   Name: Google Gemma 3"
        Write-Host "   RAM Required: ~8GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: Latest Gemma model, improved capabilities"
    }
    "qwen2.5:7b" {
        Write-Host "   Category: Balanced"
        Write-Host "   Name: Alibaba Qwen 2.5 7B"
        Write-Host "   RAM Required: ~6GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: Multilingual, strong reasoning"
    }
    "sealion" {
        Write-Host "   Category: Balanced"
        Write-Host "   Name: SEA-LION v4 (AI Singapore)"
        Write-Host "   RAM Required: ~8GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: Southeast Asian languages, regional context"
    }

    # Creative/Roleplay Models
    "dolphin-mistral" {
        Write-Host "   Category: Creative/Roleplay"
        Write-Host "   Name: Dolphin Mistral 7B"
        Write-Host "   RAM Required: ~6GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: Creative writing, fiction, flexible responses"
    }
    "mythomax" {
        Write-Host "   Category: Creative/Roleplay"
        Write-Host "   Name: MythoMax 13B"
        Write-Host "   RAM Required: ~10GB"
        Write-Host "   Speed: Medium"
        Write-Host "   Best For: Roleplay, storytelling, narrative"
    }
    "midnight-rose" {
        Write-Host "   Category: Creative/Roleplay"
        Write-Host "   Name: Midnight Rose"
        Write-Host "   RAM Required: ~12GB"
        Write-Host "   Speed: Medium"
        Write-Host "   Best For: Fiction, creative scenarios"
    }
    "nous-hermes2" {
        Write-Host "   Category: Creative/Roleplay"
        Write-Host "   Name: Nous Hermes 2"
        Write-Host "   RAM Required: ~8GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: Instruction following, diverse tasks"
    }

    # Large/Powerful Models
    "llama3.1:70b" {
        Write-Host "   Category: Large/Powerful"
        Write-Host "   Name: Meta LLaMA 3.1 70B Instruct"
        Write-Host "   RAM Required: ~40GB (quantized: ~20GB)"
        Write-Host "   Speed: Slow"
        Write-Host "   Best For: Maximum capability, complex tasks"
    }
    "qwen2.5:72b" {
        Write-Host "   Category: Large/Powerful"
        Write-Host "   Name: Alibaba Qwen 2.5 72B"
        Write-Host "   RAM Required: ~45GB (quantized: ~25GB)"
        Write-Host "   Speed: Slow"
        Write-Host "   Best For: Very strong reasoning, multilingual"
    }
    "mixtral:8x7b" {
        Write-Host "   Category: Large/Powerful"
        Write-Host "   Name: Mistral Mixtral 8x7B (MoE)"
        Write-Host "   RAM Required: ~30GB (quantized: ~15GB)"
        Write-Host "   Speed: Medium"
        Write-Host "   Best For: Mixture of Experts, efficient large model"
    }

    # Specialized Models
    "codellama:13b" {
        Write-Host "   Category: Specialized (Code)"
        Write-Host "   Name: Meta Code Llama 13B"
        Write-Host "   RAM Required: ~10GB"
        Write-Host "   Speed: Medium"
        Write-Host "   Best For: Code generation, programming tasks"
    }
    "deepseek-coder:6.7b" {
        Write-Host "   Category: Specialized (Code)"
        Write-Host "   Name: DeepSeek Coder 6.7B"
        Write-Host "   RAM Required: ~5GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: Efficient code generation"
    }
    "solar:10.7b" {
        Write-Host "   Category: Specialized"
        Write-Host "   Name: Upstage Solar 10.7B"
        Write-Host "   RAM Required: ~8GB"
        Write-Host "   Speed: Fast"
        Write-Host "   Best For: Strong instruction following"
    }
    "yi:34b" {
        Write-Host "   Category: Specialized"
        Write-Host "   Name: 01.AI Yi 34B"
        Write-Host "   RAM Required: ~20GB (quantized: ~12GB)"
        Write-Host "   Speed: Medium"
        Write-Host "   Best For: Strong reasoning, bilingual (EN/CN)"
    }
}

# 3. Determine models to pull
$modelsToPull = @()

$modelsToPull += $Model

# 4. Pull the models
foreach ($pullModel in $modelsToPull) {
    Write-Host ""
    Write-Host "⬇️  Pulling model: $pullModel..." -ForegroundColor Cyan
    Write-Host "   (This may take several minutes depending on model size)" -ForegroundColor DarkGray

    $modelList = ollama list 2>&1
    if ($modelList -match ($pullModel -replace ":", "").Split("/")[-1]) {
        Write-Host "✅ Model already available locally" -ForegroundColor Green
    }
    else {
        ollama pull $pullModel
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Model pulled successfully" -ForegroundColor Green
        }
        else {
            Write-Error "❌ Failed to pull model: $pullModel"
            exit 1
        }
    }
}

# 5. Pull vision model (unless skipped)
if (-not $SkipVision) {
    Write-Host ""
    Write-Host "Ensuring vision model is available..." -ForegroundColor Cyan

    $visionModel = "llama3.2-vision"
    $modelList = ollama list 2>&1
    if ($modelList -match "llama3.2-vision") {
        Write-Host "Vision model already available" -ForegroundColor Green
    } else {
        Write-Host "   Pulling $visionModel for image analysis..." -ForegroundColor DarkGray
        ollama pull $visionModel
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Vision model pulled successfully" -ForegroundColor Green
        } else {
            Write-Warning "Failed to pull vision model"
        }
    }
}

# 6. Verify Ollama service
Write-Host ""
Write-Host "🔍 Verifying Ollama service..." -ForegroundColor Cyan

try {
    $response = Invoke-WebRequest -Uri "http://localhost:11434" -Method Get -ErrorAction SilentlyContinue
    if ($response.StatusCode -eq 200) {
        Write-Host "✅ Ollama service is running" -ForegroundColor Green
    }
}
catch {
    Write-Warning "⚠️  Ollama service may not be running. Starting it..."
    if ($IsLinux) {
        if (Get-Command "systemctl" -ErrorAction SilentlyContinue) {
            sudo systemctl start ollama
        }
        else {
            Start-Process "ollama" -ArgumentList "serve" -NoNewWindow
        }
    }
    elseif ($IsWindows) {
        Start-Process "ollama" -ArgumentList "serve" -NoNewWindow
    }

    Start-Sleep -Seconds 3

    try {
        $response = Invoke-WebRequest -Uri "http://localhost:11434" -Method Get -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            Write-Host "✅ Service started successfully" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "⚠️  Could not verify service. You may need to start it manually with: ollama serve"
    }
}

# 7. List available models
Write-Host ""
Write-Host "📋 Available Models:" -ForegroundColor Cyan
ollama list 2>&1 | ForEach-Object { Write-Host "   $_" }

# 8. Success summary
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "Local LLM Setup Complete!" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "   Primary Model: $Model"
Write-Host "   Backend: Local Ollama"
Write-Host "   API: http://localhost:11434"
Write-Host "   Privacy: Fully offline (no external API calls)"
Write-Host ""

Write-AitherLog -Message "Local LLM setup completed: $Model" -Level Information -Source '0741_Setup-LocalLLM'
