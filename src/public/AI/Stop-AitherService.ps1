#Requires -Version 7.0

<#
.SYNOPSIS
    Stop an AitherOS service.

.DESCRIPTION
    Stops the specified AitherOS service by terminating its process.

.PARAMETER Name
    Service name or alias. Required.
    Examples: 'Node', 'AitherNode', 'MCP', 'Reasoning'

.PARAMETER Force
    Force stop even if service is in use.

.PARAMETER ShowOutput
    Display progress and status.

.PARAMETER PassThru
    Return result object instead of display output.

.EXAMPLE
    Stop-AitherService -Name Node
    # Stops AitherNode MCP server

.EXAMPLE
    Stop-AitherService -Name Node -Force
    # Force stops AitherNode

.NOTES
    Part of the AitherZero module.
#>
function Stop-AitherService {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        
        [Parameter()]
        [switch]$Force,
        
        [Parameter()]
        [switch]$ShowOutput,
        
        [Parameter()]
        [switch]$PassThru
    )
    
    # Service definitions
    $AitherServices = @{
        AitherNode      = @{ Port = 8080; Alias = @('Node', 'MCP') }
        AitherReasoning = @{ Port = 8093; Alias = @('Reasoning', 'Traces') }
        AitherPulse     = @{ Port = 8081; Alias = @('Pulse', 'Events') }
        AitherCanvas    = @{ Port = 8188; Alias = @('Canvas', 'Comfy', 'ImageGen') }
        AitherVeil      = @{ Port = 3000; Alias = @('Veil', 'Dashboard', 'UI') }
        AitherPrism     = @{ Port = 8106; Alias = @('Prism', 'Video') }
        AitherTrainer   = @{ Port = 8107; Alias = @('Trainer', 'Training') }
        vLLMOrchestrator = @{ Port = 8200; Alias = @('Orchestrator', 'LLM') }
        vLLMReasoning   = @{ Port = 8201; Alias = @('Reasoning-vLLM') }
        vLLMVision      = @{ Port = 8202; Alias = @('Vision-vLLM') }
        vLLMCoding      = @{ Port = 8203; Alias = @('Coding-vLLM') }
    }
    
    # Resolve service name
    $svcName = $null
    if ($AitherServices.ContainsKey($Name)) {
        $svcName = $Name
    } else {
        foreach ($svc in $AitherServices.Keys) {
            if ($AitherServices[$svc].Alias -contains $Name) {
                $svcName = $svc
                break
            }
        }
    }
    
    if (-not $svcName) {
        Write-AitherLog -Level Warning -Message "Service '$Name' not found. Available: $($AitherServices.Keys -join ', ')" -Source 'Stop-AitherService'
        return
    }
    
    $def = $AitherServices[$svcName]
    $port = $def.Port
    
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $conn) {
        if ($ShowOutput) { Write-AitherLog -Level Information -Message "○ $svcName is not running" -Source 'Stop-AitherService' }
        $result = [PSCustomObject]@{ Name = $svcName; Status = 'NotRunning'; Port = $port; PID = $null }
        if ($PassThru) { return $result }
        return
    }
    
    $processId = $conn.OwningProcess
    
    if ($PSCmdlet.ShouldProcess($svcName, "Stop service (PID: $processId)")) {
        if ($ShowOutput) { Write-AitherLog -Level Information -Message "⏹ Stopping $svcName (PID: $processId)..." -Source 'Stop-AitherService' }
        
        try {
            Stop-Process -Id $processId -Force:$Force -ErrorAction Stop
            Start-Sleep -Seconds 1
            
            $check = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
            if (-not $check) {
                if ($ShowOutput) { Write-AitherLog -Level Information -Message "✓ $svcName stopped" -Source 'Stop-AitherService' }
                $result = [PSCustomObject]@{ Name = $svcName; Status = 'Stopped'; Port = $port; PID = $processId }
            } else {
                Write-AitherLog -Level Warning -Message "$svcName may still be running" -Source 'Stop-AitherService'
                $result = [PSCustomObject]@{ Name = $svcName; Status = 'StopFailed'; Port = $port; PID = $processId }
            }
            if ($PassThru) { return $result }
        }
        catch {
            Write-AitherLog -Level Error -Message "Failed to stop $svcName`: $_" -Source 'Stop-AitherService' -Exception $_
            $result = [PSCustomObject]@{ Name = $svcName; Status = 'Error'; Port = $port; PID = $pid }
            if ($PassThru) { return $result }
        }
    }
}
