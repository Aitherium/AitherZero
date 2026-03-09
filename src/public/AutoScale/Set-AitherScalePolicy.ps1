#Requires -Version 7.0

<#
.SYNOPSIS
    Update an existing autoscaling policy.
.DESCRIPTION
    Modifies an existing scaling policy on the AitherAutoScale agent. Supports
    enabling/disabling, updating thresholds, changing replica bounds, and toggling providers.
.PARAMETER PolicyId
    The ID of the policy to update.
.PARAMETER Enabled
    Enable or disable the policy.
.PARAMETER MinReplica
    New minimum replica count.
.PARAMETER MaxReplica
    New maximum replica count.
.PARAMETER CooldownSeconds
    New cooldown period between actions.
.PARAMETER Provider
    Change the scaling provider.
.PARAMETER PassThru
    Return the updated policy object.
.EXAMPLE
    Set-AitherScalePolicy -PolicyId "ms-cpu" -MaxReplica 8
.EXAMPLE
    Set-AitherScalePolicy -PolicyId "ms-cpu" -Enabled $false
.NOTES
    Part of AitherZero AutoScale module.
    Copyright © 2025 Aitherium Corporation.
#>
function Set-AitherScalePolicy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [string]$PolicyId,

        [Parameter()]
        [bool]$Enabled,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$MinReplica,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$MaxReplica,

        [Parameter()]
        [ValidateRange(30, 3600)]
        [int]$CooldownSeconds,

        [Parameter()]
        [ValidateSet('docker', 'hyperv', 'aws', 'azure', 'gcp')]
        [string]$Provider,

        [switch]$PassThru
    )

    begin {
        $AutoScaleUrl = $env:AITHER_AUTOSCALE_URL
        if (-not $AutoScaleUrl) { $AutoScaleUrl = "http://localhost:8797" }
    }

    process {
        if ($PSCmdlet.ShouldProcess("Policy '$PolicyId'", 'Update')) {
            try {
                # Get existing policy
                $existing = Invoke-RestMethod -Uri "$AutoScaleUrl/policies/$PolicyId" -TimeoutSec 5
                $policy = if ($existing.data) { $existing.data } else { $existing }

                # Apply updates
                if ($PSBoundParameters.ContainsKey('Enabled')) { $policy.enabled = $Enabled }
                if ($PSBoundParameters.ContainsKey('MinReplica')) { $policy.min_replicas = $MinReplica }
                if ($PSBoundParameters.ContainsKey('MaxReplica')) { $policy.max_replicas = $MaxReplica }
                if ($PSBoundParameters.ContainsKey('CooldownSeconds')) { $policy.cooldown_seconds = $CooldownSeconds }
                if ($PSBoundParameters.ContainsKey('Provider')) { $policy.provider = $Provider }

                # Save
                $json = $policy | ConvertTo-Json -Depth 5
                $response = Invoke-RestMethod -Uri "$AutoScaleUrl/policies" -Method Post `
                    -Body $json -ContentType 'application/json' -TimeoutSec 10

                Write-Host "✅ Policy '$PolicyId' updated" -ForegroundColor Green

                if ($PassThru) {
                    $result = if ($response.data) { $response.data } else { $response }
                    return [PSCustomObject]@{
                        PolicyId   = $result.id
                        Target     = $result.target
                        Provider   = $result.provider
                        MinReplica = $result.min_replicas
                        MaxReplica = $result.max_replicas
                        Enabled    = $result.enabled
                        Cooldown   = $result.cooldown_seconds
                    }
                }

            } catch {
                Write-Error "Failed to update policy '$PolicyId': $_"
            }
        }
    }
}
