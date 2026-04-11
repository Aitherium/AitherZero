#Requires -Version 7.0

<#
.SYNOPSIS
    CLI entry point for AitherAutoScale operations.
.DESCRIPTION
    Automation script for auto-scaling infrastructure. Supports policy management,
    manual scaling, metric viewing, and continuous watch mode. Integrates with
    Atlas (ecosystem intelligence) and Demiurge (infrastructure execution).

    Supports on-prem Docker/Hyper-V and cloud providers (AWS, Azure, GCP).
.PARAMETER Action
    The operation to perform:
    - Status    : Show current autoscaling status
    - Scale     : Trigger a scale action
    - Watch     : Start continuous monitoring
    - Policy    : Create/update a scaling policy
    - Metrics   : Show current metrics
    - History   : Show scale action history
    - Providers : List configured providers
.PARAMETER Target
    Target service or group (required for Scale, Policy, Metrics).
.PARAMETER Direction
    Scale direction: Up or Down (for Scale action).
.PARAMETER Replicas
    Explicit replica count (for Scale action).
.PARAMETER Provider
    Provider override: docker, hyperv, aws, azure, gcp.
.PARAMETER Template
    Policy template: cpu-reactive, memory-reactive, latency-sensitive,
    gpu-workload, pain-responsive, cloud-burst.
.PARAMETER DryRun
    Preview actions without executing them.
.PARAMETER Interval
    Watch interval in seconds (default: 30).
.NOTES
    Stage     : 40 (Lifecycle)
    Order     : 4009
    Tags      : autoscale, infrastructure, lifecycle, atlas, demiurge
    AllowParallel : false
    Copyright © 2025 Aitherium Corporation
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Status', 'Scale', 'Watch', 'Policy', 'Metrics', 'History', 'Providers')]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Target,

    [Parameter()]
    [ValidateSet('Up', 'Down')]
    [string]$Direction,

    [Parameter()]
    [int]$Replicas,

    [Parameter()]
    [ValidateSet('docker', 'hyperv', 'aws', 'azure', 'gcp')]
    [string]$Provider,

    [Parameter()]
    [ValidateSet('cpu-reactive', 'memory-reactive', 'latency-sensitive',
                 'gpu-workload', 'pain-responsive', 'cloud-burst')]
    [string]$Template,

    [switch]$DryRun,

    [Parameter()]
    [int]$Interval = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Import AitherZero module ──────────────────────────────────────────────
$moduleRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent
$modulePath = Join-Path $moduleRoot "AitherZero" "AitherZero.psd1"
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -ErrorAction SilentlyContinue
}

# ── Execute action ────────────────────────────────────────────────────────
switch ($Action) {
    'Status' {
        Get-AitherScaleStatus -Target $Target
    }
    'Scale' {
        if (-not $Target) { throw "Target is required for Scale action" }
        if (-not $Direction) { throw "Direction (Up/Down) is required for Scale action" }

        $scaleParams = @{
            Target    = $Target
            Direction = $Direction
        }
        if ($Replicas) { $scaleParams['Replicas'] = $Replicas }
        if ($Provider) { $scaleParams['Provider'] = $Provider }
        if ($DryRun) { $scaleParams['DryRun'] = $true }

        Invoke-AitherScaleAction @scaleParams
    }
    'Watch' {
        $watchParams = @{ Interval = $Interval }
        Watch-AitherScale @watchParams
    }
    'Policy' {
        if (-not $Target) { throw "Target is required for Policy action" }

        $policyId = "$($Target.ToLower())-$(if ($Template) { $Template } else { 'custom' })"
        $policyParams = @{
            Id       = $policyId
            Target   = $Target
            PassThru = $true
        }
        if ($Template) { $policyParams['Template'] = $Template }
        if ($Provider) { $policyParams['Provider'] = $Provider }

        New-AitherScalePolicy @policyParams
    }
    'Metrics' {
        Get-AitherScaleMetric -Target $Target -Summary
    }
    'History' {
        Get-AitherScaleHistory -Target $Target
    }
    'Providers' {
        Get-AitherCloudProvider
    }
}
