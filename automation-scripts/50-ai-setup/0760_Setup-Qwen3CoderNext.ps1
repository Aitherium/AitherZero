#Requires -Version 7.0

<#
.SYNOPSIS
    Sets up Qwen3-Coder-Next for agentic coding tasks in AitherOS.

.DESCRIPTION
    Downloads and configures Qwen3-Coder-Next-80B (80B total params, 3B active).
    This is a Mixture-of-Experts model with 512 experts optimized for:
    - Long-horizon agentic coding tasks
    - Repository-scale code understanding (256K context)
    - Tool use and function calling
    - Recovery from execution failures

    The script handles:
    1. Installing prerequisites (huggingface_hub, llama.cpp tools)
    2. Downloading GGUF files from HuggingFace
    3. Merging split GGUF files into single file (required for Ollama)
    4. Creating and registering Ollama model

    Hardware Requirements:
    - RTX 5090 (32GB VRAM) or RTX 4090 (24GB VRAM) recommended
    - 64GB+ system RAM for CPU offload layers
    - 60GB+ free disk space for model files

    The script is IDEMPOTENT - safe to run multiple times.

.PARAMETER Quantization
    GGUF quantization level. Default: Q5_K_M
    Options: Q4_K_M (48GB), Q5_K_M (57GB), Q6_K (66GB), Q8_0 (85GB)

.PARAMETER ModelDir
    Directory to store model files. Default: D:\Models\Qwen3-Coder-Next

.PARAMETER Force
    Force re-download and re-merge even if files exist.

.PARAMETER SkipDownload
    Skip download, only merge/create Ollama model from existing files.

.PARAMETER GPULayers
    Number of layers to offload to GPU. Default: auto-detect based on VRAM.

.PARAMETER LlamaCppDir
    Directory for llama.cpp tools. Default: C:\llama.cpp

.EXAMPLE
    ./0760_Setup-Qwen3CoderNext.ps1
    # Downloads Q5_K_M, merges files, and creates ollama model

.EXAMPLE
    ./0760_Setup-Qwen3CoderNext.ps1 -Quantization Q4_K_M
    # Uses smaller quantization for less VRAM

.EXAMPLE
    ./0760_Setup-Qwen3CoderNext.ps1 -SkipDownload
    # Only merge/create Ollama model from existing files

.NOTES
    Stage: AI Tools
    Order: 0760
    Dependencies: Ollama, Python 3.10+
    Tags: qwen, coder, llm, ollama, agentic
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateSet("Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0")]
    [string]$Quantization = "Q5_K_M",

    [Parameter()]
    [string]$ModelDir = "D:\Models\Qwen3-Coder-Next",

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$SkipDownload,

    [Parameter()]
    [int]$GPULayers = 0,  # 0 = auto-detect

    [Parameter()]
    [string]$LlamaCppDir = "C:\llama-cpu",

    [Parameter()]
    [switch]$ShowOutput,

    [Parameter()]
    [switch]$SkipMerge
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONFIGURATION
# ============================================================================

