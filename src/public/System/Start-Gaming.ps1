#Requires -Version 7.0

<#
.SYNOPSIS
    Resume AitherOS after gaming — bring all services back online.

.DESCRIPTION
    Shorthand for: Switch-AitherGamingMode -Resume
    Starts Docker Desktop, recreates all containers, waits for health checks.
    Automatically restores the same stack that was running before gaming mode.
    Defaults to full stack if no saved state is found.

.PARAMETER ComposeFile
    Override the compose file (default: auto-detected).

.PARAMETER Stack
    Which stack to bring up: Auto (restore previous), Full, Demo, Core.
    Default: Auto

.EXAMPLE
    Start-Gaming
    # Bring AitherOS back online (full stack)

.EXAMPLE
    Start-Gaming -Stack Demo
    # Bring up just the demo stack

.NOTES
    Part of the AitherZero System module.
    Enter gaming mode with: Stop-Gaming
    Copyright © 2025 Aitherium Corporation
#>
function Start-Gaming {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$ComposeFile,

        [Parameter()]
        [ValidateSet('Auto', 'Full', 'Demo', 'Core')]
        [string]$Stack = 'Auto'
    )

    $splat = @{ Resume = $true }
    if ($ComposeFile) { $splat.ComposeFile = $ComposeFile }
    if ($Stack -ne 'Auto') { $splat.Stack = $Stack }
    Switch-AitherGamingMode @splat
}
