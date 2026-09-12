#Requires -Version 7.0

<#
.SYNOPSIS
    Install awsh — the terminal that answers you — via npm.
.DESCRIPTION
    `npm install -g @aitherium/awsh`, then refreshes PATH and verifies `awsh`
    resolves. Idempotent: npm upgrades in place.

    PACKAGE NAME TRAP (2026-09-12): the awsh README body says
    `npm i -g @aitherium/shell-cli`. That package is stale (1.16.x) and
    installs bins named `aither` / `aither-shell` — NO `awsh`. The real
    package is `@aitherium/awsh`, which ships `awsh`, `aither` and
    `aither-shell`. This script installs the real one and removes the stale
    one if present so the two never shadow each other.
.PARAMETER Force
    Reinstall even if `awsh` already resolves.
.PARAMETER DryRun
    Print the npm command without running it.
.EXAMPLE
    ./3216_Install-AWSH.ps1
.NOTES
    Stage: Onboarding
    Dependencies: 1003_Install-Node
    Tags: awsh, npm, node, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '3216_Install-AWSH'
    } else {
        Write-Host "[$Level] $Message"
    }
}

$Package      = '@aitherium/awsh'
$StalePackage = '@aitherium/shell-cli'

Write-ScriptLog "Starting awsh installation..."

try {
    # 1. npm present? (Node 20+ required by awsh.)
    Update-AitherSessionPath
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) {
        throw "npm not found. Run 10-devtools/1003_Install-Node first."
    }
    $nodeVer = (node --version 2>&1 | Out-String).Trim()
    if ($nodeVer -match '^v(\d+)' -and [int]$Matches[1] -lt 20) {
        throw "awsh needs Node 20+, found $nodeVer."
    }

    if ($DryRun) {
        Write-ScriptLog "[DRY RUN] npm install -g $Package"
        return
    }

    # 2. Remove the stale package if it is installed globally — its `aither`
    #    bin would otherwise shadow the one from @aitherium/awsh.
    $globalList = (& $npm.Source ls -g --depth=0 --json 2>$null | Out-String)
    if ($globalList -match [regex]::Escape($StalePackage)) {
        if ($PSCmdlet.ShouldProcess("npm", "uninstall -g $StalePackage")) {
            Write-ScriptLog "Removing stale package $StalePackage (superseded by $Package)"
            & $npm.Source uninstall -g $StalePackage 2>&1 | Out-Null
        }
    }

    # 3. Install / upgrade
    if (-not $Force -and (Get-Command awsh -ErrorAction SilentlyContinue)) {
        Write-ScriptLog "awsh already installed; upgrading in place."
    }
    if ($PSCmdlet.ShouldProcess("npm", "install -g $Package")) {
        Write-ScriptLog "npm install -g $Package"
        & $npm.Source install -g $Package
        if ($LASTEXITCODE -ne 0) {
            throw "npm exited with code $LASTEXITCODE"
        }
    }

    # 4. Verify. npm's global bin dir (%APPDATA%\npm on Windows) is added to
    #    PATH by the Node installer but this session may predate it.
    Update-AitherSessionPath
    $awsh = Get-Command awsh -ErrorAction SilentlyContinue
    if (-not $awsh) {
        $prefix = (& $npm.Source prefix -g 2>$null | Out-String).Trim()
        $binDir = if ($IsWindows) { $prefix } else { Join-Path $prefix 'bin' }
        if (Test-Path $binDir) {
            $env:PATH = "$binDir$([IO.Path]::PathSeparator)$env:PATH"
            $awsh = Get-Command awsh -ErrorAction SilentlyContinue
        }
        if (-not $awsh) {
            throw "$Package installed but 'awsh' is not on PATH. npm's global bin dir is $binDir — add it to PATH and open a new terminal."
        }
    }

    $ver = (& $awsh.Source --version 2>&1 | Out-String).Trim()
    Write-ScriptLog "awsh installed: $ver ($($awsh.Source))" -Level Success
}
catch {
    Write-ScriptLog "awsh installation failed: $_" -Level Error
    # Re-throw: the playbook engine ignores `exit N` by design (see Invoke-AitherScript);
    # only a terminating error marks this step as failed.
    throw
}
