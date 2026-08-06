#Requires -Version 7.0

<#
.SYNOPSIS
    Internal function to execute an orchestration sequence.

.DESCRIPTION
    Executes a sequence of scripts as part of an orchestration/playbook run.
    This is used internally by Resume-AitherOrchestration and other orchestration commands.

    Resume semantics live here. Previously SkipFailed and RetryFailed were accepted
    and never read -- SkipFailed only decided whether to `break`, and RetryFailed did
    nothing at all -- so a resume re-ran every completed step. That is unusable for a
    multi-hour migration, where re-running step 1 means re-transferring images.

.PARAMETER Scripts
    Array of script specifications to execute.

.PARAMETER StartFrom
    Index to start execution from (for resume).

.PARAMETER CompletedIndices
    Indices that already succeeded in a previous run. They are SKIPPED, not re-run.
    This is what makes resume a resume. Passing an empty array runs everything.

.PARAMETER FailedIndices
    Indices that failed in a previous run. Combined with -SkipFailed (skip them) or
    -RetryFailed (run them again). With neither, they run normally.

.PARAMETER SkipFailed
    Skip previously failed scripts, and continue past a failure in this run instead
    of stopping at it.

.PARAMETER RetryFailed
    Retry previously failed scripts.

.PARAMETER DryRun
    Forward -DryRun to each script so the script's OWN dry-run path is exercised.
    The engine deliberately does NOT short-circuit here: returning early without
    calling anything means dry-run parity can never be verified, which is the
    condition this parameter exists to test.

.PARAMETER TimeoutSec
    Per-step timeout. 0 (default) means no timeout, preserving existing behaviour.
    A hung step otherwise blocks forever -- which is exactly what a wedged image
    transfer does.

.PARAMETER OnFailure
    Script to invoke when a step fails, receiving the error context. Lets a playbook
    drive its own rollback instead of only logging that it should have.

.PARAMETER ExecutionId
    Execution ID for tracking.

.NOTES
    Internal use only. Use Invoke-AitherPlaybook for public API.
#>
function Invoke-OrchestrationSequence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Scripts,

        [int]$StartFrom = 0,

        [int[]]$CompletedIndices = @(),

        [int[]]$FailedIndices = @(),

        [switch]$SkipFailed,

        [switch]$RetryFailed,

        [switch]$DryRun,

        [int]$TimeoutSec = 0,

        [string]$OnFailure,

        [string]$ExecutionId,

        [hashtable]$Context = @{}
    )

    $results = @()
    $success = $true
    $completedSet = [System.Collections.Generic.HashSet[int]]::new([int[]]$CompletedIndices)
    $failedSet = [System.Collections.Generic.HashSet[int]]::new([int[]]$FailedIndices)

    for ($i = $StartFrom; $i -lt $Scripts.Count; $i++) {
        $script = $Scripts[$i]
        $scriptName = if ($script -is [string]) { $script } else { $script.Script }

        # Already succeeded in a previous run -- the whole point of resuming.
        if ($completedSet.Contains($i)) {
            Write-Verbose "Skipping already-completed script $($i + 1)/$($Scripts.Count): $scriptName"
            $results += [PSCustomObject]@{
                Index   = $i
                Script  = $scriptName
                Success = $true
                Skipped = $true
                Output  = $null
                Error   = $null
            }
            continue
        }

        # Previously failed and the caller asked to skip those.
        if ($failedSet.Contains($i) -and $SkipFailed -and -not $RetryFailed) {
            Write-Verbose "Skipping previously-failed script $($i + 1)/$($Scripts.Count): $scriptName"
            $results += [PSCustomObject]@{
                Index   = $i
                Script  = $scriptName
                Success = $true
                Skipped = $true
                Output  = $null
                Error   = 'skipped (previously failed, -SkipFailed)'
            }
            continue
        }

        try {
            Write-Verbose "Executing script $($i + 1)/$($Scripts.Count): $scriptName"

            $invokeParams = @{ Script = $scriptName; ErrorAction = 'Stop' }
            if ($DryRun) { $invokeParams.DryRun = $true }

            if ($TimeoutSec -gt 0) {
                # Start-Job runs in a FRESH runspace that has none of AitherZero
                # loaded, so the module must be imported inside it -- same pattern as
                # the parallel path. Without this the job does not fail fast: an
                # unresolved command sends PowerShell into a full PSModulePath
                # autoload scan, measured at ~120s on this box against a 2s timeout.
                # Every "timeout" would then be a command-not-found wearing a
                # timeout's clothes, and the step would never have run at all.
                $jobModuleRoot = Get-AitherModuleRoot
                $job = Start-Job -ScriptBlock {
                    param($p, $ModuleRoot)
                    $modulePath = Join-Path $ModuleRoot 'AitherZero' 'AitherZero.psd1'
                    Import-Module $modulePath -Force
                    Invoke-AitherScript @p
                } -ArgumentList $invokeParams, $jobModuleRoot

                if (Wait-Job -Job $job -Timeout $TimeoutSec) {
                    $scriptResult = Receive-Job -Job $job -ErrorAction Stop
                    Remove-Job -Job $job -Force
                }
                else {
                    Stop-Job -Job $job
                    Remove-Job -Job $job -Force
                    throw "Step timed out after ${TimeoutSec}s: $scriptName"
                }
            }
            else {
                $scriptResult = Invoke-AitherScript @invokeParams
            }

            $results += [PSCustomObject]@{
                Index   = $i
                Script  = $scriptName
                Success = $true
                Skipped = $false
                Output  = $scriptResult
                Error   = $null
            }
        }
        catch {
            $success = $false
            $errMsg = $_.Exception.Message
            $results += [PSCustomObject]@{
                Index   = $i
                Script  = $scriptName
                Success = $false
                Skipped = $false
                Output  = $null
                Error   = $errMsg
            }

            # A handler, not a log line: this is how a playbook drives rollback.
            if ($OnFailure) {
                try {
                    Write-Verbose "Invoking OnFailure handler: $OnFailure"
                    Invoke-AitherScript -Script $OnFailure -ErrorAction Stop
                }
                catch {
                    # The handler failing must not mask the original failure, but it
                    # must not vanish either -- a rollback that did not run is the
                    # single most important thing to surface here.
                    Write-Warning "OnFailure handler '$OnFailure' failed: $($_.Exception.Message)"
                }
            }

            if (-not $SkipFailed) {
                Write-Warning "Script '$scriptName' failed: $errMsg"
                break
            }
        }
    }

    return [PSCustomObject]@{
        Success     = $success
        ExecutionId = $ExecutionId
        Results     = $results
        Completed   = ($results | Where-Object { $_.Success }).Count
        Failed      = ($results | Where-Object { -not $_.Success }).Count
        Skipped     = ($results | Where-Object { $_.Skipped }).Count
        Total       = $Scripts.Count
    }
}
