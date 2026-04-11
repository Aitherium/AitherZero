#Requires -Version 7.0

<#
.SYNOPSIS
    Install aither-adk and optional AitherDesktop.

.DESCRIPTION
    Installs the lightweight AitherADK package via pip. This is the agent
    framework + CLI — NOT a full Docker AitherOS stack.

    Optionally installs AitherDesktop (PyQt6 native overlay).

    Exit Codes:
        0 - Success
        1 - Python/pip not found
        2 - Installation failed

.PARAMETER InstallDesktop
    Also install aither-desktop (PyQt6 overlay). Default: false.

.PARAMETER DryRun
    Preview only.

.NOTES
    Stage: Onboarding
    Order: 3210
    Dependencies: none
    Tags: onboarding, adk, install, lightweight
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [bool]$InstallDesktop = $false,
    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Name, [string]$Status = 'running')
    $icon = switch ($Status) { 'done' { '[OK]' } 'fail' { '[FAIL]' } 'skip' { '[SKIP]' } default { '[..]' } }
    Write-Host "$icon $Name" -ForegroundColor $(switch ($Status) { 'done' { 'Green' } 'fail' { 'Red' } 'skip' { 'Yellow' } default { 'Cyan' } })
}

# ── Check Python ─────────────────────────────────────────────────────────

Write-Step "Check Python" 'running'

$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) {
    Write-Step "Check Python" 'fail'
    Write-Error "Python 3.10+ required. Install from https://python.org"
    exit 1
}

$pyVersion = & $python.Name --version 2>&1
Write-Step "Check Python ($pyVersion)" 'done'

# ── Install aither-adk ───────────────────────────────────────────────────

Write-Step "Install aither-adk" 'running'

if ($DryRun) { Write-Step "Install aither-adk (DRY RUN)" 'skip' }
else {
    $pipResult = & $python.Name -m pip install --upgrade aither-adk 2>&1
    $adkCheck = Get-Command aither -ErrorAction SilentlyContinue
    if ($adkCheck) {
        $adkVersion = & aither --version 2>&1 | Select-Object -First 1
        Write-Step "Install aither-adk ($adkVersion)" 'done'
    }
    else {
        Write-Step "Install aither-adk" 'fail'
        Write-Host "  pip output: $($pipResult | Select-Object -Last 3)"
        exit 2
    }
}

# ── Install AitherDesktop (optional) ─────────────────────────────────────

if ($InstallDesktop) {
    Write-Step "Install aither-desktop" 'running'
    if ($DryRun) { Write-Step "Install aither-desktop (DRY RUN)" 'skip' }
    else {
        & $python.Name -m pip install --upgrade aither-desktop 2>&1 | Out-Null
        $desktopCheck = Get-Command aither-desktop -ErrorAction SilentlyContinue
        if ($desktopCheck) {
            Write-Step "Install aither-desktop" 'done'
        }
        else {
            Write-Step "Install aither-desktop (optional — install manually later)" 'skip'
        }
    }
}

Write-Host ""
Write-Host "ADK installed. Run 'aither onboard' to configure your node." -ForegroundColor Green
exit 0
