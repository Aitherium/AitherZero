#Requires -Version 7.0

<#
.SYNOPSIS
    Onboard a machine as an AitherOS fleet node: join it to the fleet placement
    controller (aither-registry) by node id and certificate pin.

.DESCRIPTION
    This used to fetch an installer from a retired public gateway, run it with a
    portal token and look for a cluster-agent unit the fleet no longer runs. That
    path is gone. Fleet membership has ONE implementation
    (lib/mesh/fleet_membership.py, driven by awrun's node-op verbs); this script
    delegates to 3268_Invoke-FleetMembership -Action join, which:

        1. queues `awrun submit --kind node-op --action fleet-join --node <id>
           --pin-sha256 <pin>` (the token is minted controller-side, bound to the
           node id, ttl 600; no token is passed in or printed),
        2. drains it with AitherOS/dev/tools/awrun_node_op_worker.py --once,
        3. reads the run back: verdict, node status, approved.

    Exit codes (from 3268): 0 joined (or dry-run plan printed), 1 the controller
    or the node refused, 2 refused parameters, 3 a tool failed.

.PARAMETER NodeId
    The controller node id, which is also the nodes.yaml name the node transport
    reaches. Empty = this machine's host name, lower-cased into the id alphabet.

.PARAMETER Controller
    The https URL the joining node dials. Empty = the library default
    (https://127.0.0.1:8149, right for the awnix host itself).

.PARAMETER PinSha256
    SHA-256 of the controller's certificate. Empty = 3268's default
    ($env:AITHER_PLACEMENT_CONTROLLER_SHA256, else the measured pin).

.PARAMETER Force
    Re-join a node the controller already approved.

.PARAMETER NodeDryRun
    Queue + drain with --node-dry-run: plan only, nothing changes on the node.

.PARAMETER DryRun
    Print the commands; queue nothing.

.EXAMPLE
    ./3214_Onboard-ClusterNode.ps1 -NodeId awnix -DryRun

.EXAMPLE
    ./3214_Onboard-ClusterNode.ps1 -NodeId optiplex-wsl -Controller https://10.0.0.5:8149

.NOTES
    Stage: Onboarding
    Order: 3214
    Dependencies: 3268_Invoke-FleetMembership, awrun, python + the monorepo
    Tags: onboarding, cluster, node, fleet, placement, join
    AllowParallel: false
#>

[CmdletBinding()]
param(
    [string]$NodeId = '',
    [string]$Controller = '',
    [string]$PinSha256 = '',
    [switch]$Force,
    [switch]$NodeDryRun,
    [switch]$DryRun,
    [switch]$PassThru,
    # Test seam, handed to 3268: { param([string[]]$Argv) ... return @{ rc; out } }.
    [scriptblock]$Invoker
)

$ErrorActionPreference = 'Stop'

if (-not $NodeId) {
    $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
    $NodeId = (($hostName.ToLowerInvariant()) -replace '[^a-z0-9._-]', '-').Trim('-', '.', '_')
    if ($NodeId.Length -gt 63) { $NodeId = $NodeId.Substring(0, 63) }
}

$membership = Join-Path $PSScriptRoot '3268_Invoke-FleetMembership.ps1'
if (-not (Test-Path -LiteralPath $membership)) {
    Write-Host "[FAIL] 3268_Invoke-FleetMembership.ps1 is not beside this script; fleet join needs the full AitherZero library and the AitherOS monorepo" -ForegroundColor Red
    if ($PassThru) { return [pscustomobject]@{ Success = $false; ExitCode = 3; Action = 'fleet-join'; Node = $NodeId } }
    exit 3
}
$call = @{ Action = 'join'; Node = $NodeId; PassThru = $true }
if ($Controller) { $call.Controller = $Controller }
if ($PinSha256) { $call.PinSha256 = $PinSha256 }
if ($Force) { $call.Force = $true }
if ($NodeDryRun) { $call.NodeDryRun = $true }
if ($DryRun) { $call.DryRun = $true }
if ($Invoker) { $call.Invoker = $Invoker }

Write-Host "AitherOS fleet node onboarding: $NodeId -> placement controller" -ForegroundColor Cyan
$r = & $membership @call

if ($PassThru) { return $r }
exit ([int]$r.ExitCode)
