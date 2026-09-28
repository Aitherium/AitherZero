#Requires -Version 7.0

<#
.SYNOPSIS
    Run one of the owner's fleet verbs: status, gpu sleep|wake, fleet sleep|wake|critical, arc.

.DESCRIPTION
    Every verb runs AitherOS/dev/tools/fleet_verbs.py - the ONE implementation awdesk's
    Fleet window, awsh (/gpu, /fleet), adk (adk gpu|fleet), awnode's MCP tools and the
    automation script 0857_Invoke-FleetVerb.ps1 share - so a verb means the same thing on
    every surface (owner, 2026-09-27: "all the app surfaces ... need to be updated to work
    with awnix, like GPU sleep and fleet sleep").

      gpu sleep       gaming lock, model posture gaming (MicroScheduler lanes to the DGX
                      Spark), park every 5090 GPU unit
      gpu wake        GPU units back one at a time (gpu-boot), previous posture, lanes home,
                      lock released. REFUSED when awnix reports "GPU access blocked" (a
                      maintenance restart is the fix) or a game is running (-Force)
      fleet sleep     stop + runtime-mask the fleet, recorded (customer-facing set stays up)
      fleet wake      restore the record, health-gated; GPU units only if the GPU is awake
      fleet critical  only the critical profile + gpu sleep
      status          distro, systemd, containers, GPU access, posture, gaming lock, record

    Every verb refuses while a WSL maintenance restart holds ~/.aither/wsl-maintenance.lock.

.PARAMETER Verb
    The verb, spaced or dashed ('gpu sleep' / 'gpu-sleep'); old names alias
    (gaming, resume, down, up, critical).

.PARAMETER DryRun
    Print the steps, change nothing (also -WhatIf).

.PARAMETER Force
    gpu wake only: wake even while a game is running.

.PARAMETER Json
    Print the tool's JSON verdict.

.EXAMPLE
    Invoke-AitherFleetVerb 'gpu sleep'
    Invoke-AitherFleetVerb -Verb 'fleet wake' -DryRun
    Invoke-AitherFleetVerb status -Json

.NOTES
    Part of the AitherZero System module. Exit status in $LASTEXITCODE:
    0 ok / dry-run plan, 1 refused or failed, 2 could not judge.
#>
function Get-AitherFleetVerbArgs {
    <# PURE: verb + switches -> fleet_verbs.py arguments (after the script path). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Verb,
        [switch]$DryRun,
        [switch]$Force,
        [switch]$Json
    )
    $aliases = @{
        'gaming' = 'gpu-sleep'; 'game-on' = 'gpu-sleep'; 'gpu-quiet' = 'gpu-sleep'
        'resume' = 'gpu-wake'; 'game-off' = 'gpu-wake'
        'down' = 'fleet-sleep'; 'up' = 'fleet-wake'; 'critical' = 'fleet-critical'
    }
    $known = @('status', 'gpu-sleep', 'gpu-wake', 'fleet-sleep', 'fleet-wake', 'fleet-critical',
        'arc-start', 'arc-stop', 'arc-status')
    $v = ($Verb.Trim().ToLowerInvariant() -replace '[\s_]+', '-')
    if ($aliases.ContainsKey($v)) { $v = $aliases[$v] }
    if ($v -notin $known) {
        throw "unknown fleet verb '$Verb' (one of: $($known -join ', '))"
    }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($w in ($v -split '-', 2)) { $out.Add($w) }
    $readOnly = $v -in @('status', 'arc-status')
    if (-not $readOnly -and -not $DryRun) { $out.Add('--execute') }
    if ($Force -and $v -eq 'gpu-wake') { $out.Add('--force') }
    if ($Json) { $out.Add('--json') }
    return , $out.ToArray()
}

function Invoke-AitherFleetVerb {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Verb,
        [switch]$DryRun,
        [switch]$Force,
        [switch]$Json
    )
    $dry = $DryRun -or $WhatIfPreference
    $argv = Get-AitherFleetVerbArgs -Verb $Verb -DryRun:$dry -Force:$Force -Json:$Json
    $root = if ($env:AITHEROS_ROOT) { $env:AITHEROS_ROOT } else { Get-AitherProjectRoot }
    $tool = Join-Path $root 'AitherOS/dev/tools/fleet_verbs.py'
    if (-not (Test-Path -LiteralPath $tool)) {
        Write-AitherError -Message "fleet_verbs.py not found at $tool (set AITHEROS_ROOT)"
        $global:LASTEXITCODE = 2
        return
    }
    $py = if ($env:AITHER_PYTHON) { $env:AITHER_PYTHON } else { 'python' }
    # -WhatIf still runs the tool: WITHOUT --execute it is the dry run that prints the plan.
    & $py $tool @argv
}
