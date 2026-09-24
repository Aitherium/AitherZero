#Requires -Version 7.0

<#
.SYNOPSIS
    Connect this machine to an Aitherium account via `adk login` (browser device flow).
.DESCRIPTION
    Runs `adk login`, which opens the portal device-flow page. Skipped when a
    token is already present (`adk whoami` succeeds) unless -Force. This is the
    ONLY interactive step in the dev-workstation playbook, which is why the
    playbook gates it behind -Variables @{ Login = $true }.

    Auth is optional for local-only use; it is required for cloud inference,
    awsh's cloud gateway, fleet sync and sovereign deploy.
.PARAMETER Force
    Log in again even if already authenticated.
.PARAMETER DryRun
    Print what would run.
.EXAMPLE
    ./3263_Connect-Aitherium.ps1
.NOTES
    Stage: Onboarding
    Dependencies: 3260_Install-AWDK
    Tags: auth, login, adk, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

if (Get-Command Update-AitherSessionPath -ErrorAction SilentlyContinue) { Update-AitherSessionPath }  # absent from a module built before this function existed
$adk = Get-Command adk -ErrorAction SilentlyContinue
if (-not $adk) {
    throw "adk not found. Run 32-onboarding/3260_Install-AWDK first."
}

if (-not $Force) {
    $who = (& $adk.Source whoami 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and $who -notmatch 'Not logged in') {
        Write-Host "Already authenticated:`n$who"
        return
    }
}

if ($DryRun) {
    Write-Host "[DRY RUN] adk login"
    return
}

if ($env:CI -eq 'true' -or $env:AITHERZERO_NONINTERACTIVE -eq '1') {
    Write-Warning "Non-interactive session: skipping 'adk login'. Run it yourself when a browser is available."
    return
}

if ($PSCmdlet.ShouldProcess("Aitherium", "adk login")) {
    & $adk.Source login
    if ($LASTEXITCODE -ne 0) {
        throw "adk login exited with code $LASTEXITCODE"
    }
}
