#Requires -Version 7.0

<#
.SYNOPSIS
    Verify awrise host clock (including split-AWRISE_HOME guard) and optionally schedule an eval wake.
.DESCRIPTION
    1. Optionally sets AWRELAY_NICK for relay summaries.
    2. Optionally installs this machine's awrise host clock (`awrise install-clock`).
    3. Optionally registers or updates a 30-minute detached `continuous-surface-eval`
       wake when `-EvalScript` is provided.
    4. Runs `awrise doctor` so split-AWRISE_HOME or dead-clock issues surface
       immediately rather than silently hiding behind stale dashboards.
.PARAMETER InstallClock
    Run `awrise install-clock` to register the host's native scheduler.
.PARAMETER EvalScript
    Optional path to a surface-eval Python script to schedule every 30m in awrise.
.PARAMETER RelayNick
    Optional nick to persist into `AWRELAY_NICK` (User env on Windows).
.PARAMETER DryRun
    Print planned actions without changing clock, jobs, or env vars.
.EXAMPLE
    ./3272_Setup-AwriseAndEval.ps1 -InstallClock
.NOTES
    Stage: Onboarding
    Dependencies: 3270_Install-AwBrickStack
    Tags: awrise, scheduler, eval
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$InstallClock,
    [string]$EvalScript = '',
    [string]$RelayNick = '',
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    $mapped = if ($Level -eq 'Success') { 'Information' } else { $Level }
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $mapped -Source '3272_Setup-AwriseAndEval'
    } else {
        Write-Host "[$Level] $Message"
    }
}

try {
    if (Get-Command Update-AitherSessionPath -ErrorAction SilentlyContinue) { Update-AitherSessionPath }

    $awrise = Get-Command awrise -ErrorAction SilentlyContinue
    if (-not $awrise) {
        throw "awrise not found on PATH. Run 32-onboarding/3270_Install-AwBrickStack first."
    }

    if (-not [string]::IsNullOrWhiteSpace($RelayNick)) {
        if ($DryRun) {
            Write-ScriptLog "[DRY RUN] would set AWRELAY_NICK=$RelayNick"
        } else {
            $env:AWRELAY_NICK = $RelayNick
            if ($IsWindows) {
                [Environment]::SetEnvironmentVariable('AWRELAY_NICK', $RelayNick, 'User')
            }
            Write-ScriptLog "Configured AWRELAY_NICK=$RelayNick"
        }
    }

    if ($InstallClock) {
        if ($DryRun) {
            Write-ScriptLog "[DRY RUN] awrise install-clock"
        } elseif ($PSCmdlet.ShouldProcess('awrise', 'install-clock')) {
            Write-ScriptLog "Installing host clock via awrise install-clock..."
            & $awrise.Source install-clock
            if ($LASTEXITCODE -ne 0) {
                Write-ScriptLog "awrise install-clock exited $LASTEXITCODE" -Level Warning
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($EvalScript)) {
        if (-not (Test-Path $EvalScript)) {
            Write-ScriptLog "Eval script not found at '$EvalScript' — skipping registration." -Level Warning
        } else {
            $pyName = if ($IsWindows) { 'python' } else { 'python3' }
            $homeDir = if ($IsWindows) { $env:USERPROFILE } else { $env:HOME }
            $receiptPath = Join-Path $homeDir '.aither' 'eval' 'continuous-surface-eval.receipt.json'
            $evalCmd = "$pyName `"$EvalScript`" --mode sweep --batch-tools 40 --batch-skills 25 --batch-docs 8 --llm-audit 3 --relay-channel '#evals'"

            if ($DryRun) {
                Write-ScriptLog "[DRY RUN] register/update awrise job 'continuous-surface-eval' every 30m (detached, receipt=$receiptPath)"
            } elseif ($PSCmdlet.ShouldProcess('awrise', 'register continuous-surface-eval')) {
                $existing = (& $awrise.Source list --json 2>$null | Out-String)
                if ($existing -match '"continuous-surface-eval"') {
                    Write-ScriptLog "Updating existing awrise job 'continuous-surface-eval'..."
                    & $awrise.Source set --name continuous-surface-eval "run=$evalCmd" detach=true "receipt=$receiptPath"
                } else {
                    Write-ScriptLog "Adding awrise job 'continuous-surface-eval' (every 30m, detached)..."
                    & $awrise.Source add --name continuous-surface-eval --every 30m --run $evalCmd --detach --receipt $receiptPath --report-relay '#decisions' --card-after 2
                }
                if ($LASTEXITCODE -ne 0) {
                    Write-ScriptLog "awrise registration for continuous-surface-eval exited $LASTEXITCODE" -Level Warning
                }
            }
        }
    }

    if ($DryRun) {
        Write-ScriptLog "[DRY RUN] awrise doctor"
        return
    }

    Write-ScriptLog "Running awrise doctor..."
    & $awrise.Source doctor
    if ($LASTEXITCODE -ne 0) {
        Write-ScriptLog "awrise doctor exited $LASTEXITCODE — review split-home or hostclock verdict above." -Level Warning
    } else {
        Write-ScriptLog "awrise doctor passed cleanly." -Level Success
    }
}
catch {
    Write-ScriptLog "awrise & eval setup failed: $_" -Level Error
    throw
}
