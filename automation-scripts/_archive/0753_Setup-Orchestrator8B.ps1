#Requires -Version 7.0

<#
.SYNOPSIS
    Downloads and sets up NVIDIA Orchestrator-8B for use with Ollama

.DESCRIPTION
    This script downloads the Orchestrator-8B GGUF model from HuggingFace
    and registers it with Ollama for local inference.

    The NVIDIA Orchestrator-8B model is a state-of-the-art 8B parameter
    orchestration model based on Qwen3-8B. It outperforms GPT-5 on the
    HLE (Humanity's Last Exam) benchmark and is optimized for:
    - Tool selection and function calling
    - Multi-step reasoning and planning
    - Multi-turn agentic conversations
    - 2.5x more efficient than frontier models

    Exit Codes:
    0   - Success
    1   - Failure (missing dependencies)

.PARAMETER Quantization
    Which quantization level to download. Default: Q6_K (6.73GB)
    Options: Q8_0 (8.71GB), Q6_K (6.73GB), Q5_K_M (5.85GB), Q4_K_M (5.03GB)

.PARAMETER Force
    Force re-download and re-register even if model already exists

.PARAMETER SkipDownload
    Skip downloading and only register existing GGUF file with Ollama

.PARAMETER SetDefault
    Set this model as the default in NarrativeAgent .env

.PARAMETER ShowOutput
    Display detailed progress output

.EXAMPLE
    ./0753_Setup-Orchestrator8B.ps1
    # Downloads Q6_K and registers with Ollama

.EXAMPLE
    ./0753_Setup-Orchestrator8B.ps1 -Quantization Q8_0 -SetDefault
    # Downloads highest quality and sets as default agent model

.EXAMPLE
    ./0753_Setup-Orchestrator8B.ps1 -SkipDownload
    # Only registers existing GGUF file with Ollama

.NOTES
    Stage: AI Tools
    Order: 0753
    Dependencies: Ollama, HuggingFace Hub CLI (huggingface-cli)
    Tags: nvidia, orchestrator, llm, ollama, gguf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateSet("Q8_0", "Q6_K", "Q6_K_L", "Q5_K_M", "Q5_K_L", "Q4_K_M", "IQ4_XS")]
    [string]$Quantization = "Q6_K",

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$SkipDownload,

    [Parameter()]
    [switch]$SetDefault,

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize
. "$PSScriptRoot/_init.ps1"

function Set-DefaultModel {
    $envFile = Join-Path $RepoRoot "AitherOS/agents/NarrativeAgent/.env"
    if (Test-Path $envFile) {
        $envContent = Get-Content $envFile -Raw
        $envContent = $envContent -replace "LOCAL_MODEL_NAME=.*", "LOCAL_MODEL_NAME=$ModelName"
        Set-Content -Path $envFile -Value $envContent -Encoding UTF8
        Write-ScriptLog "Updated NarrativeAgent to use $ModelName as default" -Level Success
    }
}
Write-Host "Setup NVIDIA Orchestrator-8B"

# Configuration
$ModelName = "orchestrator-8b"
$HFRepo = "bartowski/nvidia_Orchestrator-8B-GGUF"
$HFFileName = "nvidia_Orchestrator-8B-$Quantization.gguf"

# Paths
$RepoRoot = $env:AITHERZERO_ROOT
if (-not $RepoRoot) { $RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent | Split-Path -Parent }
$ModelDir = Join-Path $RepoRoot "AitherOS/Library/Models/$ModelName"
$GGUFPath = Join-Path $ModelDir $HFFileName
$ModelfilePath = Join-Path $ModelDir "Modelfile"

# Size estimates
$SizeMap = @{
    "Q8_0"   = "8.71 GB"
    "Q6_K_L" = "7.03 GB"
    "Q6_K"   = "6.73 GB"
    "Q5_K_L" = "6.24 GB"
    "Q5_K_M" = "5.85 GB"
    "Q4_K_M" = "5.03 GB"
    "IQ4_XS" = "4.40 GB"
}

# =====================================================================
# Banner
# =====================================================================
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        NVIDIA Orchestrator-8B Model Setup                 ║" -ForegroundColor Cyan
Write-Host "║                                                           ║" -ForegroundColor Cyan
Write-Host "║  • Outperforms GPT-5 on HLE benchmark                     ║" -ForegroundColor Cyan
Write-Host "║  • Based on Qwen3-8B with GRPO RL training                ║" -ForegroundColor Cyan
Write-Host "║  • 2.5x more efficient than frontier models               ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-ScriptLog "Configuration:" -Level Information
Write-ScriptLog "  Quantization: $Quantization (~$($SizeMap[$Quantization]))" -Level Information
Write-ScriptLog "  Model Dir: $ModelDir" -Level Information
Write-ScriptLog "  GGUF File: $HFFileName" -Level Information

