#Requires -Version 7.0

<#
.SYNOPSIS
    Install ComfyUI (image-generation backend) on a self-hosted node — venv, deps, CUDA-aware torch.

.DESCRIPTION
    Stands up ComfyUI in its own Python venv so a self-service subscriber's Canvas/Iris jobs can run
    on THEIR hardware. This is the image-gen twin of 3241_Install-LlamaCppRpc (LLM). It does NOT start
    the server (3252) or register it with the fleet (3253) — one concern per script, each idempotent.

    IDEMPOTENT: re-run to reconcile drift. An existing clone is `git pull`-ed; an existing venv is
    reused; torch is only (re)installed when absent or the wrong CUDA build. Nothing is destroyed.

    CUDA-AWARE: detects an NVIDIA GPU via `nvidia-smi` and installs the matching torch wheel
    (cu121/cu124/cu130 by driver), else the CPU wheel with a loud warning (CPU SDXL is minutes/image).
    The wheel index is the ONE thing worth getting right — a mismatched torch is a silent
    "CUDA not available" that falls back to CPU and looks like "ComfyUI is just slow".

    VERIFY: the final check imports torch IN THE VENV and asserts torch.cuda.is_available() matches the
    detected hardware. "pip said OK" is not the check — a wheel can install and still not see the GPU.

    Exit codes: 0 installed+verified | 1 install failed | 2 verify failed (torch cannot see the GPU it
                should) | 3 git/clone failed | 5 param invalid | 10 prerequisite missing (python/git).

.PARAMETER InstallRoot
    Where ComfyUI is cloned. Default: $HOME\ComfyUI. The models tree lives under <InstallRoot>\models.

.PARAMETER Ref
    Git ref (branch/tag/sha) to check out. Default: master. Pin a sha for reproducible deploys.

.PARAMETER TorchIndex
    Override the torch wheel index (e.g. https://download.pytorch.org/whl/cu130). Omit to auto-detect
    from the NVIDIA driver version. Pass 'cpu' to force the CPU wheel.

.PARAMETER PythonExe
    Python interpreter to build the venv from. Default: the `python` on PATH (must be 3.10–3.12).

.PARAMETER DryRun
    Plan mode: show what would change, make no changes.

.EXAMPLE
    ./3250_Install-ComfyUI.ps1
.EXAMPLE
    ./3250_Install-ComfyUI.ps1 -InstallRoot D:\ComfyUI -Ref v0.3.10 -TorchIndex https://download.pytorch.org/whl/cu130

.NOTES
    Stage: Onboarding | Order: 3250 | Platform: Windows/pwsh (Linux venv paths handled too)
    Tags: comfyui, image-gen, self-host, byo-backend, canvas
    Next: 3251 (fetch a default SFW checkpoint) -> 3252 (start) -> 3253 (register with the fleet).
    Contract: 3253 advertises capabilities:['comfyui'] + metadata.comfyui_url; Canvas jobs route to
              registered nodes with those capabilities and a valid comfyui_url endpoint.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallRoot = (Join-Path $HOME 'ComfyUI'),
    [string]$Ref = 'master',
    [string]$TorchIndex,
    [string]$PythonExe = 'python',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Log($m, $c = 'Cyan') { Write-Host ("[3250] " + $m) -ForegroundColor $c }
function LogSuccess($m) { Log $m 'Green' }
function LogWarn($m) { Log $m 'Yellow' }
function LogError($m) { Log $m 'Red' }
function LogSkip($m) { Log $m 'DarkGray' }

$IsWin = $IsWindows -or ($env:OS -eq 'Windows_NT')
$VenvPython = if ($IsWin) { Join-Path $InstallRoot '.venv\Scripts\python.exe' } else { Join-Path $InstallRoot '.venv/bin/python' }
$RepoUrl = 'https://github.com/comfyanonymous/ComfyUI.git'

function Require-Cmd($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        LogError "prerequisite '$name' not found on PATH"
        exit 10
    }
}

