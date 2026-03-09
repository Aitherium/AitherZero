#Requires -Version 7.0

<#
.SYNOPSIS
    Get active PowerShell remoting sessions

.DESCRIPTION
    Lists all active PSSession objects in the current PowerShell session. Useful for
    monitoring active connections and managing session resources.

.PARAMETER Name
    Filter sessions by name. Returns only sessions matching this name pattern.

.PARAMETER ComputerName
    Filter sessions by computer name. Returns only sessions connected to these computers.

.PARAMETER Id
    Filter sessions by session ID. Returns only sessions with matching IDs.

.PARAMETER State
    Filter sessions by state (Opened, Closed, Broken, etc.).

.INPUTS
    System.String
    You can pipe session names or computer names to Get-AitherPSSession.

    System.Int32
    You can pipe session IDs to Get-AitherPSSession.

.OUTPUTS
    System.Management.Automation.Runspaces.PSSession
    Returns PSSession objects.

.EXAMPLE
    Get-AitherPSSession
    
    Lists all active PSSessions in the current session.

.EXAMPLE
    Get-AitherPSSession -ComputerName "server01"
    
    Lists all sessions connected to server01.

.EXAMPLE
    Get-AitherPSSession -State Opened
    
    Lists only sessions that are currently open and ready for use.

.EXAMPLE
    Get-AitherPSSession -Name "Production*"
    
    Lists sessions with names matching "Production*" pattern.

.NOTES
    This cmdlet wraps Get-PSSession and adds filtering capabilities. Sessions are
    automatically cleaned up when the PowerShell session ends, but you should
    explicitly remove them when done to free resources.

.LINK
    New-AitherPSSession
    Remove-AitherPSSession
    Save-AitherPSSession
#>
function Get-AitherPSSession {
[OutputType([System.Management.Automation.Runspaces.PSSession])]
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string]$Name,
    
    [Parameter(ValueFromPipelineByPropertyName)]
    [string[]]$ComputerName,
    
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [int[]]$Id,
    
    [Parameter()]
    [string]$State
)

process {
    try {
        $sessions = Get-PSSession -ErrorAction SilentlyContinue
        
        # Apply filters
        if ($Name) {
            $sessions = $sessions | Where-Object { $_.Name -like $Name }
        }
        if ($ComputerName) {
            $sessions = $sessions | Where-Object { $_.ComputerName -in $ComputerName }
        }
        if ($Id) {
            $sessions = $sessions | Where-Object { $_.Id -in $Id }
        }
        if ($PSBoundParameters.ContainsKey('State')) {
            $sessions = $sessions | Where-Object { $_.State -eq $State }
        }
        
        return $sessions
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Getting PSSessions" -Parameters $PSBoundParameters -ThrowOnError
    }
}


}