$Config = @{
    HuggingFaceRepo = "Qwen/Qwen3-Coder-Next-GGUF"
    ModelName = "qwen3-coder-next"
    TotalLayers = 48
    
    # Quantization sizes in GB
    QuantizationSizes = @{
        "Q4_K_M" = 48.4
        "Q5_K_M" = 56.7
        "Q6_K"   = 65.5
        "Q8_0"   = 84.8
    }
    
    # Recommended GPU layers per quantization (for 32GB VRAM)
    RecommendedGPULayers = @{
        "Q4_K_M" = 40
        "Q5_K_M" = 35
        "Q6_K"   = 30
        "Q8_0"   = 25
    }
    
    # Qwen3 optimal parameters
    Temperature = 1.0
    TopP = 0.95
    TopK = 40
    NumCtx = 40960
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Install-LlamaCppTools {
    <#
    .SYNOPSIS
        Downloads and installs llama.cpp CPU-only tools for GGUF operations.
        Uses a known-working release to avoid compatibility issues.
    #>
    param([string]$InstallDir)
    
    Write-Host "  Installing llama.cpp tools (CPU-only)..." -ForegroundColor Cyan
    
    # Use known-working release to avoid CUDA DLL issues
    $knownGoodUrl = "https://github.com/ggerganov/llama.cpp/releases/download/b4951/llama-b4951-bin-win-avx2-x64.zip"
    
    # Try to get latest release, fallback to known-good
    $downloadUrl = $knownGoodUrl
    try {
        $releases = Invoke-RestMethod "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest" -TimeoutSec 10
        
        # Find CPU-only Windows build (no CUDA to avoid DLL issues)
        $asset = $releases.assets | Where-Object { 
            $_.name -match "llama.*win.*avx2.*x64\.zip$" -and 
            $_.name -notmatch "cuda|vulkan|kompute|sycl" 
        } | Select-Object -First 1
        
        if ($asset) {
            $downloadUrl = $asset.browser_download_url
            Write-Host "    Using latest release: $($asset.name)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "    Using known-good release: b4951" -ForegroundColor DarkGray
    }
    
    $zipPath = Join-Path $env:TEMP "llama-cpp-tools.zip"
    Write-Host "    Downloading..." -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    
    # Extract to temp first
    $tempExtract = Join-Path $env:TEMP "llama-extract-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force
    
    # Find extracted content (may be nested in a folder)
    $sourceDir = Get-ChildItem $tempExtract -Directory | Select-Object -First 1
    if ($sourceDir) {
        Copy-Item -Path "$($sourceDir.FullName)\*" -Destination $InstallDir -Recurse -Force
    } else {
        Copy-Item -Path "$tempExtract\*" -Destination $InstallDir -Recurse -Force
    }
    
    # Cleanup temp files
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    
    # Verify installation
    $splitTool = Join-Path $InstallDir "llama-gguf-split.exe"
    if (-not (Test-Path $splitTool)) {
        throw "Installation failed: llama-gguf-split.exe not found in $InstallDir"
    }
    
    Write-Host "    ✓ Installed to: $InstallDir" -ForegroundColor Green
}

function Merge-SplitGGUFFiles {
    <#
    .SYNOPSIS
        Merges split GGUF files into a single file using llama-gguf-split.
    #>
    param(
        [string]$InputDir,
        [string]$OutputFile,
        [string]$ToolDir
    )
    
    $splitTool = Join-Path $ToolDir "llama-gguf-split.exe"
    if (-not (Test-Path $splitTool)) {
        throw "llama-gguf-split.exe not found at $splitTool"
    }
    
    # Find the first shard file
    $firstShard = Get-ChildItem $InputDir -Filter "*-00001-of-*.gguf" | Select-Object -First 1
    if (-not $firstShard) {
        throw "Could not find first shard file (*-00001-of-*.gguf) in $InputDir"
    }
    
    # Count total shards
    $shardPattern = $firstShard.Name -replace '-00001-of-', '-*-of-'
    $allShards = Get-ChildItem $InputDir -Filter $shardPattern | Sort-Object Name
    $totalSize = ($allShards | Measure-Object -Property Length -Sum).Sum / 1GB
    
    Write-Host "    Input: $($firstShard.Name) ($($allShards.Count) shards, $([math]::Round($totalSize, 1)) GB total)" -ForegroundColor DarkGray
    Write-Host "    Output: $(Split-Path $OutputFile -Leaf)" -ForegroundColor DarkGray
    Write-Host "    This will take several minutes for a 50GB+ file..." -ForegroundColor Yellow
    
    # Prepare output directory
    $outputDir = Split-Path $OutputFile -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    # Run merge command from tool directory
    Push-Location $ToolDir
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $splitTool
        $psi.Arguments = "--merge `"$($firstShard.FullName)`" `"$OutputFile`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $ToolDir
        
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        
        $stopwatch.Stop()
        
        if ($process.ExitCode -ne 0) {
            Write-Host "    STDOUT: $stdout" -ForegroundColor Red
            Write-Host "    STDERR: $stderr" -ForegroundColor Red
            throw "GGUF merge failed with exit code $($process.ExitCode)"
        }
    } finally {
        Pop-Location
    }
    
    if (-not (Test-Path $OutputFile)) {
        throw "Merge appeared to succeed but output file not found at $OutputFile"
    }
    
    $outputSize = (Get-Item $OutputFile).Length / 1GB
    $minutes = [math]::Round($stopwatch.Elapsed.TotalMinutes, 1)
    Write-Host "    ✓ Merged: $([math]::Round($outputSize, 2)) GB in $minutes minutes" -ForegroundColor Green
}

# ============================================================================
# INITIALIZATION
# ============================================================================

Write-Host @"
╔══════════════════════════════════════════════════════════════════════════╗
║             Qwen3-Coder-Next Setup for AitherOS                          ║
║                                                                          ║
║  80B Total Params | 3B Active | 512 Experts | 256K Context              ║
║  Hybrid: DeltaNet + Attention + MoE                                      ║
╚══════════════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

$modelSubdir = "Qwen3-Coder-Next-$Quantization"
$downloadDir = Join-Path $ModelDir $modelSubdir
$mergedGguf = Join-Path $ModelDir "Qwen3-Coder-Next-$Quantization-merged.gguf"
$modelfilePath = Join-Path $ModelDir "Modelfile.$Quantization"
$ollamaModelName = "$($Config.ModelName):$($Quantization.ToLower())"

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Quantization: $Quantization ($($Config.QuantizationSizes[$Quantization]) GB)" -ForegroundColor DarkGray
Write-Host "  Model Dir:    $downloadDir" -ForegroundColor DarkGray
Write-Host "  Merged File:  $mergedGguf" -ForegroundColor DarkGray
Write-Host "  Ollama Name:  $ollamaModelName" -ForegroundColor DarkGray

# ============================================================================
# STEP 1: Check Prerequisites
# ============================================================================

Write-Host "`n[1/6] Checking prerequisites..." -ForegroundColor Yellow

# Check Ollama
$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
    throw "Ollama not found! Please install from https://ollama.com or run 0740_Install-Ollama.ps1"
}
Write-Host "  ✓ Ollama installed" -ForegroundColor Green

