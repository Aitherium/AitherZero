#Requires -Version 7.0

<#
.SYNOPSIS
    Resume a failed or stopped orchestration execution

.DESCRIPTION
    Resumes a failed or stopped playbook execution from where it left off.
    Skips scripts that already completed successfully and continues with remaining scripts.
    Useful for recovering from temporary failures.

.PARAMETER PlaybookName
    Name of the playbook to resume. Resumes the most recent failed/stopped execution.

.PARAMETER ExecutionId
    Specific execution ID to resume.

.PARAMETER SkipFailed
    Skip scripts that failed previously and continue with remaining scripts.

.PARAMETER RetryFailed
    Retry scripts that failed previously instead of skipping them.

.INPUTS
    System.String
    You can pipe playbook names or execution IDs to Resume-AitherOrchestration.

.OUTPUTS
    PSCustomObject
    Returns resume result with Success, ExecutionId, and ResumedScripts properties.

.EXAMPLE
    Resume-AitherOrchestration -PlaybookName "deployment"

    Resumes the failed "deployment" playbook execution.

.EXAMPLE
    Resume-AitherOrchestration -ExecutionId "abc123" -RetryFailed

    Resumes a specific execution and retries failed scripts.

.NOTES
    Resuming orchestration will:
    - Load previous execution state
    - Skip completed scripts
    - Retry or skip failed scripts based on parameters
    - Continue with remaining scripts

.LINK
    Get-AitherOrchestrationStatus
    Invoke-AitherPlaybook
    Stop-AitherOrchestration
#>
function Resume-AitherOrchestration {
    [OutputType([PSCustomObject])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$PlaybookName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ExecutionId,

        [switch]$SkipFailed,

        [switch]$RetryFailed,

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
    }

    process {
        try {
            # During module validation, skip execution
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $PlaybookName -and -not $ExecutionId) {
                return $null
            }

            # Check if Get-AitherOrchestrationStatus is available
            if (-not (Get-Command Get-AitherOrchestrationStatus -ErrorAction SilentlyContinue)) {
                Write-AitherLog -Level Warning -Message "Get-AitherOrchestrationStatus is not available. Cannot resume orchestration." -Source 'Resume-AitherOrchestration'
                return $null
            }

            # Get orchestration status
            $statusParams = @{}
            if ($PlaybookName) {
                $statusParams.PlaybookName = $PlaybookName
            }
            if ($ExecutionId) {
                $statusParams.ExecutionId = $ExecutionId
            }

            $status = Get-AitherOrchestrationStatus @statusParams | Select-Object -First 1

            if (-not $status) {
                throw "No orchestration found for: $PlaybookName"
            }
            if ($status.Status -eq 'Running') {
                Write-AitherLog -Level Warning -Message "Orchestration is already running. Cannot resume." -Source 'Resume-AitherOrchestration'
                return [PSCustomObject]@{
                    Success = $false
                    Message = "Orchestration is already running"
                }
            }

            if ($PSCmdlet.ShouldProcess($status.PlaybookName, "Resume orchestration execution")) {
                # Load playbook
                $playbook = Get-AitherPlaybook -Name $status.PlaybookName

                if (-not $playbook) {
                    throw "Playbook not found: $($status.PlaybookName)"
                }

                # Resume execution via orchestration engine
                $resumeParams = @{
                    LoadPlaybook    = $status.PlaybookName
                    ContinueOnError = $true
                }
                if ($RetryFailed) {
                    $resumeParams.RetryFailed = $true
                }
                elseif ($SkipFailed) {
                    $resumeParams.SkipFailed = $true
                }

                if (Get-Command Invoke-OrchestrationSequence -ErrorAction SilentlyContinue) {
                    $result = Invoke-OrchestrationSequence @resumeParams

                    Write-AitherLog -Level Information -Message "Resumed orchestration: $($status.PlaybookName)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Data @{
                        ExecutionId = $status.ExecutionId
                        RetryFailed = $RetryFailed
                        SkipFailed  = $SkipFailed
                    }
                    return [PSCustomObject]@{
                        Success        = $true
                        ExecutionId    = $status.ExecutionId
                        PlaybookName   = $status.PlaybookName
                        ResumedScripts = if ($result.Completed) { $result.Completed } else { 0 }
                    }
                }
                else {
                    throw "OrchestrationEngine not available"
                }
            }
        }
        catch {
            # Use centralized error handling
            $errorScript = Join-Path $PSScriptRoot '..' 'Private' 'Write-AitherError.ps1'
            if (Test-Path $errorScript) {
                . $errorScript -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Resuming orchestration: $PlaybookName" -Parameters $PSBoundParameters -ThrowOnError
            }
            else {
                $errorObject = [PSCustomObject]@{
                    PSTypeName = 'AitherZero.Error'
                    Success    = $false
                    ErrorId    = [System.Guid]::NewGuid().ToString()
                    Cmdlet     = $PSCmdlet.MyInvocation.MyCommand.Name
                    Operation  = "Resuming orchestration: $PlaybookName"
                    Error      = $_.Exception.Message
                    Timestamp  = Get-Date
                }
                Write-Output $errorObject

            Write-AitherLog -Level Error -Message "Failed to resume orchestration $PlaybookName : $($_.Exception.Message)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Exception $_
        }
        throw
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}}

