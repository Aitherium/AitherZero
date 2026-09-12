#Requires -Version 7.0

<#
.SYNOPSIS
    Install awdk — the Aither ADK (`adk` CLI) — via pip.
.DESCRIPTION
    `python -m pip install --upgrade "awdk[<Extras>]"`, then refreshes PATH and
    verifies `adk` resolves. Idempotent: pip upgrades in place.

    The pip package is `awdk`; the CLI it installs is `adk` (NOT `aither`, which
    is a different REPL). Extras 'shell,platform,node' match what
    `adk setup-all` installs.
.PARAMETER Extras
    Comma-separated pip extras. Default 'shell,platform,node'. Empty string
    installs the bare SDK.
.PARAMETER Force
    Reinstall even if `adk` already resolves.
.PARAMETER DryRun
    Print the pip command without running it.
.EXAMPLE
    ./3215_Install-AWDK.ps1
.EXAMPLE
    ./3215_Install-AWDK.ps1 -Extras '' -DryRun
.NOTES
    Stage: Onboarding
    Dependencies: 1004_Install-Python
    Tags: awdk, adk, python, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Extras = 'shell,platform,node',
    [switch]$Force,
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '3215_Install-AWDK'
    } else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting awdk installation..."

try {
    # 1. Find a Python 3.10+ interpreter. `py` (Windows launcher) is tried
    #    first because a fresh python.org install may not have python.exe on
    #    PATH yet in this session.
    Update-AitherSessionPath
    # Exe and its leading args kept SEPARATE: `$python = if (...) { @($x) }`
    # would stream a one-element array through the pipeline and unroll it to a
    # plain string, so $python[0] became the letter 'C'.
    $pyExe  = $null
    $pyArgs = @()
    foreach ($candidate in @('python3', 'python', 'py')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $lead = @(); if ($candidate -eq 'py') { $lead = @('-3') }
        $v = (& $cmd.Source @lead --version 2>&1 | Out-String).Trim()
        if ($v -match 'Python (\d+)\.(\d+)' -and ([int]$Matches[1] -gt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10))) {
            $pyExe  = $cmd.Source
            $pyArgs = $lead
            Write-ScriptLog "Using $v at $pyExe"
            break
        }
    }
    if (-not $pyExe) {
        throw "Python 3.10+ not found. Run 10-devtools/1004_Install-Python first."
    }

    # 2. Already installed?
    if (-not $Force -and (Get-Command adk -ErrorAction SilentlyContinue)) {
        Write-ScriptLog "adk already installed at $((Get-Command adk).Source); upgrading in place."
    }

    # 3. Install / upgrade
    $spec = if ([string]::IsNullOrWhiteSpace($Extras)) { 'awdk' } else { "awdk[$Extras]" }
    $pipArgs = $pyArgs + @('-m', 'pip', 'install', '--upgrade', $spec)
    $display = "$pyExe $($pipArgs -join ' ')"

    if ($DryRun) {
        Write-ScriptLog "[DRY RUN] $display"
        return
    }

    if ($PSCmdlet.ShouldProcess("pip", "install $spec")) {
        Write-ScriptLog $display
        & $pyExe @pipArgs
        if ($LASTEXITCODE -ne 0) {
            throw "pip exited with code $LASTEXITCODE"
        }
    }

    # 4. Verify. pip drops console scripts in a Scripts/ (Windows) or
    #    ~/.local/bin (Unix --user) directory that may not be on PATH.
    Update-AitherSessionPath
    $adk = Get-Command adk -ErrorAction SilentlyContinue
    if (-not $adk) {
        $siteArgs = $pyArgs + @('-c', 'import site; print(site.USER_BASE)')
        $userBase = (& $pyExe @siteArgs 2>$null | Out-String).Trim()
        $hint = if ($IsWindows) { "$userBase\Python*\Scripts" } else { "$userBase/bin" }
        throw "awdk installed but 'adk' is not on PATH. pip's script dir is usually $hint — add it to PATH and open a new terminal."
    }

    $ver = (& $adk.Source --help 2>&1 | Select-Object -First 1 | Out-String).Trim()
    Write-ScriptLog "adk installed: $($adk.Source)" -Level Success
}
catch {
    Write-ScriptLog "awdk installation failed: $_" -Level Error
    # Re-throw: the playbook engine ignores `exit N` by design (see Invoke-AitherScript);
    # only a terminating error marks this step as failed.
    throw
}
