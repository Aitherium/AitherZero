#Requires -Version 7.0
<#
.SYNOPSIS
    Fully automated voice capability setup for AitherOS (TTS + STT).
.DESCRIPTION
    Detects GPU availability, selects optimal voice provider (local or cloud),
    downloads required models, stores configuration in AitherSecrets and .env,
    starts the PerceptionMedia Docker service, and runs a synthesis test.
    Idempotent -- safe to run multiple times.

    GPU detected:
      TTS = XTTS v2 (local, high quality, multi-speaker)
      STT = faster-whisper (local, fast, accurate)

    No GPU:
      TTS = Edge-TTS (free Microsoft online service)
      STT = OpenAI Whisper API (requires API key)
.PARAMETER ForceProvider
    Override automatic GPU detection. Valid values: 'local', 'cloud'.
    'local' forces GPU-based providers; 'cloud' forces online providers.
.PARAMETER OpenAIApiKey
    OpenAI API key for Whisper STT (required when no GPU or ForceProvider='cloud').
    Not needed when GPU is available or ForceProvider='local'.
.PARAMETER SkipModelDownload
    Skip model downloads (models already present or will be pulled by Docker)
.PARAMETER SkipDocker
    Skip Docker service start (configuration-only mode)
.PARAMETER SkipTest
    Skip the voice synthesis test after setup
.PARAMETER ModelCacheDir
    Directory for downloaded models. Defaults to $WorkspaceRoot/models/voice.
.PARAMETER HealthCheckAttempts
    Number of health check polling attempts (default 30)
.EXAMPLE
    .\5010_Setup-Voice.ps1
    # Auto-detects GPU; downloads models; starts service
.EXAMPLE
    .\5010_Setup-Voice.ps1 -ForceProvider cloud -OpenAIApiKey "sk-..."
    # Forces cloud providers even if GPU is available
.EXAMPLE
    .\5010_Setup-Voice.ps1 -SkipModelDownload -SkipTest
    # Config only, no downloads or testing
.NOTES
    Author: AitherZero Automation
    Service: PerceptionMedia compound (port 8084)
    Layer: Perception (Layer 2)
    Voice subsystem: AitherVoice within PerceptionMedia
#>

