#Requires -Version 7.0

<#
.SYNOPSIS
    Centralized error handler for AitherZero cmdlets

.DESCRIPTION
    Provides standardized error handling and logging for all AitherZero cmdlets.
    Ensures consistent error reporting with full context for debugging.

    This is a private helper function. Use the Invoke-AitherErrorHandler helper function
    in cmdlets for cleaner error handling.

.NOTES
    This is a private helper function for use within AitherZero cmdlets.
#>
function Write-AitherError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory)]
        [string]$CmdletName,

        [Parameter(Mandatory)]
        [string]$Operation,

        [hashtable]$Parameters = @{},

        [switch]$ThrowOnError
    )

    # Handle error action preference first to determine behavior
    $errorActionPreference = if ($PSBoundParameters.ContainsKey('ErrorAction')) {
        $PSBoundParameters.ErrorAction
    }
    else {
        'Continue'
    }

    if ($errorActionPreference -eq 'Stop') {
        $ThrowOnError = $true
    }

    # Generate unique error ID for tracking
    $errorId = [System.Guid]::NewGuid().ToString()
    $timestamp = Get-Date

    # Build comprehensive error information
    $errorInfo = @{
        ErrorId = $errorId
        Cmdlet = $CmdletName
        Operation = $Operation
        Error = $ErrorRecord.Exception.Message
        ErrorType = $ErrorRecord.Exception.GetType().FullName
        StackTrace = $ErrorRecord.ScriptStackTrace
        PositionMessage = $ErrorRecord.PositionMessage
        Parameters = $Parameters
        Timestamp = $timestamp
        ComputerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { $env:HOSTNAME }
        UserName = if ($IsWindows) { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } else { $env:USER }
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        OS = if ($IsWindows) { "Windows" } elseif ($IsLinux) { "Linux" } elseif ($IsMacOS) { "macOS" } else { "Unknown" }
    }

    # Log error with full context
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        # If we are going to throw, suppress console logging to avoid duplication
        # The error will be displayed by the throw/exception mechanism
        $targets = if ($ThrowOnError -and $errorActionPreference -ne 'SilentlyContinue') { @('File') } else { $null }

        Write-AitherLog -Level Error -Message "Error in $CmdletName during $Operation" -Source $CmdletName -Exception $ErrorRecord.Exception -Data $errorInfo -Targets $targets
    }
    else {
        # Fallback logging if Write-AitherLog not available
        if (-not $ThrowOnError) {
            Write-Error "Error in $CmdletName during $Operation : $($ErrorRecord.Exception.Message)" -ErrorId $errorId
        }
    }

    # Create error object for pipeline output
    $errorObject = [PSCustomObject]@{
        PSTypeName = 'AitherZero.Error'
        Success = $false
        ErrorId = $errorId
        Cmdlet = $CmdletName
        Operation = $Operation
        Error = $ErrorRecord.Exception.Message
        ErrorType = $ErrorRecord.Exception.GetType().FullName
        Timestamp = $timestamp
        Parameters = $Parameters
        StackTrace = $ErrorRecord.ScriptStackTrace
    }

    # Always output error object to pipeline
    Write-Output $errorObject

    if ($errorActionPreference -eq 'SilentlyContinue') {
        return
    }

    # Re-throw if requested
    if ($ThrowOnError) {
        throw $ErrorRecord
    }
}


