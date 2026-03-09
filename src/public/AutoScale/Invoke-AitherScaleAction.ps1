#Requires -Version 7.0

<#
.SYNOPSIS
    Trigger a scale up or scale down action for a service.
.DESCRIPTION
    Invokes a scaling action on the AitherAutoScale agent. Can scale Docker containers,
    Hyper-V VMs, or cloud instances. Supports dry-run mode for safe previewing.
    Consults Atlas for blast-radius analysis before execution.
.PARAMETER Target
    The service or group to scale (e.g., 'MicroScheduler', 'CognitionCore').
.PARAMETER Direction
    Scale direction: 'Up' or 'Down'.
.PARAMETER Replicas
    Explicit replica count. If omitted, increments/decrements by 1.
.PARAMETER Provider
    Override the default provider for this action.
.PARAMETER Reason
    Human-readable reason for the scale action.
.PARAMETER DryRun
    Preview the action without executing it.
.PARAMETER Force
    Skip cooldown checks.
.EXAMPLE
    Invoke-AitherScaleAction -Target "MicroScheduler" -Direction Up
.EXAMPLE
    Invoke-AitherScaleAction -Target "CognitionCore" -Direction Up -Replicas 3 -Provider aws
.EXAMPLE
    Invoke-AitherScaleAction -Target "Veil" -Direction Down -DryRun
.NOTES
    Part of AitherZero AutoScale module.
    Copyright © 2025 Aitherium Corporation.
#>
function Invoke-AitherScaleAction {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Target,

        [Parameter(Mandatory, Position = 1)]
        [ValidateSet('Up', 'Down')]
        [string]$Direction,

        [Parameter()]
        [ValidateRange(0, 50)]
        [int]$Replicas,

        [Parameter()]
        [ValidateSet('docker', 'hyperv', 'aws', 'azure', 'gcp')]
        [string]$Provider,

        [Parameter()]
        [string]$Reason = 'manual',

        [switch]$DryRun,
        [switch]$Force
    )

    begin {
        $AutoScaleUrl = $env:AITHER_AUTOSCALE_URL
        if (-not $AutoScaleUrl) { $AutoScaleUrl = "http://localhost:8797" }
    }

    process {
        $dirLower = $Direction.ToLower()
        $displayAction = if ($dirLower -eq 'up') { '⬆️ Scale UP' } else { '⬇️ Scale DOWN' }

        if ($PSCmdlet.ShouldProcess("$Target via $($Provider ?? 'auto')", $displayAction)) {
            $body = @{
                target    = $Target
                direction = $dirLower
                reason    = $Reason
                dry_run   = [bool]$DryRun
            }

            if ($PSBoundParameters.ContainsKey('Replicas')) {
                $body['replicas'] = $Replicas
            }
            if ($PSBoundParameters.ContainsKey('Provider')) {
                $body['provider'] = $Provider
            }

            try {
                $json = $body | ConvertTo-Json -Depth 3
                $response = Invoke-RestMethod -Uri "$AutoScaleUrl/scale" -Method Post `
                    -Body $json -ContentType 'application/json' -TimeoutSec 30

                $data = if ($response.data) { $response.data } else { $response }

                if ($DryRun) {
                    Write-Host "`n🔍 DRY RUN — Scale $dirLower preview for $Target" -ForegroundColor Yellow
                    Write-Host "   Provider: $($data.provider)"
                    Write-Host "   Replicas: $($data.replicas ?? 'auto')"

                    $blastRadius = $data.blast_radius
                    if ($blastRadius -and $blastRadius.affected_services) {
                        Write-Host "   ⚠️  Blast Radius: $($blastRadius.affected_services -join ', ')" -ForegroundColor Red
                    }

                    return [PSCustomObject]@{
                        DryRun       = $true
                        Target       = $Target
                        Direction    = $dirLower
                        Provider     = $data.provider
                        BlastRadius  = $blastRadius
                    }
                }

                $icon = if ($data.result.status -eq 'ok') { '✅' } else { '❌' }
                Write-Host "$icon $displayAction $Target → $($data.replicas ?? 'auto') replicas ($($data.provider))" -ForegroundColor $(
                    if ($data.result.status -eq 'ok') { 'Green' } else { 'Red' }
                )

                return [PSCustomObject]@{
                    Target    = $data.target
                    Direction = $data.direction
                    Replicas  = $data.replicas
                    Provider  = $data.provider
                    Status    = $data.result.status
                    Reason    = $data.reason
                    Timestamp = $data.timestamp
                }

            } catch {
                # Fallback: direct Docker Compose scale
                if (-not $Provider -or $Provider -eq 'docker') {
                    Write-Warning "AutoScale agent unavailable. Falling back to direct Docker scale."

                    $serviceName = "aither-$($Target.ToLower().Replace('aither',''))"
                    $targetReplicas = if ($Replicas) { $Replicas } else { if ($dirLower -eq 'up') { 2 } else { 1 } }

                    if (-not $DryRun) {
                        Invoke-AitherCompose -Command "up" -Args @(
                            '-d', '--scale', "$serviceName=$targetReplicas", '--no-recreate'
                        )
                    }

                    return [PSCustomObject]@{
                        Target       = $Target
                        Direction    = $dirLower
                        Replicas     = $targetReplicas
                        Provider     = 'docker'
                        Status       = 'fallback'
                        FallbackMode = $true
                    }
                } else {
                    Write-Error "Scale action failed: $_"
                }
            }
        }
    }
}