[CmdletBinding()]
param(
    [ValidateSet('local', 'cloud')]
    [string]$ForceProvider,
    [string]$OpenAIApiKey,
    [switch]$SkipModelDownload,
    [switch]$SkipDocker,
    [switch]$SkipTest,
    [string]$ModelCacheDir,
    [int]$HealthCheckAttempts = 30
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ── Source _init.ps1 ──────────────────────────────────────────────────────
. (Join-Path $PSScriptRoot '../_init.ps1')

# ── Resolve workspace root ────────────────────────────────────────────────
$WorkspaceRoot = $PSScriptRoot
while ($WorkspaceRoot -and -not (Test-Path (Join-Path $WorkspaceRoot 'docker-compose.aitheros.yml'))) {
    $parent = Split-Path $WorkspaceRoot -Parent
    if ($parent -eq $WorkspaceRoot) { $WorkspaceRoot = $null; break }
    $WorkspaceRoot = $parent
}
if (-not $WorkspaceRoot) {
    throw "Could not locate workspace root (docker-compose.aitheros.yml not found)."
}

$MainEnvFile   = Join-Path $WorkspaceRoot '.env'
$SecretsUrl    = 'http://localhost:8111'
$ServicePort   = 8084

if (-not $ModelCacheDir) {
    $ModelCacheDir = Join-Path $WorkspaceRoot 'models' 'voice'
}

# ── Output helpers ────────────────────────────────────────────────────────
function Write-Step  { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK    { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red }

function Get-SecretsApiKey {
    param([string]$EnvFilePath)

    foreach ($name in @('AITHER_ADMIN_KEY', 'AITHER_INTERNAL_SECRET', 'AITHER_MASTER_KEY')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }

    if (Test-Path $EnvFilePath) {
        foreach ($name in @('AITHER_ADMIN_KEY', 'AITHER_INTERNAL_SECRET', 'AITHER_MASTER_KEY')) {
            $line = Select-String -Path $EnvFilePath -Pattern "^$name=(.+)$" -CaseSensitive |
                    Select-Object -First 1
            if ($line) {
                return $line.Matches[0].Groups[1].Value.Trim()
            }
        }
    }

    return 'dev-internal-secret-687579a3'
}

# ============================================================================
# Step 1: Check prerequisites
# ============================================================================
Write-Step "Checking prerequisites..."

# Docker
try {
    $dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
    if ($dockerVersion) {
        Write-OK "Docker $dockerVersion"
    } else {
        throw "no version"
    }
} catch {
    Write-Err "Docker is not running or not installed. Please install Docker Desktop."
    exit 1
}

# AitherOS running (Genesis health check)
try {
    $genesisHealth = Invoke-RestMethod -Uri 'http://localhost:8001/health' -TimeoutSec 5 -ErrorAction Stop
    Write-OK "AitherOS Genesis is running."
} catch {
    Write-Warn "Genesis (port 8001) is not reachable. Service may need manual start later."
}

# ============================================================================
# Step 2: Detect GPU availability
# ============================================================================
Write-Step "Detecting GPU availability..."

$gpuAvailable = $false
$gpuName = ''
$gpuVramMB = 0

try {
    $nvidiaSmi = nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and $nvidiaSmi) {
        $gpuAvailable = $true
        $gpuParts = $nvidiaSmi.Split(',')
        $gpuName = $gpuParts[0].Trim()
        $gpuVramMB = [int]$gpuParts[1].Trim()
        Write-OK "NVIDIA GPU detected: $gpuName ($gpuVramMB MB VRAM)"

        # Check CUDA availability in Docker
        try {
            $cudaCheck = docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-OK "Docker NVIDIA runtime available (driver $($cudaCheck.Trim()))"
            } else {
                Write-Warn "Docker NVIDIA runtime not available. Install nvidia-container-toolkit."
                Write-Warn "Local GPU models may not work inside Docker containers."
            }
        } catch {
            Write-Warn "Could not verify Docker NVIDIA runtime."
        }
    } else {
        throw "nvidia-smi not found"
    }
} catch {
    Write-Warn "No NVIDIA GPU detected. Will use cloud/CPU voice providers."
}

# ============================================================================
# Step 3: Choose voice provider
# ============================================================================
Write-Step "Selecting voice providers..."

$useLocalTts = $false
$useLocalStt = $false
$ttsProvider = ''
$sttProvider = ''

if ($ForceProvider -eq 'local') {
    if (-not $gpuAvailable) {
        Write-Warn "ForceProvider='local' but no GPU detected. Local models may be very slow on CPU."
    }
    $useLocalTts = $true
    $useLocalStt = $true
} elseif ($ForceProvider -eq 'cloud') {
    $useLocalTts = $false
    $useLocalStt = $false
} else {
    # Auto-detect: use local if GPU with >= 4GB VRAM
    if ($gpuAvailable -and $gpuVramMB -ge 4096) {
        $useLocalTts = $true
        $useLocalStt = $true
    } elseif ($gpuAvailable -and $gpuVramMB -ge 2048) {
        # Enough VRAM for STT but not both TTS + STT simultaneously
        $useLocalTts = $false
        $useLocalStt = $true
    } else {
        $useLocalTts = $false
        $useLocalStt = $false
    }
}

if ($useLocalTts) {
    $ttsProvider = 'xtts'
    Write-OK "TTS Provider: XTTS v2 (local GPU, high quality, multi-speaker)"
} else {
    $ttsProvider = 'edge-tts'
    Write-OK "TTS Provider: Edge-TTS (Microsoft online, free, low latency)"
}

if ($useLocalStt) {
    $sttProvider = 'faster-whisper'
    Write-OK "STT Provider: faster-whisper (local GPU, fast transcription)"
} else {
    $sttProvider = 'openai-whisper'
    Write-OK "STT Provider: OpenAI Whisper API (cloud, requires API key)"
}

