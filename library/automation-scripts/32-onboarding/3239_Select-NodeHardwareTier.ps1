#Requires -Version 7.0

<#
.SYNOPSIS
    Detect this node's GPU and pick its hardware tier + default model. No GPU => the
    smallest working model, CPU-only, enhancement loops on. No user step required.

.DESCRIPTION
    Plan spec P5 ("no GPU is not a dead end"): the onboarding flow must detect hardware
    and, when there is no GPU, default to the smallest model that still works plus the
    enhancement loops / knowledge neurons that make it useful.

    The tier ladder mirrors awdk/adk/setup.py `_select_profile` and the model lists mirror
    `_recommended_models` (the static fallback the ADK wizard uses), so a node onboarded by
    AitherZero and a node set up by `adk setup` land on the same profile.

    Detection order: nvidia-smi (NVIDIA, name + VRAM) -> rocm-smi (AMD) -> Apple Silicon
    (macOS arm64) -> none. A probe that is missing or errors counts as "no GPU of that vendor",
    never as a failure: a machine without a GPU is the case this step exists for.

    Output:
      - ~/.aither/node-hardware.json  (profile, cpu_only, default_model, models, enhancement)
      - process env for later playbook steps and the installer they spawn:
          AITHER_HARDWARE_PROFILE, AITHER_HARDWARE_TIER, AITHER_CPU_ONLY, AITHER_NODE_MODEL,
          AITHER_ENHANCEMENT_LOOPS
      - optionally `ollama pull <default_model>` when -PullModel and ollama is on PATH.

.PARAMETER Tier
    'auto' (default) detects. Any profile name pins it (e.g. 'cpu_only').

.PARAMETER OutputFile
    Where to write the profile JSON. Default: ~/.aither/node-hardware.json.

.PARAMETER GpuProbeJson
    Inject a probe result instead of running nvidia-smi/rocm-smi. JSON: {"vendor":"none"} or
    {"vendor":"nvidia","name":"RTX 4090","vram_mb":24564}. For tests and air-gapped planning.

.PARAMETER PullModel
    Pull the default model with ollama when ollama is installed.

.PARAMETER DryRun
    Detect and print; write nothing, pull nothing, set no env.

.NOTES
    Stage: Onboarding | Order: 3239 | Platform: Windows, Linux, macOS
    Tags: onboarding, hardware, gpu, cpu-only, tier, model-selection
    Dependencies: none (nvidia-smi / rocm-smi / ollama are optional)
    Exit Codes: 0 success | 1 could not write the profile
#>

[CmdletBinding()]
param(
    [string]$Tier = 'auto',
    [string]$OutputFile,
    [string]$GpuProbeJson,
    [switch]$PullModel,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Mirrors awdk/adk/setup.py _recommended_models (static fallback). Keep in step.
$ProfileModels = [ordered]@{
    cpu_only      = @('gemma4:4b', 'nomic-embed-text')
    minimal       = @('gemma4:4b', 'nomic-embed-text')
    nvidia_low    = @('gemma4:4b', 'nomic-embed-text')
    nvidia_mid    = @('nemotron-orchestrator-8b', 'deepseek-r1:8b', 'nomic-embed-text')
    nvidia_high   = @('nemotron-orchestrator-8b', 'deepseek-r1:14b', 'nomic-embed-text', 'gemma4:27b')
    nvidia_ultra  = @('nemotron-orchestrator-8b', 'deepseek-r1:32b', 'nomic-embed-text', 'gemma4:27b')
    apple_silicon = @('gemma4:4b', 'deepseek-r1:8b', 'nomic-embed-text')
    amd_low       = @('gemma4:4b', 'nomic-embed-text')
    amd           = @('nemotron-orchestrator-8b', 'deepseek-r1:8b', 'nomic-embed-text')
    amd_high      = @('nemotron-orchestrator-8b', 'deepseek-r1:14b', 'nomic-embed-text', 'gemma4:27b')
}

# AitherHardware tier names (lib/utils/AitherHardware.py .tier) per profile.
$ProfileTier = @{
    cpu_only = 'minimal'; minimal = 'minimal'; nvidia_low = 'minimal'; amd_low = 'minimal'
    nvidia_mid = 'high'; amd = 'high'; apple_silicon = 'standard'
    nvidia_high = 'ultra'; amd_high = 'ultra'; nvidia_ultra = 'ultra'
}

function Get-GpuProbe {
    if ($GpuProbeJson) { return ($GpuProbeJson | ConvertFrom-Json -AsHashtable) }

    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            $line = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null |
                Select-Object -First 1
            if ($LASTEXITCODE -eq 0 -and $line) {
                $parts = "$line".Split(',')
                return @{ vendor = 'nvidia'; name = $parts[0].Trim(); vram_mb = [int]($parts[1].Trim()) }
            }
        } catch { Write-Verbose "nvidia-smi failed: $_" }
    }
    if (Get-Command rocm-smi -ErrorAction SilentlyContinue) {
        try {
            $j = & rocm-smi --showproductname --showmeminfo vram --json 2>$null | ConvertFrom-Json -AsHashtable
            if ($LASTEXITCODE -eq 0 -and $j) {
                $card = $j.Values | Select-Object -First 1
                $bytes = [double]($card['VRAM Total Memory (B)'])
                return @{ vendor = 'amd'; name = "$($card['Card series'])"; vram_mb = [int]($bytes / 1MB) }
            }
        } catch { Write-Verbose "rocm-smi failed: $_" }
    }
    if ($IsMacOS) {
        try {
            if ((& sysctl -n hw.optional.arm64 2>$null) -eq '1') {
                return @{ vendor = 'apple'; name = 'Apple Silicon'; vram_mb = 0 }
            }
        } catch { Write-Verbose "sysctl failed: $_" }
    }
    return @{ vendor = 'none'; name = ''; vram_mb = 0 }
}

