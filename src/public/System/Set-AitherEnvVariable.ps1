#Requires -Version 7.0

<#
.SYNOPSIS
    Update a single environment variable

.DESCRIPTION
    Sets or updates an environment variable at the specified scope (Process, User, or Machine).
    Machine scope requires administrator privileges.

.PARAMETER Name
    Variable name

.PARAMETER Value
    Variable value

.PARAMETER Scope
    Variable scope: Process, User, or Machine (System)

.PARAMETER Force
    Overwrite existing value without confirmation

.EXAMPLE
    Set-AitherEnvVariable -Name 'AITHERZERO_PROFILE' -Value 'Developer' -Scope User

    Set a user environment variable

.EXAMPLE
    Set-AitherEnvVariable -Name 'MY_VAR' -Value 'test' -Scope Process -Force

    Set a process environment variable, overwriting if it exists

.OUTPUTS
    Boolean - True if variable was set successfully, False otherwise

.NOTES
    Machine scope requires administrator privileges.
    Process scope variables only persist for the current session.
    User scope variables persist across sessions for the current user.

.LINK
    Get-AitherEnvironmentConfig
    Set-AitherEnvironmentConfig
#>
function Set-AitherEnvVariable {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value,

        [ValidateSet('Process', 'User', 'Machine')]
        [string]$Scope = 'Process',

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

    process {
        try {
            # During module validation, skip execution
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $Name) {
                return $false
            }

            $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

            # Check admin rights for Machine scope
            if ($Scope -eq 'Machine') {
                $isAdmin = if (Get-Command Test-AitherAdmin -ErrorAction SilentlyContinue) {
                    Test-AitherAdmin
                }
                else {
                    $false
                }
                if (-not $isAdmin) {
                    if ($hasWriteAitherLog) {
                        Write-AitherLog -Message "Administrator privileges required for Machine scope" -Level Warning -Source 'Set-AitherEnvVariable'
                    }
                else {
                    Write-AitherLog -Level Warning -Message "Administrator privileges required for Machine scope" -Source 'Set-AitherEnvVariable'
                }
                    return $false
                }
            }

            # Get current value
            $currentValue = [Environment]::GetEnvironmentVariable($Name, $Scope)

            if ($currentValue -and -not $Force) {
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Variable $Name already exists with value: $currentValue" -Level Warning -Source 'Set-AitherEnvVariable'
                }
                else {
                    Write-AitherLog -Level Warning -Message "Variable $Name already exists with value: $currentValue" -Source 'Set-AitherEnvVariable'
                }
                $confirmation = Read-Host "Overwrite? (y/N)"
                if ($confirmation -ne 'y') {
                    if ($hasWriteAitherLog) {
                        Write-AitherLog -Message "Operation cancelled" -Level Information -Source 'Set-AitherEnvVariable'
                    }
                    return $false
                }
            }

            try {
                [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Set $Scope environment variable: $Name = $Value" -Level Information -Source 'Set-AitherEnvVariable'
                }
                return $true
            }
            catch {
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Error setting environment variable: $($_.Exception.Message)" -Level Error -Source 'Set-AitherEnvVariable' -Exception $_
                }
                else {
                    Write-AitherLog -Level Error -Message "Error setting environment variable: $($_.Exception.Message)" -Source 'Set-AitherEnvVariable' -Exception $_
                }
                throw
            }
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }    
}