# ============================================================================
# Step 4: Prompt for OpenAI API key if needed
# ============================================================================
if ($sttProvider -eq 'openai-whisper' -and -not $OpenAIApiKey) {
    Write-Step "OpenAI API key required for Whisper STT..."

    # Check if already in environment or .env
    $existingKey = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY')
    if (-not $existingKey -and (Test-Path $MainEnvFile)) {
        $match = Select-String -Path $MainEnvFile -Pattern '^OPENAI_API_KEY=(.+)$' | Select-Object -First 1
        if ($match) {
            $existingKey = $match.Matches[0].Groups[1].Value.Trim()
        }
    }

    if ($existingKey) {
        $OpenAIApiKey = $existingKey
        Write-OK "Found existing OPENAI_API_KEY ($($existingKey.Length) chars)"
    } else {
        Write-Host ""
        Write-Host "    OpenAI Whisper API is selected for speech-to-text." -ForegroundColor Yellow
        Write-Host "    An API key is required. Get one at: https://platform.openai.com/api-keys" -ForegroundColor Yellow
        Write-Host ""

        $secKey = Read-Host "    Enter your OpenAI API key (sk-...)"
        if (-not $secKey -or $secKey.Length -lt 10) {
            Write-Err "Valid OpenAI API key is required for cloud STT. Alternatives:"
            Write-Host "      - Run with a GPU for local faster-whisper" -ForegroundColor Yellow
            Write-Host "      - Run with -ForceProvider local (slow on CPU)" -ForegroundColor Yellow
            exit 1
        }
        $OpenAIApiKey = $secKey
        Write-OK "API key accepted ($($OpenAIApiKey.Length) chars)"
    }
}

# ============================================================================
# Step 5: Download required models
# ============================================================================
if (-not $SkipModelDownload) {
    Write-Step "Preparing model cache directory..."

    if (-not (Test-Path $ModelCacheDir)) {
        New-Item -ItemType Directory -Path $ModelCacheDir -Force | Out-Null
        Write-OK "Created $ModelCacheDir"
    } else {
        Write-OK "Model cache exists at $ModelCacheDir"
    }

    # --- faster-whisper model ---
    if ($useLocalStt) {
        Write-Step "Downloading faster-whisper model (base.en)..."

        $whisperModelDir = Join-Path $ModelCacheDir 'faster-whisper-base.en'
        if (Test-Path $whisperModelDir) {
            Write-OK "faster-whisper-base.en already downloaded."
        } else {
            try {
                # Try huggingface-cli first
                $hfCli = Get-Command 'huggingface-cli' -ErrorAction SilentlyContinue
                if ($hfCli) {
                    Write-Host "    Using huggingface-cli..." -ForegroundColor Gray
                    $env:HF_HOME = Join-Path $ModelCacheDir '.hf_cache'
                    huggingface-cli download Systran/faster-whisper-base.en --local-dir $whisperModelDir 2>&1 |
                        ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

                    if ($LASTEXITCODE -eq 0 -and (Test-Path $whisperModelDir)) {
                        Write-OK "faster-whisper-base.en downloaded."
                    } else {
                        throw "huggingface-cli download failed"
                    }
                } else {
                    # Fallback: pip install huggingface_hub, then download
                    Write-Host "    Installing huggingface_hub..." -ForegroundColor Gray
                    python -m pip install --quiet huggingface_hub 2>$null

                    python -c @"
from huggingface_hub import snapshot_download
snapshot_download('Systran/faster-whisper-base.en', local_dir=r'$whisperModelDir')
print('Download complete.')
"@ 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

                    if (Test-Path $whisperModelDir) {
                        Write-OK "faster-whisper-base.en downloaded via Python."
                    } else {
                        throw "Python download failed"
                    }
                }
            } catch {
                Write-Warn "Could not download faster-whisper model: $($_.Exception.Message)"
                Write-Warn "The Docker container will attempt to download at startup."
            }
        }
    }

    # --- Piper TTS model (fallback for all configurations) ---
    Write-Step "Downloading Piper TTS fallback model (en_GB-sonia-medium)..."

    $piperModelDir = Join-Path $ModelCacheDir 'piper'
    $piperOnnx = Join-Path $piperModelDir 'en_GB-sonia-medium.onnx'
    $piperJson = Join-Path $piperModelDir 'en_GB-sonia-medium.onnx.json'

    if ((Test-Path $piperOnnx) -and (Test-Path $piperJson)) {
        Write-OK "Piper model already downloaded."
    } else {
        if (-not (Test-Path $piperModelDir)) {
            New-Item -ItemType Directory -Path $piperModelDir -Force | Out-Null
        }

        $piperBaseUrl = 'https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/sonia/medium'
        $downloadOk = $true

        try {
            Invoke-WebRequest -Uri "$piperBaseUrl/en_GB-sonia-medium.onnx" `
                              -OutFile $piperOnnx -UseBasicParsing -ErrorAction Stop
            $sizeMB = [math]::Round((Get-Item $piperOnnx).Length / 1MB, 1)
            Write-OK "Downloaded en_GB-sonia-medium.onnx ($sizeMB MB)"
        } catch {
            Write-Warn "Could not download Piper ONNX model: $($_.Exception.Message)"
            $downloadOk = $false
        }

        try {
            Invoke-WebRequest -Uri "$piperBaseUrl/en_GB-sonia-medium.onnx.json" `
                              -OutFile $piperJson -UseBasicParsing -ErrorAction Stop
            Write-OK "Downloaded en_GB-sonia-medium.onnx.json"
        } catch {
            Write-Warn "Could not download Piper config: $($_.Exception.Message)"
            $downloadOk = $false
        }

        if (-not $downloadOk) {
            Write-Warn "Piper model download incomplete. Docker container will attempt at startup."
        }
    }
} else {
    Write-Warn "Skipping model downloads (-SkipModelDownload)."
}

