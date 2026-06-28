#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: Python
# Description: Starts the ComfyUI server
# Tags: ai, comfyui, server

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallPath,

    [Parameter()]
    [switch]$Listen,

    [Parameter()]
    [string]$Port = "8188",

    # Dynamic VRAM management. ComfyUI's smart memory manager streams model
    # weights between RAM and VRAM layer-by-layer; the lower modes let large
    # models (e.g. Lance ~40GB) run on small cards (12GB or less).
    #   auto    - detect GPU VRAM via nvidia-smi and pick a sensible mode
    #   high    - keep everything resident in VRAM (--highvram, fastest, needs headroom)
    #   normal  - default ComfyUI behaviour (--normalvram)
    #   low     - aggressive layer streaming (--lowvram, big models on small cards)
    #   no      - keep weights in system RAM, stream every layer (--novram, slowest, smallest footprint)
    #   cpu     - run entirely on CPU (--cpu, no GPU required)
    [Parameter()]
    [ValidateSet('auto', 'high', 'normal', 'low', 'no', 'cpu')]
    [string]$VramMode = 'auto',

    # Reserve this many MB of VRAM for the OS/other apps (ComfyUI --reserve-vram).
    [Parameter()]
    [int]$ReserveVramMB = 0,

    # Keep the VAE on CPU to free VRAM for the diffusion model (--cpu-vae).
    [Parameter()]
    [switch]$CpuVae
)

. "$PSScriptRoot/_init.ps1"

# ---------------------------------------------------------------------------
# Detect total GPU VRAM (MB) via nvidia-smi. Returns 0 when unavailable.
# ---------------------------------------------------------------------------
function Get-GpuVramMB {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return 0 }
    try {
        $out = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return 0 }
        # Take the largest GPU if more than one is present.
        $max = 0
        foreach ($line in @($out)) {
            $val = 0
            if ([int]::TryParse(($line.Trim()), [ref]$val) -and $val -gt $max) { $max = $val }
        }
        return $max
    }
    catch {
        return 0
    }
}

# Map a VRAM budget (MB) to a ComfyUI memory mode.
function Resolve-VramMode {
    param([int]$VramMB)
    if ($VramMB -le 0) { return 'normal' }   # unknown - let ComfyUI decide
    if ($VramMB -ge 24000) { return 'high' }
    if ($VramMB -ge 12000) { return 'normal' }
    if ($VramMB -ge 6000) { return 'low' }
    return 'no'
}

# Set default InstallPath if not provided
if ([string]::IsNullOrEmpty($InstallPath)) {
    if ($IsWindows) {
        # Auto-detect ComfyUI location
        $PossiblePaths = @("E:\ComfyUI", "D:\ComfyUI", "C:\ComfyUI", "$env:USERPROFILE\ComfyUI")
        foreach ($path in $PossiblePaths) {
            if (Test-Path $path) {
                $InstallPath = $path
                Write-Host "Auto-detected ComfyUI at: $InstallPath" -ForegroundColor Cyan
                break
            }
        }
        # Fallback
        if ([string]::IsNullOrEmpty($InstallPath)) {
            if (Test-Path "E:") {
                $InstallPath = "E:\ComfyUI"
            }
            elseif (Test-Path "D:") {
                $InstallPath = "D:\ComfyUI"
            }
            else {
                $InstallPath = "C:\ComfyUI"
            }
        }
    }
    else {
        $InstallPath = Join-Path $env:HOME "ComfyUI"
    }
}

if (-not (Test-Path $InstallPath)) {
    Write-Error "ComfyUI directory not found at $InstallPath"
    exit 1
}

$venvPython = if ($IsWindows) { Join-Path $InstallPath "venv\Scripts\python.exe" } else { Join-Path $InstallPath "venv/bin/python" }
$mainPy = Join-Path $InstallPath "main.py"

if (-not (Test-Path $venvPython)) {
    Write-Error "Python venv not found at $venvPython"
    exit 1
}

$argsList = @($mainPy)
if ($Listen) { $argsList += "--listen" }
if ($Port) { $argsList += "--port"; $argsList += $Port }

# --- Dynamic VRAM resolution ------------------------------------------------
$resolvedMode = $VramMode
if ($VramMode -eq 'auto') {
    $vramMB = Get-GpuVramMB
    $resolvedMode = Resolve-VramMode -VramMB $vramMB
    if ($vramMB -gt 0) {
        Write-Host ("Detected {0} MB GPU VRAM -> '{1}' mode" -f $vramMB, $resolvedMode) -ForegroundColor Cyan
    }
    else {
        Write-Host "No NVIDIA GPU detected (nvidia-smi unavailable) -> 'normal' mode" -ForegroundColor Yellow
    }
}

switch ($resolvedMode) {
    'high'   { $argsList += "--highvram" }
    'normal' { $argsList += "--normalvram" }
    'low'    { $argsList += "--lowvram" }
    'no'     { $argsList += "--novram" }
    'cpu'    { $argsList += "--cpu" }
}

if ($ReserveVramMB -gt 0) {
    # ComfyUI --reserve-vram takes a value in GB (float).
    $reserveGb = [math]::Round($ReserveVramMB / 1024.0, 2)
    $argsList += "--reserve-vram"; $argsList += "$reserveGb"
}

if ($CpuVae) { $argsList += "--cpu-vae" }

Write-Host "Starting ComfyUI..." -ForegroundColor Green
Write-Host "VRAM mode: $resolvedMode" -ForegroundColor Green
Write-Host "Command: $venvPython $argsList" -ForegroundColor DarkGray

& $venvPython @argsList
