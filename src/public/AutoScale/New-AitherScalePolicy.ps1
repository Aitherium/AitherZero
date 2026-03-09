#Requires -Version 7.0

<#
.SYNOPSIS
    Create a new autoscaling policy from a template or custom definition.
.DESCRIPTION
    Creates a scaling policy and registers it with the AitherAutoScale agent.
    Supports predefined templates (cpu-reactive, memory-reactive, latency-sensitive,
    gpu-workload, pain-responsive, cloud-burst) or fully custom definitions.
.PARAMETER Id
    Unique policy identifier.
.PARAMETER Target
    Target service or group name (e.g., 'MicroScheduler', 'cognition').
.PARAMETER Template
    Use a predefined policy template. Overrideable with other parameters.
.PARAMETER Provider
    Scaling provider: docker (default), hyperv, aws, azure, gcp.
.PARAMETER MinReplica
    Minimum replica count (default: 1).
.PARAMETER MaxReplica
    Maximum replica count (default: 5).
.PARAMETER CpuScaleUp
    CPU percentage threshold to trigger scale up.
.PARAMETER CpuScaleDown
    CPU percentage threshold to trigger scale down.
.PARAMETER MemoryScaleUp
    Memory percentage threshold to trigger scale up.
.PARAMETER MemoryScaleDown
    Memory percentage threshold to trigger scale down.
.PARAMETER CooldownSeconds
    Cooldown between scaling actions (default: 300).
.PARAMETER Enabled
    Whether the policy is active immediately (default: true).
.PARAMETER PassThru
    Return the created policy object.
.EXAMPLE
    New-AitherScalePolicy -Id "ms-cpu" -Target "MicroScheduler" -Template "cpu-reactive"
.EXAMPLE
    New-AitherScalePolicy -Id "veil-custom" -Target "Veil" -Provider "docker" `
        -CpuScaleUp 75 -CpuScaleDown 20 -MaxReplica 3
.EXAMPLE
    New-AitherScalePolicy -Id "burst-aws" -Target "cognition" -Template "cloud-burst" `
        -Provider "aws" -MaxReplica 10
.NOTES
    Part of AitherZero AutoScale module.
    Copyright © 2025 Aitherium Corporation.
#>
function New-AitherScalePolicy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Id,

        [Parameter(Mandatory, Position = 1)]
        [string]$Target,

        [Parameter()]
        [ValidateSet('cpu-reactive', 'memory-reactive', 'latency-sensitive',
                     'gpu-workload', 'pain-responsive', 'cloud-burst')]
        [string]$Template,

        [Parameter()]
        [ValidateSet('docker', 'hyperv', 'aws', 'azure', 'gcp')]
        [string]$Provider = 'docker',

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$MinReplica = 1,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$MaxReplica = 5,

        [Parameter()]
        [ValidateRange(1, 100)]
        [double]$CpuScaleUp,

        [Parameter()]
        [ValidateRange(0, 100)]
        [double]$CpuScaleDown,

        [Parameter()]
        [ValidateRange(1, 100)]
        [double]$MemoryScaleUp,

        [Parameter()]
        [ValidateRange(0, 100)]
        [double]$MemoryScaleDown,

        [Parameter()]
        [ValidateRange(30, 3600)]
        [int]$CooldownSeconds = 300,

        [Parameter()]
        [bool]$Enabled = $true,

        [switch]$PassThru
    )

    begin {
        $AutoScaleUrl = $env:AITHER_AUTOSCALE_URL
        if (-not $AutoScaleUrl) { $AutoScaleUrl = "http://localhost:8797" }
    }

    process {
        # Build thresholds
        $thresholds = @()

        if ($CpuScaleUp -or $CpuScaleDown) {
            $thresholds += @{
                metric           = 'cpu_percent'
                scale_up         = if ($CpuScaleUp) { $CpuScaleUp } else { 80.0 }
                scale_down       = if ($CpuScaleDown) { $CpuScaleDown } else { 20.0 }
                duration_seconds = 60
            }
        }

        if ($MemoryScaleUp -or $MemoryScaleDown) {
            $thresholds += @{
                metric           = 'memory_percent'
                scale_up         = if ($MemoryScaleUp) { $MemoryScaleUp } else { 85.0 }
                scale_down       = if ($MemoryScaleDown) { $MemoryScaleDown } else { 30.0 }
                duration_seconds = 120
            }
        }

        # Build policy body
        $body = @{
            id               = $Id
            name             = "AutoScale: $Target ($Id)"
            target           = $Target
            target_type      = 'service'
            provider         = $Provider
            min_replicas     = $MinReplica
            max_replicas     = $MaxReplica
            cooldown_seconds = $CooldownSeconds
            enabled          = $Enabled
            priority         = 5
            labels           = @{}
            cloud_config     = @{}
        }

        # Apply template defaults if specified
        if ($Template) {
            $body['labels'] = @{ template = $Template }

            if ($thresholds.Count -eq 0) {
                # Use template defaults — the agent will apply them
                $body['labels']['use_template'] = $Template
            }
        }

        if ($thresholds.Count -gt 0) {
            $body['thresholds'] = $thresholds
        }

        if ($PSCmdlet.ShouldProcess("AutoScale policy '$Id' for target '$Target'", 'Create')) {
            try {
                $json = $body | ConvertTo-Json -Depth 5
                $response = Invoke-RestMethod -Uri "$AutoScaleUrl/policies" -Method Post `
                    -Body $json -ContentType 'application/json' -TimeoutSec 10

                $result = if ($response.data) { $response.data } else { $response }

                Write-Host "✅ Policy '$Id' created for $Target (provider: $Provider)" -ForegroundColor Green

                if ($PassThru) {
                    return [PSCustomObject]@{
                        PolicyId     = $result.id
                        Name         = $result.name
                        Target       = $result.target
                        Provider     = $result.provider
                        MinReplica   = $result.min_replicas
                        MaxReplica   = $result.max_replicas
                        Enabled      = $result.enabled
                        Thresholds   = $result.thresholds
                        Cooldown     = $result.cooldown_seconds
                    }
                }

            } catch {
                Write-Error "Failed to create policy: $_"
            }
        }
    }
}