# ============================================================================
# Step 6: Save configuration to .env
# ============================================================================
Write-Step "Saving voice configuration..."

$voiceConfig = @{
    'VOICE_TTS_PROVIDER'       = $ttsProvider
    'VOICE_STT_PROVIDER'       = $sttProvider
    'VOICE_MODEL_CACHE_DIR'    = $ModelCacheDir
    'VOICE_GPU_AVAILABLE'      = if ($gpuAvailable) { 'true' } else { 'false' }
}

if ($OpenAIApiKey) {
    $voiceConfig['OPENAI_API_KEY'] = $OpenAIApiKey
}

if ($useLocalStt) {
    $voiceConfig['WHISPER_MODEL']     = 'base.en'
    $voiceConfig['WHISPER_DEVICE']    = if ($gpuAvailable) { 'cuda' } else { 'cpu' }
    $voiceConfig['WHISPER_COMPUTE']   = if ($gpuAvailable) { 'float16' } else { 'int8' }
}

if ($useLocalTts) {
    $voiceConfig['XTTS_DEVICE'] = if ($gpuAvailable) { 'cuda' } else { 'cpu' }
}

# Update main .env file
if (Test-Path $MainEnvFile) {
    $envContent = Get-Content $MainEnvFile -Raw

    foreach ($kv in $voiceConfig.GetEnumerator()) {
        $pattern = "^$($kv.Key)=.*$"
        $replacement = "$($kv.Key)=$($kv.Value)"
        if ($envContent -match $pattern) {
            $envContent = $envContent -replace "(?m)$pattern", $replacement
        } else {
            $envContent = $envContent.TrimEnd() + "`n$replacement"
        }
    }

    Set-Content -Path $MainEnvFile -Value $envContent.TrimEnd() -NoNewline
    Write-OK "Updated $MainEnvFile"
} else {
    $envLines = $voiceConfig.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    Set-Content -Path $MainEnvFile -Value ($envLines -join "`n") -NoNewline
    Write-OK "Created $MainEnvFile"
}

# ============================================================================
# Step 7: Store secrets in AitherSecrets
# ============================================================================
Write-Step "Storing voice configuration in AitherSecrets..."

$secrets = @{
    'VOICE_TTS_PROVIDER' = $ttsProvider
    'VOICE_STT_PROVIDER' = $sttProvider
}

if ($OpenAIApiKey) {
    $secrets['OPENAI_API_KEY'] = $OpenAIApiKey
}

