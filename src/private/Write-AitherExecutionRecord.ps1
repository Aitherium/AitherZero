#Requires -Version 7.0

<#
.SYNOPSIS
    Persist a playbook execution record, including per-step results.

.DESCRIPTION
    THE single writer for the execution-history store. Before this existed, three
    consumers read that store and NOTHING wrote it:

      Get-AitherOrchestrationStatus  -> library/execution-history
      Stop-AitherOrchestration       -> library/execution-history
      Get-AitherExecutionHistory     -> library/reports/execution-history

    Neither directory existed. Every consumer fails SOFT to an empty result, which
    reads as "no executions have run" rather than "the store was never written" --
    so Resume-AitherOrchestration threw "No orchestration found" on every call and
    the real cause was invisible. Per-step Results were built in memory by
    Invoke-AitherPlaybook and discarded on return.

    Resume cannot work without this: knowing WHICH steps completed is the whole
    input to "don't re-run them".

    Records are written atomically (temp + move) because a resume reading a
    half-written record would skip steps that never ran -- a worse failure than
    not resuming at all.

.PARAMETER ExecutionId
    Unique id for this execution. Becomes the file name.

.PARAMETER PlaybookName
    Playbook this execution belongs to.

.PARAMETER Status
    Running | Completed | Failed | Stopped.

.PARAMETER Results
    Per-step result objects. Each should carry Index, Script, Success, Error.

.PARAMETER StartTime
    When the execution began.

.PARAMETER Variables
    Variables the playbook was invoked with. Values matching a credential-shaped
    name are replaced with '<withheld>' -- an execution record is a file on disk
    and must never become a secret sink.

.OUTPUTS
    System.String. Full path of the record written.

.NOTES
    Category: Orchestration
    Platform: Windows, Linux, macOS
#>
function Write-AitherExecutionRecord {
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [string]$PlaybookName,

        [ValidateSet('Running', 'Completed', 'Failed', 'Stopped')]
        [string]$Status = 'Running',

        [array]$Results = @(),

        [datetime]$StartTime = (Get-Date),

        [hashtable]$Variables = @{}
    )

    # Same withholding rule the quadlet generator uses: match on the NAME, never
    # attempt to detect a secret by the shape of its value.
    $secretRe = '(?i)(secret|password|passwd|token|api[-_]?key|bearer|credential|private[-_]?key)'
    $notSecretRe = '(?i)(_path$|_ttl$|_file$|_url$|_enabled$|_timeout$)'

    $safeVars = @{}
    foreach ($k in $Variables.Keys) {
        if ($k -match $secretRe -and $k -notmatch $notSecretRe) {
            $safeVars[$k] = '<withheld>'
        }
        else {
            $safeVars[$k] = $Variables[$k]
        }
    }

    $moduleRoot = Get-AitherModuleRoot
    $historyPath = Join-Path $moduleRoot 'library' 'reports' 'execution-history'

    if (-not (Test-Path $historyPath)) {
        New-Item -Path $historyPath -ItemType Directory -Force | Out-Null
    }

    $record = [ordered]@{
        ExecutionId  = $ExecutionId
        PlaybookName = $PlaybookName
        Status       = $Status
        StartTime    = $StartTime.ToString('o')
        EndTime      = (Get-Date).ToString('o')
        Variables    = $safeVars
        Total        = @($Results).Count
        Completed    = @($Results | Where-Object { $_.Success }).Count
        Failed       = @($Results | Where-Object { -not $_.Success }).Count
        Results      = @($Results | ForEach-Object {
                [ordered]@{
                    Index   = $_.Index
                    Script  = $_.Script
                    Success = [bool]$_.Success
                    Error   = if ($_.Error) { "$($_.Error)" } else { $null }
                }
            })
    }

    $target = Join-Path $historyPath "$ExecutionId.json"

    if (-not $PSCmdlet.ShouldProcess($target, 'Write execution record')) {
        return $target
    }

    # Atomic: a resume that reads a torn record would skip steps that never ran.
    $tmp = "$target.tmp"
    $record | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding utf8 -Force
    Move-Item -Path $tmp -Destination $target -Force

    return $target
}
