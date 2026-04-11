#Requires -Version 7.0

<#
.SYNOPSIS
    Get status of AitherOS services.

.DESCRIPTION
    Shows the status (Running/Stopped) of all or specified AitherOS services.
    Supports filtering by service name, alias, or online/offline status.

.PARAMETER Name
    Service name, alias, or wildcard pattern. Defaults to 'All'.
    Examples: 'Node', 'AitherNode', 'MCP', '*Vision*'

.PARAMETER Online
    Show only running services.

.PARAMETER Offline
    Show only stopped services.

.PARAMETER PassThru
    Return service objects instead of formatted display.

.EXAMPLE
    Get-AitherService
    # Shows status of all services

.EXAMPLE
    Get-AitherService -Name Node
    # Shows status of AitherNode service

.EXAMPLE
    Get-AitherService -Online
    # Shows only running services

.NOTES
    Part of the AitherZero module.
#>
function Get-AitherService {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name = 'All',
        
        [Parameter()]
        [switch]$Online,
        
        [Parameter()]
        [switch]$Offline,
        
        [Parameter()]
        [switch]$PassThru
    )
    
    # Service definitions (shared with other service cmdlets)
    $AitherServices = @{
        AitherNode      = @{ Port = 8080; Script = '0762'; Alias = @('Node', 'MCP'); Desc = 'MCP Server (Tools for AI agents)' }
        AitherReasoning = @{ Port = 8093; Script = '0764'; Alias = @('Reasoning', 'Traces'); Desc = 'Thinking Traces' }
        AitherPulse     = @{ Port = 8081; Script = '0765'; Alias = @('Pulse', 'Events'); Desc = 'Event Bus & Pain Signals' }
        AitherVision    = @{ Port = 8084; Script = '0766'; Alias = @('Vision'); Desc = 'Image Analysis' }
        AitherSpirit    = @{ Port = 8087; Script = '0767'; Alias = @('Spirit', 'Memory'); Desc = 'Long-term Memory' }
        AitherVeil      = @{ Port = 3000; Script = '0530'; Alias = @('Veil', 'Dashboard', 'UI'); Desc = 'Web Dashboard' }
        ComfyUI         = @{ Port = 8188; Script = '0734'; Alias = @('Comfy', 'ImageGen'); Desc = 'Image Generation' }
        vLLMOrchestrator = @{ Port = 8200; Script = $null; Alias = @('Orchestrator', 'LLM'); Desc = 'vLLM Orchestrator Model'; External = $true }
        vLLMReasoning   = @{ Port = 8201; Script = $null; Alias = @('Reasoning-vLLM'); Desc = 'vLLM Reasoning Model'; External = $true }
        vLLMVision      = @{ Port = 8202; Script = $null; Alias = @('Vision-vLLM'); Desc = 'vLLM Vision Model'; External = $true }
        vLLMCoding      = @{ Port = 8203; Script = $null; Alias = @('Coding-vLLM'); Desc = 'vLLM Coding Model'; External = $true }
    }
    
    # Resolve service name (handles aliases and wildcards)
    function Resolve-ServiceName {
        param([string]$ServiceName)
        
        if ([string]::IsNullOrWhiteSpace($ServiceName) -or $ServiceName -eq 'All' -or $ServiceName -eq '*') {
            return $AitherServices.Keys
        }
        
        if ($AitherServices.ContainsKey($ServiceName)) {
            return @($ServiceName)
        }
        
        foreach ($svc in $AitherServices.Keys) {
            if ($AitherServices[$svc].Alias -contains $ServiceName) {
                return @($svc)
            }
        }
        
        if ($ServiceName -match '\*|\?') {
            $matched = $AitherServices.Keys | Where-Object { $_ -like $ServiceName }
            if ($matched) { return $matched }
        }
        
        $partial = $AitherServices.Keys | Where-Object { $_ -like "*$ServiceName*" }
        if ($partial) { return $partial }
        
        Write-AitherLog -Level Warning -Message "Service '$ServiceName' not found. Available: $($AitherServices.Keys -join ', ')" -Source 'Get-AitherService'
        return @()
    }
    
    $services = Resolve-ServiceName -ServiceName $Name
    $results = @()
    
    foreach ($svcName in $services) {
        $def = $AitherServices[$svcName]
        $port = $def.Port
        
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        $isRunning = $null -ne $conn
        $pid = if ($isRunning) { $conn.OwningProcess } else { $null }
        
        $svcObj = [PSCustomObject]@{
            Name        = $svcName
            Port        = $port
            Status      = if ($isRunning) { 'Running' } else { 'Stopped' }
            PID         = $pid
            Script      = $def.Script
            Description = $def.Desc
            Aliases     = $def.Alias -join ', '
            External    = $def.External -eq $true
        }
        
        if ($Online -and -not $isRunning) { continue }
        if ($Offline -and $isRunning) { continue }
        
        $results += $svcObj
    }
    
    if ($PassThru) {
        return $results
    }
    
    if ($results.Count -eq 0) {
        Write-AitherLog -Level Warning -Message "No services found matching '$Name'" -Source 'Get-AitherService'
        return
    }
    
    Write-AitherLog -Level Information -Message "AitherOS Services" -Source 'Get-AitherService'
    Write-AitherLog -Level Information -Message ("=" * 70) -Source 'Get-AitherService'
    
    foreach ($svc in $results | Sort-Object Port) {
        $statusLevel = if ($svc.Status -eq 'Running') { 'Information' } else { 'Warning' }
        $statusIcon = if ($svc.Status -eq 'Running') { '●' } else { '○' }
        $pidInfo = if ($svc.PID) { " (PID: $($svc.PID))" } else { '' }
        
        $svcLine = "$statusIcon $($svc.Name.PadRight(18)) $($svc.Port.ToString().PadLeft(6))  $($svc.Status.PadRight(8)) $($svc.Description)$pidInfo"
        Write-AitherLog -Level $statusLevel -Message $svcLine -Source 'Get-AitherService'
    }
    
    $running = @($results | Where-Object Status -eq 'Running').Count
    $total = $results.Count
    $onlineLevel = if ($running -eq $total) { 'Information' } elseif ($running -gt 0) { 'Warning' } else { 'Error' }
    Write-AitherLog -Level $onlineLevel -Message "Online: $running/$total" -Source 'Get-AitherService'
    
    return $results
}