# =====================================================================
# Step 1: Check Prerequisites
# =====================================================================
Write-ScriptLog "Checking prerequisites..." -Level Information

# Check Ollama
$ollamaCheck = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCheck) {
    Write-ScriptLog "Ollama is not installed. Run: ./0740_Install-Ollama.ps1" -Level Error
    exit 1
}

# Check if Ollama is running
try {
    $ollamaVersion = Invoke-RestMethod -Uri "http://localhost:11434/api/version" -Method GET -TimeoutSec 5 -ErrorAction Stop
    Write-ScriptLog "Ollama is running (version: $($ollamaVersion.version))" -Level Success
} catch {
    Write-ScriptLog "Ollama is not running. Starting..." -Level Warning
    Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 3
    try {
        $ollamaVersion = Invoke-RestMethod -Uri "http://localhost:11434/api/version" -Method GET -TimeoutSec 5 -ErrorAction Stop
        Write-ScriptLog "Ollama started successfully" -Level Success
    } catch {
        Write-ScriptLog "Failed to start Ollama. Run 'ollama serve' manually." -Level Error
        exit 1
    }
}

# Check if model already exists
$existingModels = ollama list 2>&1
if ($existingModels -match $ModelName -and -not $Force) {
    Write-ScriptLog "Model '$ModelName' already exists in Ollama!" -Level Warning
    Write-Host ""
    Write-Host "  Use -Force to reinstall, or run directly:" -ForegroundColor Yellow
    Write-Host "    ollama run $ModelName" -ForegroundColor White
    Write-Host ""

    if ($SetDefault) {
        Set-DefaultModel
    }
    exit 0
}

# Check huggingface-cli
$hfCheck = Get-Command hf -ErrorAction SilentlyContinue
if (-not $hfCheck) {
    $hfCheck = Get-Command huggingface-cli -ErrorAction SilentlyContinue
}

if (-not $hfCheck -and -not $SkipDownload) {
    Write-ScriptLog "HuggingFace Hub CLI not found. Installing..." -Level Warning
    pip install huggingface_hub[cli] --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-ScriptLog "Failed to install huggingface_hub. Install manually: pip install huggingface_hub[cli]" -Level Error
        exit 1
    }
    Write-ScriptLog "HuggingFace Hub CLI installed" -Level Success
}

# =====================================================================
# Step 2: Create Model Directory
# =====================================================================
if (-not (Test-Path $ModelDir)) {
    New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
    Write-ScriptLog "Created model directory: $ModelDir" -Level Information
}

