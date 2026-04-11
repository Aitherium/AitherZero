#Requires -Version 7.0

<#
.SYNOPSIS
    Restart an AitherOS service.

.DESCRIPTION
    Stops and then starts the specified AitherOS service.

.PARAMETER Name
    Service name or alias. Required.
    Examples: 'Node', 'AitherNode', 'MCP', 'Reasoning'

.PARAMETER Port
    Override the default port for the service.

.PARAMETER Force
    Force stop even if service is in use.

.PARAMETER ShowOutput
    Display progress and status.

.PARAMETER PassThru
    Return result object instead of display output.

.EXAMPLE
    Restart-AitherService -Name Node
    # Restarts AitherNode MCP server

.EXAMPLE
    Restart-AitherService -Name Node -ShowOutput
    # Restarts with progress output

.NOTES
    Part of the AitherZero module.
#>
function Restart-AitherService {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        
        [Parameter()]
        [int]$Port,
        
        [Parameter()]
        [switch]$Force,
        
        [Parameter()]
        [switch]$ShowOutput,
        
        [Parameter()]
        [switch]$PassThru
    )
    
    if ($PSCmdlet.ShouldProcess($Name, "Restart service")) {
        if ($ShowOutput) { Write-AitherLog -Level Information -Message "🔄 Restarting $Name..." -Source 'Restart-AitherService' }
        
        # Stop
        Stop-AitherService -Name $Name -Force:$Force -ShowOutput:$ShowOutput
        Start-Sleep -Seconds 2
        
        # Start
        $startParams = @{
            Name = $Name
            ShowOutput = $ShowOutput
            Wait = $true
            PassThru = $PassThru
        }
        if ($Port) { $startParams.Port = $Port }
        
        $result = Start-AitherService @startParams
        
        if ($PassThru) { return $result }
    }
}
