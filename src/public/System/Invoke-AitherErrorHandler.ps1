#Requires -Version 7.0

<#
.SYNOPSIS
    Centralized error handler helper for AitherZero cmdlets

.DESCRIPTION
    Simplified helper function for cmdlets to use Write-AitherError
    with automatic context capture.

.NOTES
    This is a private helper function for use within AitherZero cmdlets.
#>
function Invoke-AitherErrorHandler {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Operation,
        [hashtable]$Parameters = @{},
        [switch]$ThrowOnError
    )

    $cmdletName = if ($PSCmdlet) { $PSCmdlet.MyInvocation.MyCommand.Name } else { 'Unknown' }
    Write-AitherError -ErrorRecord $ErrorRecord -CmdletName $cmdletName -Operation $Operation -Parameters $Parameters -ThrowOnError:$ThrowOnError
}