# Check/Install huggingface_hub
$hfCheck = python -c "import huggingface_hub" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Installing huggingface_hub..." -ForegroundColor Cyan
    pip install huggingface_hub --quiet
}
Write-Host "  ✓ huggingface_hub available" -ForegroundColor Green

# Check/Install llama.cpp tools
$splitTool = Join-Path $LlamaCppDir "llama-gguf-split.exe"
if (-not (Test-Path $splitTool)) {
    Install-LlamaCppTools -InstallDir $LlamaCppDir
}
Write-Host "  ✓ llama.cpp tools available" -ForegroundColor Green

# Auto-detect GPU layers if not specified
if ($GPULayers -eq 0) {
    $GPULayers = $Config.RecommendedGPULayers[$Quantization]
    
    # Try to detect actual VRAM
    try {
        $vramInfo = nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
        if ($vramInfo) {
            $vramGB = [int]($vramInfo.Trim()) / 1024
            Write-Host "  ✓ Detected GPU VRAM: $([math]::Round($vramGB, 1)) GB" -ForegroundColor Green
            
            # Adjust layers based on actual VRAM
            $modelSizeGB = $Config.QuantizationSizes[$Quantization]
            $maxLayersInVRAM = [int](($vramGB / $modelSizeGB) * $Config.TotalLayers * 0.85)  # 85% safety margin
            $GPULayers = [math]::Min($maxLayersInVRAM, $Config.TotalLayers)
        }
    } catch {
        Write-Host "  ⚠ Could not detect GPU VRAM, using default: $GPULayers layers" -ForegroundColor Yellow
    }
}
Write-Host "  GPU Layers: $GPULayers / $($Config.TotalLayers)" -ForegroundColor Cyan

# ============================================================================
# STEP 2: Download Model from HuggingFace
# ============================================================================