try {
    Invoke-RestMethod -Uri "$SecretsUrl/health" -TimeoutSec 3 -ErrorAction Stop | Out-Null

    $secretsApiKey = Get-SecretsApiKey -EnvFilePath $MainEnvFile
    $headers = @{ 'X-API-Key' = $secretsApiKey }
    $storedCount = 0

    foreach ($kv in $secrets.GetEnumerator()) {
        $secretType = if ($kv.Key -match 'API_KEY') { 'api_key' } else { 'config' }
        $body = @{
            name         = $kv.Key
            value        = $kv.Value
            secret_type  = $secretType
            access_level = 'internal'
        } | ConvertTo-Json

        try {
            Invoke-RestMethod -Uri "$SecretsUrl/secrets?service=AitherVoice" -Method Post `
                              -Body $body -Headers $headers `
                              -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $storedCount++
        } catch {
            Write-Warn "Failed to store $($kv.Key): $($_.Exception.Message)"
        }
    }

    if ($storedCount -eq $secrets.Count) {
        Write-OK "All $storedCount secrets stored in AitherSecrets."
    } else {
        Write-Warn "$storedCount of $($secrets.Count) secrets stored."
    }
} catch {
    Write-Warn "AitherSecrets (port 8111) not reachable: $($_.Exception.Message)"
    Write-Warn "Configuration saved to .env only. Store in Secrets when services are running."
}

