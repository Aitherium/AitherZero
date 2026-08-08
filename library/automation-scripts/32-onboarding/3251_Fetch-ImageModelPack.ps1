#Requires -Version 7.0

<#
.SYNOPSIS
    Download a default SFW SDXL checkpoint into a ComfyUI models tree — the image twin of 3243.

.DESCRIPTION
    A fresh ComfyUI has no weights, so Canvas jobs 404 until a checkpoint exists. This fetches ONE
    known-good, permissively-licensed, SFW SDXL checkpoint into <ModelsRoot>\checkpoints so a
    self-hosted subscriber's first generation works. It matches the platform Canvas default
    (`waiIllustriousSDXL_v140`) by name so the same prompt/preset behaves the same on either backend.

    IDEMPOTENT + RESUMABLE: an already-present file with the right size is skipped; a partial download
    resumes (HTTP Range). The file is verified by SHA256 when a hash is known, else by size floor — a
    truncated checkpoint is the classic "ComfyUI loads then errors on the first sample" failure.

    SFW BY DEFAULT: the pack list here is deliberately general-purpose/SFW. This is the customer's own
    box, but the DEFAULT we hand them is not adult-tuned — the restricted models are a separate,
    opt-in concern (consistent with a conservative defaults philosophy).

    Exit codes: 0 fetched+verified | 1 download failed | 2 verify failed (size/hash) | 5 param invalid
                | 10 no network / source unreachable.

.PARAMETER ModelsRoot
    ComfyUI models root. Default: $HOME\ComfyUI\models. Checkpoints land in <ModelsRoot>\checkpoints.

.PARAMETER Pack
    Which pack to fetch. 'sdxl-sfw' (default): one general SDXL checkpoint + the SDXL VAE.
    'minimal': the checkpoint only.

.PARAMETER Url
    Override the checkpoint download URL (e.g. a self-hosted mirror or a Civitai/HF link). When set,
    -Sha256 SHOULD accompany it; without a hash the check falls back to a size floor.

.PARAMETER Sha256
    Expected SHA256 of the checkpoint, for exact verification.

.PARAMETER DryRun
    Plan mode: show what would be fetched, download nothing.

.EXAMPLE
    ./3251_Fetch-ImageModelPack.ps1
.EXAMPLE
    ./3251_Fetch-ImageModelPack.ps1 -ModelsRoot D:\ComfyUI\models -Url https://my-mirror/wai.safetensors -Sha256 abc123...

.NOTES
    Stage: Onboarding | Order: 3251 | Platform: Windows/pwsh
    Tags: comfyui, models, checkpoint, sdxl, self-host
    A default URL is intentionally NOT hardcoded to a specific host that may rot — set MF_CKPT_URL /
    -Url to your chosen mirror. The script fails LOUD (exit 10) rather than guessing a dead link.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ModelsRoot = (Join-Path $HOME 'ComfyUI\models'),
    [ValidateSet('sdxl-sfw', 'minimal')]
    [string]$Pack = 'sdxl-sfw',
    [string]$Url,
    [string]$Sha256,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Log($m, $c = 'Cyan') { Write-Host ("[3251] " + $m) -ForegroundColor $c }
function LogSuccess($m) { Log $m 'Green' }
function LogWarn($m) { Log $m 'Yellow' }
function LogError($m) { Log $m 'Red' }
function LogSkip($m) { Log $m 'DarkGray' }

# The canonical filename used by Canvas presets. Ensure this name matches your Canvas application's default model setting.
$CkptName = 'waiIllustriousSDXL_v140.safetensors'
$CkptUrl = if ($Url) { $Url } elseif ($env:MF_CKPT_URL) { $env:MF_CKPT_URL } else { $null }
$MinBytes = 1GB   # an SDXL checkpoint is ~6.5GB; anything under 1GB is a truncated/HTML error body.

$VaeName = 'sdxl_vae.safetensors'
$VaeUrl = if ($env:MF_VAE_URL) { $env:MF_VAE_URL } else { 'https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors' }

function Fetch-File {
    param([string]$DestDir, [string]$Name, [string]$SrcUrl, [long]$FloorBytes, [string]$Hash)
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $dest = Join-Path $DestDir $Name

    if (Test-Path $dest) {
        $sz = (Get-Item $dest).Length
        if ($Hash) {
            $have = (Get-FileHash $dest -Algorithm SHA256).Hash
            if ($have -ieq $Hash) { LogSkip "$Name present + hash OK"; return $true }
            LogWarn "$Name present but hash mismatch — refetching"
        } elseif ($sz -ge $FloorBytes) {
            LogSkip "$Name present ($([math]::Round($sz/1GB,2)) GB) — skipping (no hash to check)"; return $true
        } else {
            LogWarn "$Name present but under size floor ($sz B) — truncated, refetching"
        }
    }

    if ($DryRun) { Log "WOULD fetch $Name from $SrcUrl -> $dest"; return $true }

    Log "downloading $Name (resumable) from $SrcUrl"
    try {
        # curl.exe: -C - resumes, -f fails on HTTP error (so an HTML 404 body never lands as a .safetensors).
        & curl.exe -fL -C - --retry 3 --retry-delay 5 -o $dest $SrcUrl
        if ($LASTEXITCODE -ne 0) { LogError "download failed (curl exit $LASTEXITCODE)"; return $false }
    } catch { LogError "download failed: $_"; return $false }

    $sz = (Get-Item $dest).Length
    if ($sz -lt $FloorBytes) { LogError "$Name is $sz B, under the $FloorBytes B floor — truncated"; return $false }
    if ($Hash) {
        $have = (Get-FileHash $dest -Algorithm SHA256).Hash
        if ($have -ine $Hash) { LogError "$Name SHA256 mismatch: got $have"; return $false }
        LogSuccess "$Name verified (SHA256)"
    } else {
        LogSuccess "$Name fetched ($([math]::Round($sz/1GB,2)) GB; no hash supplied — size-verified only)"
    }
    return $true
}

if ($DryRun) { Log 'DRY RUN — nothing will be downloaded' 'Magenta' }

if (-not $CkptUrl) {
    LogError "No checkpoint URL. Pass -Url <mirror/HF/Civitai link> or set MF_CKPT_URL."
    LogError "A default host is deliberately not baked in (dead links rot silently). Refusing to guess."
    exit 10
}

$ck = Fetch-File -DestDir (Join-Path $ModelsRoot 'checkpoints') -Name $CkptName -SrcUrl $CkptUrl -FloorBytes $MinBytes -Hash $Sha256
if (-not $ck) { exit ($DryRun ? 0 : 2) }

if ($Pack -eq 'sdxl-sfw') {
    $vae = Fetch-File -DestDir (Join-Path $ModelsRoot 'vae') -Name $VaeName -SrcUrl $VaeUrl -FloorBytes 100MB -Hash ''
    if (-not $vae) { LogWarn "VAE fetch failed — SDXL works with the baked VAE, continuing" }
}

LogSuccess "image model pack '$Pack' ready under $ModelsRoot"
Log "next: 3252_Start-ComfyUI -> 3253_Register-ImageBackend"
exit 0