# Detect the CUDA torch wheel index from the NVIDIA driver, or CPU if no GPU.
function Resolve-TorchIndex {
    if ($TorchIndex) {
        if ($TorchIndex -eq 'cpu') { return 'https://download.pytorch.org/whl/cpu' }
        return $TorchIndex
    }
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        LogWarn "no nvidia-smi — installing the CPU torch wheel. SDXL on CPU is MINUTES per image."
        return 'https://download.pytorch.org/whl/cpu'
    }
    try {
        $ver = (& nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>$null | Select-Object -First 1).Trim()
    } catch { $ver = '' }
    # Driver->CUDA runtime floor (pytorch ships cu121/cu124/cu128/cu130). Newer driver = pick the
    # highest wheel it supports; the wheel bundles its own CUDA runtime, only the driver must be >=.
    $major = 0; if ($ver -match '^(\d+)') { $major = [int]$Matches[1] }
    $idx = if ($major -ge 570) { 'cu130' } elseif ($major -ge 550) { 'cu124' } elseif ($major -ge 525) { 'cu121' } else { 'cu121' }
    Log "NVIDIA driver $ver -> torch wheel $idx"
    return "https://download.pytorch.org/whl/$idx"
}

if ($DryRun) { Log 'DRY RUN — no changes will be made' 'Magenta' }

Require-Cmd git
Require-Cmd $PythonExe

# 1. Clone or update ComfyUI
if (Test-Path (Join-Path $InstallRoot '.git')) {
    LogSkip "ComfyUI present at $InstallRoot — updating to $Ref"
    if (-not $DryRun) {
        try {
            git -C $InstallRoot fetch --quiet --depth 1 origin $Ref 2>&1 | Out-Null
            git -C $InstallRoot checkout --quiet $Ref 2>&1 | Out-Null
            git -C $InstallRoot pull --quiet --ff-only 2>&1 | Out-Null
        } catch {
            LogError "git update failed: $_"; exit 3
        }
    }
} else {
    Log "cloning ComfyUI ($Ref) -> $InstallRoot"
    if (-not $DryRun) {
        try {
            git clone --quiet --depth 1 --branch $Ref $RepoUrl $InstallRoot 2>&1 | Out-Null
        } catch {
            # --branch fails for a raw sha; fall back to full clone + checkout.
            try {
                git clone --quiet $RepoUrl $InstallRoot 2>&1 | Out-Null
                git -C $InstallRoot checkout --quiet $Ref 2>&1 | Out-Null
            } catch { LogError "git clone failed: $_"; exit 3 }
        }
    }
}

# 2. Create the venv
if (Test-Path $VenvPython) {
    LogSkip "venv present"
} else {
    Log "creating venv"
    if (-not $DryRun) {
        & $PythonExe -m venv (Join-Path $InstallRoot '.venv')
        if (-not (Test-Path $VenvPython)) { LogError "venv creation failed"; exit 1 }
    }
}

# 3. torch (CUDA-matched) then ComfyUI requirements
$idxUrl = Resolve-TorchIndex
Log "installing torch from $idxUrl"
if (-not $DryRun) {
    try {
        & $VenvPython -m pip install --quiet --upgrade pip 2>&1 | Out-Null
        & $VenvPython -m pip install --quiet torch torchvision torchaudio --index-url $idxUrl
        & $VenvPython -m pip install --quiet -r (Join-Path $InstallRoot 'requirements.txt')
    } catch { LogError "pip install failed: $_"; exit 1 }
}

# 4. VERIFY: torch must see the GPU it was built for (pip-OK is not the check)
if ($DryRun) { LogSuccess 'DRY RUN complete — install plan is valid'; exit 0 }

$expectCuda = ($idxUrl -notmatch '/cpu$')
$probe = & $VenvPython -c "import torch,sys; print(torch.cuda.is_available()); sys.exit(0)" 2>&1
$cudaOk = ($probe -match 'True')
if ($expectCuda -and -not $cudaOk) {
    LogError "torch installed but torch.cuda.is_available()=False on a machine with an NVIDIA GPU."
    LogError "This is the classic wrong-wheel trap: ComfyUI would silently run on CPU (minutes/image)."
    LogError "Re-run with an explicit -TorchIndex matching your driver, or check the driver install."
    exit 2
}
LogSuccess ("ComfyUI installed at {0} (torch.cuda={1})" -f $InstallRoot, $cudaOk)
Log "next: 3251_Fetch-ImageModelPack -> 3252_Start-ComfyUI -> 3253_Register-ImageBackend"
exit 0
