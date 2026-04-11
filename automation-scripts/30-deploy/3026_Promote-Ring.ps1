#Requires -Version 7.0
<#
.SYNOPSIS
    Quick one-liner ring promotion for AitherOS.

.DESCRIPTION
    Dead-simple ring promotion wrapper. Just pick your target:

    .\3026_Promote-Ring.ps1 staging          # Promote dev → staging
    .\3026_Promote-Ring.ps1 prod             # Promote staging → prod
    .\3026_Promote-Ring.ps1 prod -FromDev    # Full pipeline: dev → staging → prod

    This is the "I just want to deploy" script. For full control,
    use 3025_Ring-Deploy.ps1 or Invoke-AitherRingPromotion.

.PARAMETER Target
    Where to promote to: staging or prod

.PARAMETER FromDev
    For prod target: start from dev (goes through staging first)

.PARAMETER SkipTests
    Skip running tests before promoting

.PARAMETER DryRun
    Show what would happen without executing

.PARAMETER Force
    Force promotion even if gates fail

.EXAMPLE
    .\3026_Promote-Ring.ps1 staging                 # Deploy to staging
    .\3026_Promote-Ring.ps1 prod                    # Promote staging → prod
    .\3026_Promote-Ring.ps1 prod -FromDev           # Full pipeline
    .\3026_Promote-Ring.ps1 staging -DryRun         # Preview
    .\3026_Promote-Ring.ps1 staging -SkipTests      # Fast promote

.NOTES
    Category: deploy
    Script: 3026
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet("staging", "prod")]
    [string]$Target,

    [switch]$FromDev,
    [switch]$SkipTests,
    [switch]$SkipBuild,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ═══════════════════════════════════════════════════════════════
# INIT
# ═══════════════════════════════════════════════════════════════

. "$PSScriptRoot/../_init.ps1"

# Load the ring deployment module
$ringModule = Join-Path $PSScriptRoot "../../../src/public/Deployment/Invoke-AitherRingDeployment.ps1"
if (Test-Path $ringModule) {
    . $ringModule
} else {
    Write-Error "Ring deployment module not found at: $ringModule"
    exit 1
}

# ═══════════════════════════════════════════════════════════════
# DETERMINE PROMOTION PATH
# ═══════════════════════════════════════════════════════════════

$from = switch ($Target) {
    "staging" { "dev" }
    "prod"    { if ($FromDev) { "dev" } else { "staging" } }
}

Write-Host ""
Write-Host "  ⚡ Quick Promote: $($from.ToUpper()) → $($Target.ToUpper())" -ForegroundColor Cyan
if ($from -eq "dev" -and $Target -eq "prod") {
    Write-Host "  ℹ  This will go: dev → staging → prod (2-step)" -ForegroundColor DarkCyan
}
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# EXECUTE
# ═══════════════════════════════════════════════════════════════

$params = @{
    From    = $from
    To      = $Target
    Approve = $true    # Quick promote = auto-approve
}

if ($SkipTests) { $params.SkipTests = $true }
if ($SkipBuild) { $params.SkipBuild = $true }
if ($DryRun) { $params.DryRun = $true }
if ($Force) { $params.Force = $true }

Invoke-AitherRingPromotion @params

exit $LASTEXITCODE