# ============================================================================
# Step 8: Start Docker service
# ============================================================================
if (-not $SkipDocker) {
    Write-Step "Starting PerceptionMedia Docker service (voice subsystem)..."

    try {
        $composeFile = Join-Path $WorkspaceRoot 'docker-compose.aitheros.yml'
        if (-not (Test-Path $composeFile)) {
            Write-Err "docker-compose.aitheros.yml not found at $composeFile"
            exit 1
        }

        Push-Location $WorkspaceRoot
        docker compose -f docker-compose.aitheros.yml up -d aither-perception-media 2>&1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        Pop-Location

        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-OK "Docker service started."
        } else {
            Write-Err "Docker compose exited with code $exitCode"
            exit 1
        }
    } catch {
        Write-Err "Failed to start Docker service: $($_.Exception.Message)"
        exit 1
    }

    # ============================================================================
    # Step 9: Health check loop
    # ============================================================================
    Write-Step "Waiting for PerceptionMedia health (port $ServicePort)..."

    $healthUrl = "http://localhost:$ServicePort/health"
    $healthy = $false

    for ($i = 1; $i -le $HealthCheckAttempts; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3 -ErrorAction Stop
            if ($resp.status -eq 'healthy' -or $resp -eq 'ok' -or $null -ne $resp) {
                $healthy = $true
                break
            }
        } catch {
            # Expected during startup
        }

        $pct = [math]::Round(($i / $HealthCheckAttempts) * 100)
        Write-Host "`r    Attempt $i/$HealthCheckAttempts ($pct%)..." -NoNewline -ForegroundColor Gray
        Start-Sleep -Seconds 3
    }

    Write-Host ""

    if ($healthy) {
        Write-OK "PerceptionMedia is healthy on port $ServicePort."
    } else {
        Write-Err "PerceptionMedia did not become healthy after $HealthCheckAttempts attempts."
        Write-Host "    Check logs: docker logs -f aitheros-perception-media" -ForegroundColor Yellow
    }

    # ============================================================================
    # Step 10: Voice synthesis test
    # ============================================================================
    if (-not $SkipTest -and $healthy) {
        Write-Step "Running voice synthesis test..."

        try {
            $testBody = @{
                text   = 'Hello. AitherOS voice capabilities are now operational.'
                format = 'wav'
            } | ConvertTo-Json

            $testResponse = Invoke-WebRequest -Uri "http://localhost:$ServicePort/voice/synthesize" `
                                              -Method POST -Body $testBody `
                                              -ContentType 'application/json' `
                                              -TimeoutSec 30 -ErrorAction Stop

            $contentType = $testResponse.Headers['Content-Type']
            $contentLength = $testResponse.RawContentLength

            if ($contentLength -gt 1000) {
                Write-OK "Voice synthesis successful."
                Write-Host "    Response: $contentType, $([math]::Round($contentLength / 1024, 1)) KB" -ForegroundColor Gray
                Write-Host "    Provider: $ttsProvider" -ForegroundColor Gray

                # Save test audio for manual verification
                $testAudioPath = Join-Path $ModelCacheDir 'test_output.wav'
                [System.IO.File]::WriteAllBytes($testAudioPath, $testResponse.Content)
                Write-Host "    Test audio saved: $testAudioPath" -ForegroundColor Gray
            } else {
                Write-Warn "Synthesis returned only $contentLength bytes. May indicate an error."
            }
        } catch {
            $errMsg = $_.Exception.Message
            # Try to parse error body
            try {
                $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($errBody.detail) { $errMsg = $errBody.detail }
            } catch {}

            Write-Warn "Voice synthesis test failed: $errMsg"
            Write-Host "    This may be normal if the model is still loading." -ForegroundColor Yellow
            Write-Host "    Try again in 30-60 seconds, or check logs:" -ForegroundColor Yellow
            Write-Host "    docker logs -f aitheros-perception-media" -ForegroundColor Gray
        }
    } elseif (-not $SkipTest -and -not $healthy) {
        Write-Warn "Skipping synthesis test (service not healthy)."
    } else {
        Write-Warn "Skipping synthesis test (-SkipTest)."
    }
} else {
    Write-Warn "Skipping Docker service start (-SkipDocker). Configuration saved only."
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  AitherVoice setup complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Service Port:       $ServicePort (PerceptionMedia compound)" -ForegroundColor White
Write-Host "  Model Cache:        $ModelCacheDir" -ForegroundColor White
Write-Host ""
Write-Host "  Capabilities:" -ForegroundColor Yellow

if ($useLocalTts) {
    Write-Host "    TTS:  XTTS v2 (local GPU)" -ForegroundColor White
    Write-Host "          - Multi-speaker voice cloning" -ForegroundColor Gray
    Write-Host "          - 16 languages supported" -ForegroundColor Gray
    Write-Host "          - ~200ms latency on GPU" -ForegroundColor Gray
} else {
    Write-Host "    TTS:  Edge-TTS (Microsoft online)" -ForegroundColor White
    Write-Host "          - 300+ voices, 100+ languages" -ForegroundColor Gray
    Write-Host "          - Free, no API key needed" -ForegroundColor Gray
    Write-Host "          - Requires internet connection" -ForegroundColor Gray
}

Write-Host ""

if ($useLocalStt) {
    Write-Host "    STT:  faster-whisper (local GPU)" -ForegroundColor White
    Write-Host "          - Model: base.en" -ForegroundColor Gray
    Write-Host "          - ~10x realtime on GPU" -ForegroundColor Gray
    Write-Host "          - Fully offline capable" -ForegroundColor Gray
} else {
    Write-Host "    STT:  OpenAI Whisper API (cloud)" -ForegroundColor White
    Write-Host "          - Whisper large-v3 quality" -ForegroundColor Gray
    Write-Host "          - Requires internet + API key" -ForegroundColor Gray
}

Write-Host ""
Write-Host "    Fallback TTS: Piper (CPU, offline, low quality)" -ForegroundColor Gray

if ($gpuAvailable) {
    Write-Host ""
    Write-Host "  GPU:    $gpuName ($gpuVramMB MB)" -ForegroundColor White
}

Write-Host ""
Write-Host "  API Endpoints:" -ForegroundColor Yellow
Write-Host "    POST http://localhost:$ServicePort/voice/synthesize   # Text-to-speech" -ForegroundColor Gray
Write-Host "    POST http://localhost:$ServicePort/voice/transcribe   # Speech-to-text" -ForegroundColor Gray
Write-Host "    GET  http://localhost:$ServicePort/voice/voices       # List available voices" -ForegroundColor Gray
Write-Host "    GET  http://localhost:$ServicePort/health             # Health check" -ForegroundColor Gray
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor Yellow
Write-Host "    docker logs -f aitheros-perception-media    # Follow logs" -ForegroundColor Gray
Write-Host "    docker restart aitheros-perception-media     # Restart service" -ForegroundColor Gray
Write-Host ""
