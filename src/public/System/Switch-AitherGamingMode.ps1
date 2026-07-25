#Requires -Version 7.0

<#
.SYNOPSIS
    Toggle between AitherOS and gaming mode with a single command.

.DESCRIPTION
    Gaming mode releases ALL GPU + system resources so games get full performance:
      - Stops all Docker containers
      - Kills GPU processes holding VRAM
      - Stops Docker Desktop + WSL2
      - Optionally compacts WSL2 VHDX

    Resume brings everything back up: Docker Desktop, containers, health checks.

    This is the AitherShell wrapper around scripts/Switch-GamingMode.ps1.
    Just type: Start-Gaming / Stop-Gaming from any AitherShell prompt.

.PARAMETER Resume
    Bring everything back online (Docker Desktop → containers → health checks).

.PARAMETER SkipCompact
    Skip VHDX compaction when entering gaming mode (faster shutdown).

.PARAMETER ComposeFile
    Override the compose file used (default: auto-detected).

.EXAMPLE
    Switch-AitherGamingMode
    # Enter gaming mode — free all GPU resources

.EXAMPLE
    Switch-AitherGamingMode -Resume
    # Resume AitherOS — bring all services back up

.EXAMPLE
    Stop-Gaming
    # Alias: enter gaming mode

.EXAMPLE
    Start-Gaming
    # Alias: resume AitherOS from gaming mode

.NOTES
    Part of the AitherZero System module.
    Copyright © 2025 Aitherium Corporation
#>
function Switch-AitherGamingMode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]$Resume,

        [Parameter()]
        [switch]$SkipCompact,

        [Parameter()]
        [string]$ComposeFile,

        [Parameter()]
        [ValidateSet('Auto', 'Full', 'Demo', 'Core')]
        [string]$Stack = 'Auto'
    )

    begin {
        # Resolve the backing script
        $projectRoot = Get-AitherProjectRoot
        $scriptPath  = Join-Path $projectRoot 'scripts' 'Switch-GamingMode.ps1'

        if (-not (Test-Path $scriptPath)) {
            Write-AitherError -Message "Gaming mode script not found at: $scriptPath" -ErrorAction Stop
            return
        }
    }

    process {
        # Build argument list
        $argList = @('-NoProfile', '-File', $scriptPath)

        if ($Resume)      { $argList += '-Resume' }
        if ($SkipCompact) { $argList += '-SkipCompact' }
        if ($ComposeFile) { $argList += '-ComposeFile'; $argList += $ComposeFile }
        if ($Stack -ne 'Auto') { $argList += '-Stack'; $argList += $Stack }

        $action = if ($Resume) { 'Resume AitherOS services' } else { 'Enter gaming mode (release GPU + services)' }

        if ($PSCmdlet.ShouldProcess('AitherOS', $action)) {
            Write-Host ""
            if ($Resume) {
                Write-Host "  🚀 Resuming AitherOS..." -ForegroundColor Cyan
            } else {
                Write-Host "  🎮 Entering gaming mode..." -ForegroundColor Yellow
            }
            Write-Host ""

            # The script self-elevates, so we can just invoke it directly
            try {
                & pwsh @argList
                $exitCode = $LASTEXITCODE

                if ($exitCode -and $exitCode -ne 0) {
                    Write-AitherError -Message "Gaming mode script exited with code $exitCode"
                }
            }
            catch {
                Write-AitherError -Message "Failed to run gaming mode script: $_"
            }
        }
    }
}


