#Requires -Version 7.0

<#
.SYNOPSIS
    Wire 2-way Google Antigravity integration, probe awsh 2.0 avatars, and optionally start the harness daemon.
.DESCRIPTION
    Runs `adk antigravity setup` and `adk antigravity doctor` to configure the
    2-way Google Antigravity <-> awdk/awsh/AitherOS plugin, MCP server, rules,
    and skill pack; runs `awsh avatar --probe` to verify terminal graphics
    protocol support (Kitty/iTerm2/Sixel/half-block); and optionally runs
    `adk harness up` to start the local harness daemon.
.PARAMETER StartHarnessDaemon
    Start the local harness daemon via `adk harness up`.
.PARAMETER DryRun
    Print the commands without running them.
.EXAMPLE
    ./3271_Setup-AntigravityAndAwsh.ps1
.EXAMPLE
    ./3271_Setup-AntigravityAndAwsh.ps1 -StartHarnessDaemon
.NOTES
    Stage: Onboarding
    Dependencies: 3260_Install-AWDK, 3261_Install-AWSH
    Tags: antigravity, awdk, awsh, avatars, harness
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$StartHarnessDaemon,
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    $mapped = if ($Level -eq 'Success') { 'Information' } else { $Level }
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $mapped -Source '3271_Setup-AntigravityAndAwsh'
    } else {
        Write-Host "[$Level] $Message"
    }
}

try {
    if (Get-Command Update-AitherSessionPath -ErrorAction SilentlyContinue) { Update-AitherSessionPath }

    $adk  = Get-Command adk  -ErrorAction SilentlyContinue
    $awsh = Get-Command awsh -ErrorAction SilentlyContinue
    if (-not $adk)  { throw "adk not found on PATH. Run 32-onboarding/3260_Install-AWDK first." }
    if (-not $awsh) { throw "awsh not found on PATH. Run 32-onboarding/3261_Install-AWSH first." }

    if ($DryRun) {
        Write-ScriptLog "[DRY RUN] adk antigravity setup"
        Write-ScriptLog "[DRY RUN] adk antigravity doctor"
        Write-ScriptLog "[DRY RUN] awsh avatar list"
        if ($StartHarnessDaemon) { Write-ScriptLog "[DRY RUN] adk harness up" }
        return
    }

    if ($PSCmdlet.ShouldProcess('adk', 'antigravity setup')) {
        Write-ScriptLog "Configuring 2-way Google Antigravity integration..."
        & $adk.Source antigravity setup
        if ($LASTEXITCODE -ne 0) {
            Write-ScriptLog "adk antigravity setup exited $LASTEXITCODE (non-fatal if Antigravity is not installed on this host)" -Level Warning
        }
    }

    Write-ScriptLog "Checking Antigravity integration health..."
    & $adk.Source antigravity doctor
    if ($LASTEXITCODE -ne 0) {
        Write-ScriptLog "adk antigravity doctor reported warnings (exit $LASTEXITCODE)" -Level Warning
    }

    Write-ScriptLog "Checking awsh 2.0 terminal avatars..."
    $awshVer = (& $awsh.Source --version 2>&1 | Out-String).Trim()
    if ($awshVer -match '(\d+)\.(\d+)' -and [int]$Matches[1] -ge 2) {
        & $awsh.Source avatar list
        if ($LASTEXITCODE -ne 0) {
            Write-ScriptLog "awsh avatar list exited $LASTEXITCODE" -Level Warning
        }
    } else {
        Write-ScriptLog "Skipping awsh avatar list (installed awsh is '$awshVer'; upgrade to @aitherium/awsh >= 2.0.0)" -Level Warning
    }

    if ($StartHarnessDaemon) {
        if ($PSCmdlet.ShouldProcess('adk', 'harness up')) {
            Write-ScriptLog "Starting local harness daemon (adk harness up)..."
            & $adk.Source harness up
            if ($LASTEXITCODE -ne 0) {
                throw "adk harness up failed with exit code $LASTEXITCODE"
            }
        }
    }

    Write-ScriptLog "Antigravity & awsh wiring complete." -Level Success
}
catch {
    Write-ScriptLog "Antigravity & awsh setup failed: $_" -Level Error
    throw
}
