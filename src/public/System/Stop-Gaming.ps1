#Requires -Version 7.0

<#
.SYNOPSIS
    Enter gaming mode — release all GPU + system resources.

.DESCRIPTION
    Shorthand for: Switch-AitherGamingMode
    Stops all Docker containers, kills GPU processes, stops Docker Desktop + WSL2.
    Your images, volumes, and data are preserved — just run Start-Gaming to come back.

.PARAMETER SkipCompact
    Skip VHDX compaction (faster shutdown).

.PARAMETER ComposeFile
    Override the compose file (default: auto-detected).

.EXAMPLE
    Stop-Gaming
    # Free all GPU resources for gaming

.EXAMPLE
    Stop-Gaming -SkipCompact
    # Quick shutdown without disk compaction

.NOTES
    Part of the AitherZero System module.
    Resume with: Start-Gaming
    Copyright © 2025 Aitherium Corporation
#>
function Stop-Gaming {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]$SkipCompact,

        [Parameter()]
        [string]$ComposeFile
    )

    $splat = @{}
    if ($SkipCompact) { $splat.SkipCompact = $true }
    if ($ComposeFile) { $splat.ComposeFile = $ComposeFile }
    Switch-AitherGamingMode @splat
}
