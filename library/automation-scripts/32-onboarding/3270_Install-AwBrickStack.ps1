#Requires -Version 7.0

<#
.SYNOPSIS
    Install or upgrade the core aw* Python brick stack.
.DESCRIPTION
    Installs the daily-driver aw* bricks that pair with awdk 4.0+ and awsh 2.0+:
    awrise, awgit, awm, awrelay, awdecide, awask, awrun, awfocus, awsettings,
    awmine, awbrain, awrtifact.

    Supports two sources:
      - PyPI (default): upgrades all selected bricks from pypi.org.
      - Local: installs from `<LocalPackagesDir>/<brick>` for source checkouts.

    Idempotent and cross-platform (handles PEP 668 `--user --break-system-packages`
    on Linux/macOS when system pip refuses installs). Re-asserts every brick by
    checking installed metadata and printing a version table.
.PARAMETER Source
    'PyPI' (default) or 'Local'.
.PARAMETER LocalPackagesDir
    Directory containing `<brick>/pyproject.toml` folders when Source='Local'.
.PARAMETER Bricks
    Optional comma-separated list of brick names to install instead of the
    default core 12.
.PARAMETER DryRun
    Print what would be installed without running pip.
.EXAMPLE
    ./3270_Install-AwBrickStack.ps1
.EXAMPLE
    ./3270_Install-AwBrickStack.ps1 -Source Local -LocalPackagesDir ./packages
.NOTES
    Stage: Onboarding
    Dependencies: 1004_Install-Python
    Tags: aw-stack, awrise, awgit, awm, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('PyPI', 'Local')]
    [string]$Source = 'PyPI',
    [string]$LocalPackagesDir = '',
    [string]$Bricks = '',
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    $mapped = if ($Level -eq 'Success') { 'Information' } else { $Level }
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $mapped -Source '3270_Install-AwBrickStack'
    } else {
        Write-Host "[$Level] $Message"
    }
}

$DefaultBricks = @(
    'awrise',
    'awgit',
    'awm',
    'awrelay',
    'awdecide',
    'awask',
    'awrun',
    'awfocus',
    'awsettings',
    'awmine',
    'awbrain',
    'awrtifact'
)

try {
    if (Get-Command Update-AitherSessionPath -ErrorAction SilentlyContinue) { Update-AitherSessionPath }

    # 1. Locate Python 3.10+
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

    # 2. Resolve brick list
    $brickList = if ([string]::IsNullOrWhiteSpace($Bricks)) {
        $DefaultBricks
    } else {
        @($Bricks -split '[,\s]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    }

    # 3. Build install targets
    $targets = @()
    if ($Source -eq 'Local') {
        if ([string]::IsNullOrWhiteSpace($LocalPackagesDir) -or -not (Test-Path $LocalPackagesDir)) {
            throw "LocalPackagesDir not found: '$LocalPackagesDir' (pass -LocalPackagesDir or use -Source PyPI)."
        }
        foreach ($b in $brickList) {
            $dir = Join-Path $LocalPackagesDir $b
            if (Test-Path (Join-Path $dir 'pyproject.toml')) {
                $targets += $dir
            } else {
                Write-ScriptLog "Local package missing for '$b' at $dir; falling back to PyPI." -Level Warning
                $targets += $b
            }
        }
    } else {
        $targets = $brickList
    }

    $pipArgs = $pyArgs + @('-m', 'pip', 'install', '--upgrade') + $targets
    $display = "$pyExe $($pipArgs -join ' ')"

    if ($DryRun) {
        Write-ScriptLog "[DRY RUN] Source=$Source Bricks=$($brickList -join ', ')"
        Write-ScriptLog "[DRY RUN] $display"
        return
    }

    if ($PSCmdlet.ShouldProcess('pip', "install $($brickList.Count) aw* bricks ($Source)")) {
        Write-ScriptLog "Installing $($brickList.Count) aw* bricks from $Source..."
        & $pyExe @pipArgs
        if ($LASTEXITCODE -ne 0 -and -not $IsWindows) {
            Write-ScriptLog "System pip install refused; retrying with --user --break-system-packages" -Level Warning
            $userArgs = $pyArgs + @('-m', 'pip', 'install', '--upgrade', '--user', '--break-system-packages') + $targets
            & $pyExe @userArgs
        }
        if ($LASTEXITCODE -ne 0) {
            throw "pip exited with code $LASTEXITCODE while installing aw* bricks"
        }
    }

    # 4. Re-assert every brick is installed and report versions
    $joined = ($brickList -join ',')
    $probe = @"
import importlib.metadata, sys
names = [n for n in '$joined'.split(',') if n]
missing = []
for n in names:
    try:
        v = importlib.metadata.version(n)
        print(f'  [OK] {n:<14} {v}')
    except importlib.metadata.PackageNotFoundError:
        print(f'  [MISSING] {n}')
        missing.append(n)
if missing:
    sys.exit(1)
"@
    Write-ScriptLog "Verifying installed aw* bricks:"
    & $pyExe @($pyArgs + @('-c', $probe))
    if ($LASTEXITCODE -ne 0) {
        throw "One or more aw* bricks failed post-install metadata verification."
    }
    Write-ScriptLog "All $($brickList.Count) aw* bricks installed and verified." -Level Success
}
catch {
    Write-ScriptLog "aw* brick stack installation failed: $_" -Level Error
    throw
}