function Select-HardwareProfile([hashtable]$Gpu) {
    # Mirrors awdk/adk/setup.py _select_profile.
    $vendor = "$($Gpu.vendor)".ToLower()
    $vram = [int]($Gpu.vram_mb)
    if ($vendor -in @('', 'none')) { return 'cpu_only' }
    if ($vendor -eq 'apple') { return 'apple_silicon' }
    if ($vendor -eq 'amd') {
        if ($vram -ge 20000) { return 'amd_high' }
        if ($vram -ge 12000) { return 'amd' }
        return 'amd_low'
    }
    if ($vram -ge 48000) { return 'nvidia_ultra' }
    if ($vram -ge 24000) { return 'nvidia_high' }
    if ($vram -ge 12000) { return 'nvidia_mid' }
    if ($vram -ge 6000) { return 'nvidia_low' }
    return 'minimal'
}

$gpu = Get-GpuProbe
$profileName = if ($Tier -and $Tier -ne 'auto') { $Tier } else { Select-HardwareProfile $gpu }
if (-not $ProfileModels.Contains($profileName)) {
    Write-Host "[FAIL] Unknown hardware profile '$profileName' (known: $($ProfileModels.Keys -join ', '))" -ForegroundColor Red
    exit 1
}
$models = @($ProfileModels[$profileName])
$cpuOnly = ($profileName -eq 'cpu_only')

$result = [ordered]@{
    profile       = $profileName
    tier          = $ProfileTier[$profileName]
    cpu_only      = $cpuOnly
    gpu           = $gpu
    default_model = $models[0]
    models        = $models
    # No GPU: the small model is carried by enhancement loops (reflect/retry) and the
    # knowledge neurons (web + docs retrieval) instead of raw parameter count.
    enhancement   = [ordered]@{
        loops   = $cpuOnly -or ($ProfileTier[$profileName] -eq 'minimal')
        neurons = @('web', 'docs')
    }
    source        = if ($Tier -ne 'auto') { 'pinned' } elseif ($GpuProbeJson) { 'injected' } else { 'detected' }
}

$label = if ($cpuOnly) { 'NO GPU -> CPU-only, smallest model' } else { "$($gpu.vendor) $($gpu.name) $($gpu.vram_mb)MB" }
Write-Host "[OK] Hardware: $label | profile=$profileName tier=$($result.tier) model=$($result.default_model)" -ForegroundColor Green

$json = $result | ConvertTo-Json -Depth 5
if ($DryRun) {
    Write-Host "[SKIP] DRY RUN: profile not written, env not set" -ForegroundColor Yellow
    Write-Output $json
    exit 0
}

if (-not $OutputFile) {
    $homeDir = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $OutputFile = Join-Path (Join-Path $homeDir '.aither') 'node-hardware.json'
}
try {
    $dir = Split-Path -Parent $OutputFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $OutputFile -Value $json -Encoding utf8NoBOM
} catch {
    Write-Host "[FAIL] Could not write $OutputFile : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Wrote $OutputFile" -ForegroundColor Green

$env:AITHER_HARDWARE_PROFILE = $profileName
$env:AITHER_HARDWARE_TIER = $result.tier
$env:AITHER_CPU_ONLY = "$cpuOnly".ToLower()
$env:AITHER_NODE_MODEL = $result.default_model
$env:AITHER_ENHANCEMENT_LOOPS = "$($result.enhancement.loops)".ToLower()

if ($PullModel) {
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        & ollama pull $result.default_model
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[WARN] ollama pull $($result.default_model) exited $LASTEXITCODE" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[SKIP] ollama not installed; model pull deferred to the node installer" -ForegroundColor Yellow
    }
}

Write-Output $json
exit 0
