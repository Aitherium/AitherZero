#Requires -Version 7.0
<#
.SYNOPSIS
    Optimizes Ollama for maximum inference speed on RTX 5080/high-end GPUs.

.DESCRIPTION
    Sets environment variables for:
    - Flash Attention (faster attention mechanism)
    - Parallel request handling
    - KV cache quantization (saves VRAM, allows larger batches)
    - Optimal context settings

.PARAMETER Apply
    Apply settings permanently (requires restart of Ollama service).

.PARAMETER ShowCurrent
    Show current Ollama optimization settings.

.EXAMPLE
    .\0015_Optimize-Ollama.ps1 -Apply
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Apply,
    [switch]$ShowCurrent,
    [switch]$RestartOllama
)

# Import common initialization
. "$PSScriptRoot/_init.ps1"

Write-Host "`n🚀 OLLAMA PERFORMANCE OPTIMIZER" -ForegroundColor Cyan
Write-Host "================================`n" -ForegroundColor Cyan

# Optimal settings for RTX 5080 (16GB VRAM)
$OptimalSettings = @{
    # Flash Attention - Uses optimized attention kernels (20-40% faster)
    OLLAMA_FLASH_ATTENTION = "1"
    
    # Parallel requests - Handle multiple requests simultaneously
    OLLAMA_NUM_PARALLEL = "2"
    
    # KV Cache Type - Use FP16 for speed/quality balance (q8_0 for more VRAM savings)
    OLLAMA_KV_CACHE_TYPE = "f16"
    
    # Keep models loaded longer (in minutes)
    OLLAMA_KEEP_ALIVE = "60m"
    
    # Maximum loaded models (with 16GB, can keep 1-2 8B models)
    OLLAMA_MAX_LOADED_MODELS = "2"
    
    # GPU layers - Load all layers to GPU
    OLLAMA_GPU_LAYERS = "99"
    
    # Use all available VRAM
    OLLAMA_MAX_VRAM = "0"  # 0 = use all available
}

if ($ShowCurrent) {
    Write-Host "📊 Current Ollama Settings:" -ForegroundColor Yellow
    foreach ($key in $OptimalSettings.Keys | Sort-Object) {
        $current = [Environment]::GetEnvironmentVariable($key, "User")
        $optimal = $OptimalSettings[$key]
        $status = if ($current -eq $optimal) { "✅" } elseif ($current) { "⚠️" } else { "❌" }
        Write-Host "  $status $key = $(if($current){"'$current'"}else{'(not set)'}) $(if($current -ne $optimal){"→ optimal: '$optimal'"})" 
    }
    
    # Check if Ollama is running and show runtime info
    try {
        $ollamaPs = ollama ps 2>$null | Out-String
        Write-Host "`n📦 Loaded Models:" -ForegroundColor Yellow
        Write-Host $ollamaPs
    } catch {
        Write-Host "`n⚠️ Ollama not running" -ForegroundColor Yellow
    }
    
    return
}

if ($Apply) {
    Write-Host "⚡ Applying optimal Ollama settings..." -ForegroundColor Green
    
    foreach ($key in $OptimalSettings.Keys) {
        $value = $OptimalSettings[$key]
        $current = [Environment]::GetEnvironmentVariable($key, "User")
        
        if ($current -ne $value) {
            [Environment]::SetEnvironmentVariable($key, $value, "User")
            Write-Host "  ✅ Set $key = $value" -ForegroundColor Green
        } else {
            Write-Host "  ⏭️ $key already set to $value" -ForegroundColor Gray
        }
    }
    
    Write-Host "`n📝 Settings applied to User environment." -ForegroundColor Cyan
    Write-Host "   Restart Ollama for changes to take effect." -ForegroundColor Yellow
    
    if ($RestartOllama) {
        Write-Host "`n🔄 Restarting Ollama service..." -ForegroundColor Yellow
        
        # Stop Ollama
        $ollamaProc = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
        if ($ollamaProc) {
            Stop-Process -Name "ollama*" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        
        # Start Ollama with new settings
        Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
        
        Write-Host "  ✅ Ollama restarted with new settings" -ForegroundColor Green
        
        # Preload the primary model
        Write-Host "`n🔥 Preloading aither-orchestrator-8b:v2..." -ForegroundColor Yellow
        $body = @{model = "aither-orchestrator-8b:v2"; prompt = ""; keep_alive = "60m"} | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri "http://localhost:11434/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 60 | Out-Null
            Write-Host "  ✅ Model preloaded and ready!" -ForegroundColor Green
        } catch {
            Write-Host "  ⚠️ Model preload failed: $_" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "📋 Recommended Ollama Optimizations:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($key in $OptimalSettings.Keys | Sort-Object) {
        $value = $OptimalSettings[$key]
        $current = [Environment]::GetEnvironmentVariable($key, "User")
        if ($current -ne $value) {
            Write-Host "  $key = $value" -ForegroundColor White
        }
    }
    Write-Host ""
    Write-Host "Run with -Apply to set these, or -Apply -RestartOllama to apply and restart." -ForegroundColor Cyan
}
