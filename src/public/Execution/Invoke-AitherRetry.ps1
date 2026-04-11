#Requires -Version 7.0

<#
.SYNOPSIS
    Execute a script block with retry logic

.DESCRIPTION
    Executes a script block with configurable retry attempts and delays.
    Useful for operations that may fail transiently (network calls, file operations, etc.).

.PARAMETER ScriptBlock
    The script block to execute

.PARAMETER MaxAttempts
    Maximum number of attempts (default: 3)

.PARAMETER DelaySeconds
    Delay between attempts in seconds (default: 5)

.PARAMETER ErrorMessage
    Custom error message prefix

.EXAMPLE
    Invoke-AitherRetry -ScriptBlock {
        Invoke-WebRequest -Uri "https://example.com"
    } -MaxAttempts 5 -DelaySeconds 10

    Retry web request up to 5 times with 10 second delays

.EXAMPLE
    Invoke-AitherRetry -ScriptBlock {
        Copy-Item -Path $source -Destination $dest
    }

    Retry file copy with default settings (3 attempts, 5 second delay)

.OUTPUTS
    Object - The result of the script block execution

.NOTES
    Throws the last exception if all attempts fail.
    Logs each attempt for debugging.

.LINK
    Invoke-AitherScript
#>
function Invoke-AitherRetry {
[CmdletBinding()]
param(
    [Parameter()]
    [int]$DelaySeconds = 5,

    [Parameter()]
    [string]$ErrorMessage = "Operation failed",

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

process {
    try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $ScriptBlock) {
            return
        }

        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

        $attempt = 1
        $lastError = $null

        while ($attempt -le $MaxAttempts) {
            try {
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Attempt $attempt of $MaxAttempts" -Level Debug -Source 'Invoke-AitherRetry'
                }

                $result = & $ScriptBlock

                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Operation succeeded on attempt $attempt" -Level Debug -Source 'Invoke-AitherRetry'
                }
                return $result
            }
            catch {
                $lastError = $_

                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "$ErrorMessage (attempt $attempt of $MaxAttempts): $($_.Exception.Message)" -Level Warning -Source 'Invoke-AitherRetry'
                }

                if ($attempt -lt $MaxAttempts) {
                    if ($hasWriteAitherLog) {
                        Write-AitherLog -Message "Retrying in $DelaySeconds seconds..." -Level Debug -Source 'Invoke-AitherRetry'
                    }
                    Start-Sleep -Seconds $DelaySeconds
                }

                $attempt++
            }
        }

        # If we get here, all attempts failed
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "$ErrorMessage - All $MaxAttempts attempts failed" -Level Error -Source 'Invoke-AitherRetry'
        }

        throw $lastError
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