if (-not $SkipDownload) {
    Write-Host "`n[2/6] Downloading Qwen3-Coder-Next-$Quantization..." -ForegroundColor Yellow
    
    # Create directory
    if (-not (Test-Path $ModelDir)) {
        New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
    }
    
    # Check if already downloaded
    $existingFiles = Get-ChildItem -Path $downloadDir -Filter "*.gguf" -ErrorAction SilentlyContinue
    if ($existingFiles -and -not $Force) {
        $totalSize = ($existingFiles | Measure-Object -Property Length -Sum).Sum / 1GB
        if ($totalSize -gt ($Config.QuantizationSizes[$Quantization] * 0.9)) {
            Write-Host "  ✓ Model already downloaded ($([math]::Round($totalSize, 1)) GB)" -ForegroundColor Green
        } else {
            Write-Host "  Partial download found, resuming..." -ForegroundColor Yellow
            $doDownload = $true
        }
    } else {
        $doDownload = $true
    }
    
    if ($doDownload) {
        Write-Host "  Expected size: $($Config.QuantizationSizes[$Quantization]) GB" -ForegroundColor Cyan
        Write-Host "  This may take 1-3 hours depending on connection speed..." -ForegroundColor DarkGray
        
        # Use hf download (newer command)
        $downloadArgs = @(
            "download"
            $Config.HuggingFaceRepo
            "--include", "$modelSubdir/*"
            "--local-dir", $ModelDir
        )
        
        if ($ShowOutput) {
            & hf @downloadArgs
        } else {
            & hf @downloadArgs 2>&1 | Where-Object { $_ -match "Downloading|%|complete|resume" }
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed! Check network connection and HuggingFace access."
        }
        
        Write-Host "  ✓ Download complete!" -ForegroundColor Green
    }
} else {
    Write-Host "`n[2/6] Skipping download (using existing files)..." -ForegroundColor Yellow
}

# ============================================================================
# STEP 3: Verify Downloaded Files
# ============================================================================

Write-Host "`n[3/6] Verifying downloaded files..." -ForegroundColor Yellow

$ggufFiles = Get-ChildItem -Path $downloadDir -Filter "*.gguf" -ErrorAction Stop | Sort-Object Name
if ($ggufFiles.Count -eq 0) {
    throw "No GGUF files found in $downloadDir! Download may have failed."
}

$totalDownloaded = ($ggufFiles | Measure-Object -Property Length -Sum).Sum / 1GB
Write-Host "  Found $($ggufFiles.Count) GGUF file(s), total: $([math]::Round($totalDownloaded, 1)) GB" -ForegroundColor Green

foreach ($file in $ggufFiles) {
    Write-Host "    - $($file.Name) ($([math]::Round($file.Length / 1GB, 2)) GB)" -ForegroundColor DarkGray
}

# ============================================================================
# STEP 4: Merge Split GGUF Files (if needed)
# ============================================================================

Write-Host "`n[4/6] Processing GGUF files..." -ForegroundColor Yellow

$useGgufFile = $mergedGguf

if ($SkipMerge) {
    # User wants to skip merge, check if merged file exists
    if (Test-Path $mergedGguf) {
        Write-Host "  ✓ Skipping merge (using existing merged file)" -ForegroundColor Green
        $useGgufFile = $mergedGguf
    } elseif ($ggufFiles.Count -eq 1) {
        $useGgufFile = $ggufFiles[0].FullName
        Write-Host "  ✓ Single GGUF file detected, no merge required" -ForegroundColor Green
    } else {
        throw "No merged file found and multiple split files detected. Remove -SkipMerge to merge them."
    }
} elseif ($ggufFiles.Count -gt 1) {
    # Multiple files = split GGUF, need to merge for Ollama
    $needsMerge = $true
    
    if ((Test-Path $mergedGguf) -and -not $Force) {
        $mergedSize = (Get-Item $mergedGguf).Length / 1GB
        if ($mergedSize -gt ($Config.QuantizationSizes[$Quantization] * 0.9)) {
            Write-Host "  ✓ Merged file already exists ($([math]::Round($mergedSize, 1)) GB)" -ForegroundColor Green
            $needsMerge = $false
        } else {
            Write-Host "  Merged file incomplete ($([math]::Round($mergedSize, 1)) GB), re-merging..." -ForegroundColor Yellow
        }
    }
    
    if ($needsMerge) {
        Write-Host "  Merging $($ggufFiles.Count) split GGUF files..." -ForegroundColor Cyan
        Merge-SplitGGUFFiles -InputDir $downloadDir -OutputFile $mergedGguf -ToolDir $LlamaCppDir
    }
} else {
    # Single file, use directly (no merge needed)
    $useGgufFile = $ggufFiles[0].FullName
    Write-Host "  ✓ Single GGUF file detected, no merge required" -ForegroundColor Green
}

# ============================================================================
# STEP 5: Create Modelfile
# ============================================================================

Write-Host "`n[5/6] Creating Ollama Modelfile..." -ForegroundColor Yellow

# Use forward slashes for Ollama compatibility
$ggufPathForOllama = $useGgufFile -replace '\\', '/'

