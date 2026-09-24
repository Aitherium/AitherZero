#Requires -Version 7.0

<#
.SYNOPSIS
    Make sure this machine has an inference backend: reuse one that is UP, else `adk quickstart`.
.DESCRIPTION
    Reads `adk status`. If any backend (vLLM, Ollama, Genesis, awnode, cloud
    Gateway) is already UP, does nothing — running `adk setup`/`quickstart`
    next to a live vLLM starts a second one and OOMs the GPU (awdk's own
    AGENT_PROMPT warns about this). Otherwise runs `adk quickstart --cloud`
    (no GPU needed; uses the account from `adk login`) or, with -Mode local,
    `adk quickstart` (detects GPU, pulls models; interactive, 10-15 min).
.PARAMETER Mode
    cloud (default) or local.
.PARAMETER Force
    Run quickstart even if a backend is already UP.
.PARAMETER DryRun
    Print what would run.
.EXAMPLE
    ./3264_Connect-Inference.ps1
.NOTES
    Stage: Onboarding
    Dependencies: 3260_Install-AWDK, 3263_Connect-Aitherium
    Tags: inference, adk, quickstart, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('cloud', 'local')]
    [string]$Mode = 'cloud',
    [switch]$Force,
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

if (Get-Command Update-AitherSessionPath -ErrorAction SilentlyContinue) { Update-AitherSessionPath }  # absent from a module built before this function existed
$adk = Get-Command adk -ErrorAction SilentlyContinue
if (-not $adk) { throw "adk not found. Run 32-onboarding/3260_Install-AWDK first." }

$status = (& $adk.Source status 2>&1 | Out-String)
$up = @($status -split "`r?`n" | Where-Object { $_ -match '\[\+\]' } | ForEach-Object { ($_ -replace '^\s*\[\+\]\s*', '') -replace '\s{2,}', ' ' })
if ($up.Count -gt 0 -and -not $Force) {
    Write-Host "Inference already reachable; not running quickstart:`n  $($up -join "`n  ")"
    return
}

$qsArgs = @('quickstart'); if ($Mode -eq 'cloud') { $qsArgs += '--cloud' }
if ($DryRun) { Write-Host "[DRY RUN] adk $($qsArgs -join ' ')"; return }

if ($env:CI -eq 'true' -or $env:AITHERZERO_NONINTERACTIVE -eq '1') {
    Write-Warning "Non-interactive session: skipping 'adk $($qsArgs -join ' ')'. Run it yourself."
    return
}

if ($PSCmdlet.ShouldProcess("adk", ($qsArgs -join ' '))) {
    & $adk.Source @qsArgs
    if ($LASTEXITCODE -ne 0) { throw "adk quickstart exited with code $LASTEXITCODE" }
}
