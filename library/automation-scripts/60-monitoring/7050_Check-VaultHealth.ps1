#Requires -Version 7.0
<#
.SYNOPSIS
    Vault health & secret presence check — alerts on missing critical keys.

.DESCRIPTION
    Thin AitherZero wrapper around scripts/secrets-doctor.ps1. Designed to be
    invoked from a scheduled routine so that:
      1. A genuinely-down vault is detected (probes BOTH http:// and https://
         to avoid false negatives from scheme mismatch).
      2. Missing production secrets (Stripe, GitHub, etc.) raise a high-priority
         alert via Pulse instead of failing silently at request time.

.PARAMETER Keys
    Override the default critical-secret list.

.PARAMETER EmitPulse
    Push a critical-priority Pulse notification on failure (default: $true).

.NOTES
    Category: monitoring
    Routine: vault_health_check
    Created: 2026-05-20
    Reason : Stripe checkout silently returned 503 because STRIPE_SECRET_KEY
             was missing from the vault and there was no monitor that would
             have surfaced it. This script closes that gap.
#>

[CmdletBinding()]
param(
    [string[]]$Keys,
    [switch]$NoEmitPulse
)

$ErrorActionPreference = 'Continue'

$repoRoot   = (Resolve-Path "$PSScriptRoot/../../../..").Path
$doctorPath = Join-Path $repoRoot 'scripts/secrets-doctor.ps1'

if (-not (Test-Path $doctorPath)) {
    Write-Error "secrets-doctor.ps1 not found at $doctorPath"
    exit 2
}

$args = @('-Alert')
if ($Keys) { $args += @('-Keys', ($Keys -join ',')) }

& pwsh -NoProfile -File $doctorPath @args
$rc = $LASTEXITCODE

if ($rc -ne 0 -and -not $NoEmitPulse) {
    # Best-effort Pulse alert — non-fatal if Pulse is itself down
    $alert = @{
        priority      = 'critical'
        domain        = 'security'
        title         = "AitherSecrets vault health check FAILED"
        message       = "secrets-doctor exit code $rc — vault unreachable OR critical keys missing"
        source        = 'automation:7050_Check-VaultHealth'
        dedup_key     = 'vault_health_check'
        recommended   = 'pwsh ./scripts/secrets-doctor.ps1   (then ./scripts/vault-put.ps1 for missing keys)'
    } | ConvertTo-Json -Compress

    foreach ($scheme in @('https','http')) {
        try {
            Invoke-RestMethod -Uri "${scheme}://127.0.0.1:8088/api/v1/alerts" `
                -Method POST -Body $alert -ContentType 'application/json' `
                -TimeoutSec 3 -SkipCertificateCheck -ErrorAction Stop | Out-Null
            break
        } catch { continue }
    }
}

exit $rc
