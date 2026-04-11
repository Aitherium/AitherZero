#Requires -Version 7.0

<#
.SYNOPSIS
    Check execution status of running orchestration

.DESCRIPTION
    Retrieves the current status of orchestration execution, including which scripts
    are running, completed, or failed. Useful for monitoring long-running playbooks
    and understanding execution progress.

.PARAMETER PlaybookName
    Name of the playbook to check status for. If not specified, checks all active orchestrations.

.PARAMETER ExecutionId
    Specific execution ID to check. Use this to track a specific orchestration run.

.INPUTS
    System.String
    You can pipe playbook names to Get-AitherOrchestrationStatus.

.OUTPUTS
    PSCustomObject
    Returns orchestration status with properties:
    - PlaybookName: Name of the playbook
    - ExecutionId: Unique execution identifier
    - Status: Current status (Running, Completed, Failed, Paused)
    - StartTime: When execution started
    - Duration: How long execution has been running
    - CompletedScripts: Number of scripts completed
    - TotalScripts: Total number of scripts
    - RunningScripts: Currently running scripts
    - FailedScripts: Failed scripts

.EXAMPLE
    Get-AitherOrchestrationStatus

    Gets status of all active orchestrations.

.EXAMPLE
    Get-AitherOrchestrationStatus -PlaybookName "deployment"

    Gets status of the "deployment" playbook execution.

.NOTES
    Orchestration status is tracked in the execution history system.
    This cmdlet provides real-time visibility into playbook execution.

.LINK
    Invoke-AitherPlaybook
    Get-AitherExecutionHistory
    Stop-AitherOrchestration
#>
function Get-AitherOrchestrationStatus {
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$PlaybookName,

        [Parameter()]
        [string]$ExecutionId,

        [switch]$ShowOutput
    )

    begin {
        # Save original log targets
        $originalLogTargets = $script:AitherLogTargets

        # Set log targets based on ShowOutput parameter
        if ($ShowOutput) {
            # Ensure Console is in the log targets
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
        else {
            # Remove Console from log targets if present (default behavior)
            if ($script:AitherLogTargets -contains 'Console') {
                $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
            }
        }

        $moduleRoot = Get-AitherModuleRoot
    }

    process {
        try {
            try {
                $moduleRoot = Get-AitherModuleRoot
                $historyPath = Join-Path $moduleRoot 'library' 'execution-history'

                if (-not (Test-Path $historyPath)) {
                    return @()
                }

                # Get execution history files
                $historyFiles = Get-ChildItem -Path $historyPath -Filter "*.json" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending

                $statuses = @()

                foreach ($file in $historyFiles) {
                    try {
                        $execution = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json -AsHashtable

                        # Apply filters
                        if ($PlaybookName -and $execution.PlaybookName -ne $PlaybookName) {
                            continue
                        }
                        if ($ExecutionId -and $execution.ExecutionId -ne $ExecutionId) {
                            continue
                        }

                        # Determine status
                        $status = 'Unknown'
                        if ($execution.Completed) {
                            if ($execution.Failed -gt 0) {
                                $status = 'Failed'
                            }
                            else {
                                $status = 'Completed'
                            }
                        }
                        elseif ($execution.StartTime) {
                            $status = 'Running'
                        }

                        $statusObj = [PSCustomObject]@{
                            PSTypeName       = 'AitherZero.OrchestrationStatus'
                            PlaybookName     = $execution.PlaybookName
                            ExecutionId      = $execution.ExecutionId
                            Status           = $status
                            StartTime        = if ($execution.StartTime) { [DateTime]$execution.StartTime } else { $null }
                            Duration         = if ($execution.StartTime -and $execution.EndTime) {
                                ([DateTime]$execution.EndTime) - ([DateTime]$execution.StartTime)
                            }
                            elseif ($execution.StartTime) {
                                (Get-Date) - ([DateTime]$execution.StartTime)
                            }
                            else { $null }
                            CompletedScripts = $execution.Completed
                            TotalScripts     = $execution.Total
                            RunningScripts   = if ($execution.Running) { $execution.Running } else { 0 }
                            FailedScripts    = if ($execution.Failed) { $execution.Failed } else { 0 }
                        }

                        $statuses += $statusObj
                    }
                    catch {
                        continue
                    }
                }

                return $statuses
            }
            catch {
                # Use centralized error handling
                $errorScript = Join-Path $PSScriptRoot '..' 'Private' 'Write-AitherError.ps1'
                if (Test-Path $errorScript) {
                    . $errorScript -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Getting orchestration status" -Parameters $PSBoundParameters -ThrowOnError
                }
                else {
                    Write-AitherLog -Level Error -Message "Failed to get orchestration status: $_" -Source 'Get-AitherOrchestrationStatus' -Exception $_
                    throw
                }
            }
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }

}

