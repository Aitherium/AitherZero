#Requires -Version 7.0

<#
.SYNOPSIS
    Internal function to execute an orchestration sequence.

.DESCRIPTION
    Executes a sequence of scripts as part of an orchestration/playbook run.
    This is used internally by Resume-AitherOrchestration and other orchestration commands.

.PARAMETER Scripts
    Array of script specifications to execute.

.PARAMETER StartFrom
    Index to start execution from (for resume).

.PARAMETER SkipFailed
    Skip previously failed scripts.

.PARAMETER RetryFailed
    Retry previously failed scripts.

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

        [switch]$SkipFailed,

        [switch]$RetryFailed,

        [string]$ExecutionId,

        [hashtable]$Context = @{}
    )

    $results = @()
    $success = $true

    for ($i = $StartFrom; $i -lt $Scripts.Count; $i++) {
        $script = $Scripts[$i]
        $scriptName = if ($script -is [string]) { $script } else { $script.Script }

        try {
            Write-Verbose "Executing script $($i + 1)/$($Scripts.Count): $scriptName"
            
            $scriptResult = Invoke-AitherScript -Script $scriptName -ErrorAction Stop
            
            $results += [PSCustomObject]@{
                Index    = $i
                Script   = $scriptName
                Success  = $true
                Output   = $scriptResult
                Error    = $null
            }
        }
        catch {
            $success = $false
            $results += [PSCustomObject]@{
                Index    = $i
                Script   = $scriptName
                Success  = $false
                Output   = $null
                Error    = $_.Exception.Message
            }

            if (-not $SkipFailed) {
                Write-Warning "Script '$scriptName' failed: $($_.Exception.Message)"
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
        Total       = $Scripts.Count
    }
}
