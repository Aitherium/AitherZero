#Requires -Version 7.0

<#
.SYNOPSIS
    Toggle between AitherOS and gaming mode with a single command.

.DESCRIPTION
    Since 2026-09-27 the fleet runs as podman quadlets in the awnix WSL distro, so gaming
    mode is the owner's GPU verb set (AitherOS/dev/tools/fleet_verbs.py, the same as
    awdesk, awsh /gpu, adk gpu and awnode):

      Switch-AitherGamingMode           = gpu sleep: gaming lock, model posture gaming
                                          (MicroScheduler lanes to the DGX Spark), park every
                                          5090 GPU unit. The rest of the fleet stays up.
      Switch-AitherGamingMode -Resume   = gpu wake: GPU units back one at a time, previous
                                          posture, lanes home, lock released. Refused while
                                          awnix reports "GPU access blocked" (needs a
                                          maintenance restart) or a game is running.

    -Legacy runs the pre-awnix scripts/Switch-GamingMode.ps1 (Docker Desktop: stop compose,
    stop the Docker service, terminate docker-desktop). On awnix it frees no fleet VRAM.

.PARAMETER Resume
    gpu wake instead of gpu sleep.

.PARAMETER Legacy
    Use the Docker Desktop script (Stack/ComposeFile/SkipCompact apply only here).

.PARAMETER Force
    gpu wake only: wake even while a game is running.

.EXAMPLE
    Stop-Gaming      # gpu sleep
    Start-Gaming     # gpu wake

.NOTES
    Part of the AitherZero System module.
    Copyright (c) 2025 Aitherium Corporation
#>
function Switch-AitherGamingMode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]$Resume,

        [Parameter()]
        [switch]$Legacy,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$SkipCompact,

        [Parameter()]
        [string]$ComposeFile,

        [Parameter()]
        [ValidateSet('Auto', 'Full', 'Demo', 'Core')]
        [string]$Stack = 'Auto'
    )

    process {
        if (-not $Legacy) {
            $verb = if ($Resume) { 'gpu wake' } else { 'gpu sleep' }
            if ($PSCmdlet.ShouldProcess('AitherOS fleet (awnix)', $verb)) {
                Invoke-AitherFleetVerb -Verb $verb -Force:$Force
            } else {
                Invoke-AitherFleetVerb -Verb $verb -DryRun
            }
            return
        }

        $projectRoot = Get-AitherProjectRoot
        $scriptPath = Join-Path $projectRoot 'scripts' 'Switch-GamingMode.ps1'
        if (-not (Test-Path $scriptPath)) {
            Write-AitherError -Message "Gaming mode script not found at: $scriptPath" -ErrorAction Stop
            return
        }
        $argList = @('-NoProfile', '-File', $scriptPath)
        if ($Resume)      { $argList += '-Resume' }
        if ($SkipCompact) { $argList += '-SkipCompact' }
        if ($ComposeFile) { $argList += '-ComposeFile'; $argList += $ComposeFile }
        if ($Stack -ne 'Auto') { $argList += '-Stack'; $argList += $Stack }
        $action = if ($Resume) { 'Resume AitherOS services (Docker Desktop)' } else { 'Enter gaming mode (Docker Desktop)' }
        if ($PSCmdlet.ShouldProcess('AitherOS', $action)) {
            try {
                & pwsh @argList
                if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                    Write-AitherError -Message "Gaming mode script exited with code $LASTEXITCODE"
                }
            }
            catch {
                Write-AitherError -Message "Failed to run gaming mode script: $_"
            }
        }
    }
}