# =====================================================================
# Step 3: Download GGUF Model
# =====================================================================
if (-not $SkipDownload) {
    if (-not (Test-Path $GGUFPath) -or $Force) {
        Write-ScriptLog "Downloading $HFFileName (~$($SizeMap[$Quantization]))..." -Level Information
        Write-Host ""
        Write-Host "  This may take several minutes depending on your connection." -ForegroundColor Yellow
        Write-Host "  Source: https://huggingface.co/$HFRepo" -ForegroundColor DarkGray
        Write-Host ""

        try {
            # Use hf download for proper LFS handling
            $downloadArgs = @(
                "download",
                $HFRepo,
                $HFFileName,
                "--local-dir", $ModelDir
            )

            # Prefer 'hf' command (newer), fall back to 'huggingface-cli'
            $hfCmd = "hf"
            if (-not (Get-Command hf -ErrorAction SilentlyContinue)) {
                $hfCmd = "huggingface-cli"
            }

            & $hfCmd @downloadArgs

            if ($LASTEXITCODE -ne 0) {
                throw "Download failed with exit code $LASTEXITCODE"
            }

            Write-ScriptLog "Download complete!" -Level Success
        } catch {
            Write-ScriptLog "Failed to download model: $_" -Level Error
            Write-Host ""
            Write-Host "  Manual download:" -ForegroundColor Yellow
            Write-Host "  hf download $HFRepo $HFFileName --local-dir `"$ModelDir`"" -ForegroundColor White
            Write-Host ""
            exit 1
        }
    } else {
        Write-ScriptLog "GGUF file already exists: $GGUFPath" -Level Information
    }
}

# Verify GGUF exists
if (-not (Test-Path $GGUFPath)) {
    Write-ScriptLog "GGUF file not found: $GGUFPath" -Level Error
    exit 1
}

$ggufSize = (Get-Item $GGUFPath).Length / 1GB
Write-ScriptLog "GGUF file verified: $([math]::Round($ggufSize, 2)) GB" -Level Success

# =====================================================================
# Step 4: Create/Update Modelfile
# =====================================================================
Write-ScriptLog "Creating Ollama Modelfile..." -Level Information

$ModelfileContent = @"
# NVIDIA Orchestrator-8B for Ollama
# Based on Qwen3-8B, fine-tuned for tool orchestration
# Source: https://huggingface.co/nvidia/Orchestrator-8B
# GGUF: https://huggingface.co/$HFRepo

FROM $HFFileName

# Model parameters - Qwen3 defaults with adjustments for orchestration
PARAMETER temperature 0.7
PARAMETER top_p 0.9
PARAMETER top_k 40
PARAMETER num_ctx 32768
PARAMETER repeat_penalty 1.1
PARAMETER stop "<|im_end|>"
PARAMETER stop "<|endoftext|>"

# System prompt for tool orchestration
SYSTEM """You are Orchestrator-8B, an advanced AI orchestration model designed to solve complex tasks by coordinating tools and expert models.

You excel at:
- Breaking down complex problems into manageable steps
- Selecting the optimal tool or model for each subtask
- Managing multi-turn conversations with clear reasoning
- Balancing accuracy, efficiency, and user preferences

When given a task:
1. Analyze the problem and identify required capabilities
2. Select appropriate tools/models from available resources
3. Execute steps systematically, adjusting based on feedback
4. Synthesize results into a coherent response

Available capabilities include web search, code execution, specialized models, and various tools. Always explain your reasoning clearly."""

# Chat template (Qwen3/ChatML format)
TEMPLATE """{{ if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
{{ end }}<|im_start|>assistant
{{ .Response }}<|im_end|>"""
"@

Set-Content -Path $ModelfilePath -Value $ModelfileContent -Encoding UTF8
Write-ScriptLog "Modelfile created: $ModelfilePath" -Level Success

# =====================================================================
# Step 5: Register Model with Ollama
# =====================================================================
Write-ScriptLog "Registering model with Ollama..." -Level Information

if ($Force) {
    # Remove existing model first
    ollama rm $ModelName 2>$null
}

Push-Location $ModelDir
try {
    if ($PSCmdlet.ShouldProcess($ModelName, "Create Ollama model")) {
        ollama create $ModelName -f Modelfile
        if ($LASTEXITCODE -ne 0) {
            throw "ollama create failed with exit code $LASTEXITCODE"
        }
        Write-ScriptLog "Model '$ModelName' registered successfully!" -Level Success
    }
} catch {
    Write-ScriptLog "Failed to register model: $_" -Level Error
    exit 1
} finally {
    Pop-Location
}

# Verify model
$models = ollama list
if ($models -match $ModelName) {
    Write-ScriptLog "Model verification passed" -Level Success
} else {
    Write-ScriptLog "Model verification failed" -Level Error
    exit 1
}

# =====================================================================
# Step 6: Set as Default (optional)
# =====================================================================

if ($SetDefault) {
    Set-DefaultModel
}

# =====================================================================
# Success Summary
# =====================================================================
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    Setup Complete!                        ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Model: $ModelName" -ForegroundColor White
Write-Host "  Size:  $([math]::Round($ggufSize, 2)) GB" -ForegroundColor White
Write-Host "  Quant: $Quantization" -ForegroundColor White
Write-Host ""
Write-Host "  Usage:" -ForegroundColor Cyan
Write-Host "    ollama run $ModelName" -ForegroundColor White
Write-Host ""
Write-Host "  Via API:" -ForegroundColor Cyan
Write-Host "    curl http://localhost:11434/api/generate -d '{" -ForegroundColor White
Write-Host "      `"model`": `"$ModelName`"," -ForegroundColor White
Write-Host "      `"prompt`": `"Your prompt here`"" -ForegroundColor White
Write-Host "    }'" -ForegroundColor White
Write-Host ""
Write-Host "  To set as default for agents:" -ForegroundColor Cyan
Write-Host "    ./0753_Setup-Orchestrator8B.ps1 -SetDefault" -ForegroundColor White
Write-Host ""

Write-ScriptFooter
