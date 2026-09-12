#Requires -Version 7.0

<#
.SYNOPSIS
    Pull local models and stand up an inference backend with `adk setup`.
.DESCRIPTION
    Runs `adk setup --tier <Tier> --non-interactive` (vLLM in Docker, Ollama,
    or native llama.cpp depending on the tier) and lets adk pull the weights
    for that tier. Skipped when `adk status` already shows vLLM/Ollama/awnode
    UP - starting a second vLLM next to a live one OOMs the GPU.

    Tiers (adk setup --help): nano (6-8 GB), lite, standard, standard-tq4
    (12-16 GB), full (24 GB+), hybrid, hybrid-tq4, ollama, llamacpp (native,
    no Docker - the right answer for a laptop). Default 'auto' lets adk pick
    from the detected GPU. First run downloads 16-30 GB; expect 10-15 min.
.PARAMETER Tier
    adk tier, or 'auto' (default).
.PARAMETER HfToken
    HuggingFace token for gated weights (optional).
.PARAMETER Force
    Run setup even if a backend is UP (passes --force).
.PARAMETER DryRun
    Pass --dry-run to adk setup (shows the plan, pulls nothing).
.EXAMPLE
    ./3221_Install-LocalModels.ps1 -Tier llamacpp
.NOTES
    Stage: Onboarding
    Dependencies: 3215_Install-AWDK
    Tags: inference, models, vllm, ollama, llamacpp, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('auto', 'nano', 'lite', 'standard', 'standard-tq4', 'full', 'hybrid', 'hybrid-tq4', 'ollama', 'llamacpp')]
    [string]$Tier = 'auto',
    [string]$HfToken = '',
    [switch]$Force,
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

Update-AitherSessionPath
$adk = Get-Command adk -ErrorAction SilentlyContinue
if (-not $adk) { throw "adk not found. Run 32-onboarding/3215_Install-AWDK first." }

$status = (& $adk.Source status 2>&1 | Out-String)
$localUp = @($status -split "`r?`n" | Where-Object { $_ -match '\[\+\]\s+(vLLM|Ollama|awnode|Genesis)' })
if ($localUp.Count -gt 0 -and -not $Force -and -not $DryRun) {
    Write-Host "Local inference already UP; not running adk setup (use -Force to add another):`n  $($localUp -join "`n  ")"
    return
}

$setupArgs = @('setup', '--non-interactive')
if ($Tier -ne 'auto') { $setupArgs += @('--tier', $Tier) }
if ($HfToken) { $setupArgs += @('--hf-token', $HfToken) }
if ($Force)   { $setupArgs += '--force' }
if ($DryRun)  { $setupArgs += '--dry-run' }

Write-Host "adk $(($setupArgs | Where-Object { $_ -ne $HfToken }) -join ' ')"
if ($DryRun -or $PSCmdlet.ShouldProcess("adk", ($setupArgs -join ' '))) {
    & $adk.Source @setupArgs
    if ($LASTEXITCODE -ne 0) { throw "adk setup exited with code $LASTEXITCODE" }
}

if (-not $DryRun) {
    $after = (& $adk.Source status 2>&1 | Out-String)
    $nowUp = @($after -split "`r?`n" | Where-Object { $_ -match '\[\+\]\s+(vLLM|Ollama|awnode|Genesis)' })
    if ($nowUp.Count -eq 0) { throw "adk setup finished but no local backend reports UP. Run 'adk status' / 'adk doctor'." }
    Write-Host "Local inference UP:`n  $($nowUp -join "`n  ")" -ForegroundColor Green
}
