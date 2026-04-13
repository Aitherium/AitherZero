#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-provisions Qwen 3.5 35B A3B for the dedicated vLLM container.

.DESCRIPTION
    Ensures the Qwen/Qwen3.5-35B-A3B-GPTQ-Int4 model is present in the 
    shared 'aither-hf-cache' volume used by the 'aither-vllm-qwen' service.
    
    This prevents download delays during the first service startup and allows
    for offline operation after provisioning.

    Features:
    - Uses a temporary vLLM container to perform the download (ensuring env compatibility).
    - Mounts the shared 'aither-hf-cache' volume.
    - Downloads only required files (safetensors, config) to save space/bandwidth.
    - IDEMPOTENT: Skips if model is already present (checked via huggingface-cli).

.PARAMETER Model
    The HuggingFace model ID to download. 
    Default: Qwen/Qwen3.5-35B-A3B-GPTQ-Int4

.PARAMETER Force
    Force re-download even if it seems present.

.EXAMPLE
    .\5003_Setup-Qwen35-35B.ps1

.EXAMPLE
    .\5003_Setup-Qwen35-35B.ps1 -Model "Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4"
#>

[CmdletBinding()]
param(
    [string]$Model = "Qwen/Qwen3.5-35B-A3B-GPTQ-Int4",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   Qwen 3.5 35B A3B Provisioning (vLLM Cache)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Model: $Model" -ForegroundColor Gray

# 1. Check for Volume
$volName = "aither-hf-cache"
if (-not (docker volume ls -q -f "name=$volName")) {
    Write-Host "  Creating volume '$volName'..." -ForegroundColor Yellow
    docker volume create $volName | Out-Null
    Write-Host "  Volume created." -ForegroundColor Green
} else {
    Write-Host "  Volume '$volName' found." -ForegroundColor Util
}

# 2. Prepare Download Command
# We use vllm/vllm-openai:latest because it has python + huggingface_hub installed.
$image = "vllm/vllm-openai:latest"
$cmd = "huggingface-cli download $Model --exclude '*.bin' '*.pth' '*.pt' 'original/*'"

if ($Force) {
    $cmd += " --force-download"
}

Write-Host "  Starting temporary container for download..." -ForegroundColor Yellow
Write-Host "  Image: $image" -ForegroundColor DarkGray
Write-Host "  Command: $cmd" -ForegroundColor DarkGray

# 3. Run Download
# We mount the volume to /root/.cache/huggingface which is standard for vLLM
try {
    # Check if we have internet connection
    $test = Test-Connection -ComputerName "huggingface.co" -Count 1 -ErrorAction SilentlyContinue
    if (-not $test) {
        Write-Warning "  Cannot reach huggingface.co. Download might fail if not cached."
    }

    $containerId = docker run --rm -d `
        -v "${volName}:/root/.cache/huggingface" `
        -e "HF_TOKEN=${env:HF_TOKEN}" `
        $image `
        bash -c "$cmd"

    Write-Host "  Download container started ($containerId). Streaming logs..." -ForegroundColor Cyan
    
    # Stream logs to user
    docker logs -f $containerId

    # Wait for container to exit and get code
    $exitCode = docker wait $containerId
    
    if ($exitCode -eq 0) {
        Write-Host ""
        Write-Host "  [SUCCESS] Model '$Model' provisioned to volume '$volName'." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  [ERROR] Download failed with exit code $exitCode." -ForegroundColor Red
        exit $exitCode
    }

} catch {
    Write-Host "  [ERROR] Docker run failed: $_" -ForegroundColor Red
    exit 1
}