$modelfileContent = @"
# Qwen3-Coder-Next - Agentic Coding Model for AitherOS
# 80B Total | 3B Active | 512 Experts (10 active) | 256K Context
# Hybrid: DeltaNet + Attention + MoE
# Quantization: $Quantization

FROM $ggufPathForOllama

# Optimal parameters from Qwen documentation
PARAMETER temperature $($Config.Temperature)
PARAMETER top_p $($Config.TopP)
PARAMETER top_k $($Config.TopK)
PARAMETER min_p 0

# Context and generation
PARAMETER num_ctx $($Config.NumCtx)
PARAMETER num_predict 16384

# GPU offloading (auto-detected for this system)
PARAMETER num_gpu $GPULayers

# System prompt for agentic coding
SYSTEM """You are Qwen3-Coder-Next, an expert AI coding assistant integrated with AitherOS.

You are optimized for complex, long-horizon software engineering tasks including:
- Repository-scale code understanding and navigation (256K context)
- Multi-step refactoring and architecture decisions
- Debugging intricate issues across codebases
- Tool use and function calling
- Recovering from execution failures

When responding to coding tasks:
1. Analyze requirements thoroughly before writing code
2. Plan the implementation approach
3. Write clean, well-documented, idiomatic code
4. Consider edge cases and error handling
5. Provide clear explanations when helpful

You are part of AitherOS and can integrate with:
- AitherNeurons (memory system)
- AitherGenesis (service orchestration)
- AitherVeil (web interface)
- AitherCouncil (multi-agent collaboration)

Always prioritize correctness, clarity, and maintainability."""

LICENSE "Apache-2.0"
"@

Set-Content -Path $modelfilePath -Value $modelfileContent -Encoding UTF8
Write-Host "  ✓ Modelfile created: $modelfilePath" -ForegroundColor Green

# ============================================================================
# STEP 6: Create Ollama Model
# ============================================================================

Write-Host "`n[6/6] Creating Ollama model..." -ForegroundColor Yellow

# Check if model already exists
$existingModels = ollama list 2>&1 | Select-String -Pattern $ollamaModelName
if ($existingModels -and -not $Force) {
    Write-Host "  Model already exists. Use -Force to recreate." -ForegroundColor Yellow
} else {
    if ($existingModels) {
        Write-Host "  Removing existing model..." -ForegroundColor DarkGray
        ollama rm $ollamaModelName 2>$null
    }
    
    Write-Host "  Building model (this may take a minute)..." -ForegroundColor Cyan
    
    Push-Location $ModelDir
    try {
        ollama create $ollamaModelName -f $modelfilePath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Ollama model!"
        }
    } finally {
        Pop-Location
    }
    
    Write-Host "  ✓ Ollama model created!" -ForegroundColor Green
}

# ============================================================================
# VERIFY MODEL LOADS
# ============================================================================

Write-Host "`nVerifying model can load..." -ForegroundColor Yellow
$testResult = ollama show $ollamaModelName 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Model verified and ready!" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Model created but verification failed" -ForegroundColor Yellow
    Write-Host "    Error: $testResult" -ForegroundColor Red
}

# ============================================================================
# DONE!
# ============================================================================

Write-Host @"

╔══════════════════════════════════════════════════════════════════════════╗
║                         ✓ Setup Complete!                                ║
╠══════════════════════════════════════════════════════════════════════════╣
║  Model:      $ollamaModelName
║  GGUF File:  $useGgufFile
║  GPU Layers: $GPULayers / $($Config.TotalLayers)
║  Context:    $($Config.NumCtx) tokens
╠══════════════════════════════════════════════════════════════════════════╣
║  Run with:                                                               ║
║    ollama run $ollamaModelName
║                                                                          ║
║  Skip this setup:                                                        ║
║    `$env:AITHEROS_SKIP_QWEN3 = "1"                                       ║
╠══════════════════════════════════════════════════════════════════════════╣
║  Integration with AitherOrchestrator:                                    ║
║    Tier: AGENTIC (Level 7+ complexity tasks)                            ║
║    Trigger: Complex multi-file refactoring, architecture decisions      ║
╚══════════════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Green

# Return success info
@{
    Success = $true
    ModelName = $ollamaModelName
    GGUFPath = $useGgufFile
    ModelDir = $downloadDir
    GPULayers = $GPULayers
    Quantization = $Quantization
}
