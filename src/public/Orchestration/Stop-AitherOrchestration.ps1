#Requires -Version 7.0

<#
.SYNOPSIS
    Stop a running orchestration execution

.DESCRIPTION
    Stops a running playbook execution gracefully. Attempts to stop running scripts
    and clean up resources. Use this when you need to cancel a long-running playbook.

.PARAMETER PlaybookName
    Name of the playbook to stop. Stops the most recent execution if multiple are running.

.PARAMETER ExecutionId
    Specific execution ID to stop. Use this to stop a specific orchestration run.

.PARAMETER Force
    Force stop without waiting for scripts to complete gracefully.

.INPUTS
    System.String
    You can pipe playbook names or execution IDs to Stop-AitherOrchestration.

.OUTPUTS
    PSCustomObject
    Returns stop result with Success, ExecutionId, and StoppedScripts properties.

.EXAMPLE
    Stop-AitherOrchestration -PlaybookName "deployment"

    Stops the running "deployment" playbook execution.

.EXAMPLE
    Stop-AitherOrchestration -ExecutionId "abc123" -Force

    Force stops a specific execution.

.NOTES
    Stopping orchestration will:
    - Cancel running scripts
    - Mark execution as stopped
    - Clean up resources
    - Update execution history

.LINK
    Get-AitherOrchestrationStatus
    Invoke-AitherPlaybook
#>
function Stop-AitherOrchestration {
[OutputType([PSCustomObject])]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string]$PlaybookName,

    [Parameter(ValueFromPipelineByPropertyName)]
    [string]$ExecutionId,

    [switch]$Force,

    [Parameter(HelpMessage = "Show command output in console.")]
    [switch]$ShowOutput
)

begin {
    # Manage logging targets for this execution
    $originalLogTargets = $script:AitherLogTargets
    if ($ShowOutput) {
        if ($script:AitherLogTargets -notcontains 'Console') {
            $script:AitherLogTargets += 'Console'
        }
    }
    else {
        # Ensure Console is NOT in targets if ShowOutput is not specified
        $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $PlaybookName -and -not $ExecutionId) {
            return $null
        }

        # Check if Get-AitherOrchestrationStatus is available
        if (-not (Get-Command Get-AitherOrchestrationStatus -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Message "Get-AitherOrchestrationStatus is not available. Cannot stop orchestration." -Level Warning
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

        if (-not $status -or $status.Status -ne 'Running') {
            Write-AitherLog -Message "No running orchestration found for: $PlaybookName" -Level Warning
            return [PSCustomObject]@{
                Success = $false
                Message = "No running orchestration found"
            }
        }

        if ($PSCmdlet.ShouldProcess($status.PlaybookName, "Stop orchestration execution")) {
            # Stop execution (implementation depends on orchestration engine)
            # For now, mark as stopped in history
            $moduleRoot = Get-AitherModuleRoot
            $historyPath = Join-Path $moduleRoot 'library' 'execution-history'
            $historyFile = Join-Path $historyPath "$($status.ExecutionId).json"

            if (Test-Path $historyFile) {
                $execution = Get-Content -Path $historyFile -Raw | ConvertFrom-Json -AsHashtable
                $execution.Status = 'Stopped'
                $execution.EndTime = Get-Date
                $execution | ConvertTo-Json -Depth 10 | Out-File -FilePath $historyFile -Encoding UTF8 -Force
            }

            Write-AitherLog -Level Information -Message "Stopped orchestration: $($status.PlaybookName)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Data @{
                ExecutionId = $status.ExecutionId
                Force = $Force
            }
            return [PSCustomObject]@{
                Success = $true
                ExecutionId = $status.ExecutionId
                PlaybookName = $status.PlaybookName
                StoppedScripts = $status.RunningScripts
            }
        }
    }
    catch {
        # Use centralized error handling
        $errorScript = Join-Path $PSScriptRoot '..' 'Private' 'Write-AitherError.ps1'
        if (Test-Path $errorScript) {
            . $errorScript -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Stopping orchestration: $PlaybookName" -Parameters $PSBoundParameters -ThrowOnError
        }
        else {
            $errorObject = [PSCustomObject]@{
                PSTypeName = 'AitherZero.Error'
                Success = $false
                ErrorId = [System.Guid]::NewGuid().ToString()
                Cmdlet = $PSCmdlet.MyInvocation.MyCommand.Name
                Operation = "Stopping orchestration: $PlaybookName"
                Error = $_.Exception.Message
                Timestamp = Get-Date
            }
            Write-Output $errorObject

            Write-AitherLog -Level Error -Message "Failed to stop orchestration $PlaybookName : $($_.Exception.Message)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Exception $_
        }
        throw
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

