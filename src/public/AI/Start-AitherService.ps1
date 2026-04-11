#Requires -Version 7.0

<#
.SYNOPSIS
    Start an AitherOS service.

.DESCRIPTION
    Starts the specified AitherOS service by invoking its start script.
    Supports waiting for startup confirmation.

.PARAMETER Name
    Service name or alias. Required.
    
    Available services and their aliases:
    - AitherNode (Node, MCP) - MCP Server
    - AitherCanvas (Canvas, Comfy, ComfyUI, ImageGen) - Image Generation
    - AitherReasoning (Reasoning, Traces) - Thinking Traces
    - AitherPulse (Pulse, Events) - Event Bus
    - AitherVeil (Veil, Dashboard, UI) - Dashboard
    - AitherPrism (Prism, Video) - Video Frame Extraction
    - AitherTrainer (Trainer, Training) - Model Training
    - vLLM Orchestrator (Orchestrator) - General LLM (Docker)
    - vLLM Reasoning (Reasoning-vLLM) - Deep reasoning LLM (Docker)
    - vLLM Vision (Vision-vLLM) - Multimodal LLM (Docker)
    - vLLM Coding (Coding-vLLM) - Code generation LLM (Docker)

.PARAMETER Port
    Override the default port for the service.

.PARAMETER ShowOutput
    Display startup progress and status.

.PARAMETER PassThru
    Return result object instead of display output.

.PARAMETER Wait
    Wait for service to fully start before returning.

.PARAMETER List
    Show all available services and their status.

.EXAMPLE
    Start-AitherService -Name Node
    # Starts AitherNode MCP server

.EXAMPLE
    Start-AitherService -Name Comfy -ShowOutput -Wait
    # Starts ComfyUI (AitherCanvas) and waits for it to be ready

.EXAMPLE
    Start-AitherService -List
    # Shows all available services and their current status

.NOTES
    Part of the AitherZero module.
#>
function Start-AitherService {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        
        [Parameter()]
        [int]$Port,
        
        [Parameter()]
        [switch]$ShowOutput,
        
        [Parameter()]
        [switch]$PassThru,
        
        [Parameter()]
        [switch]$Wait
    )
    
    # Service definitions
    $AitherServices = @{
        AitherNode      = @{ Port = 8080; Script = '0762'; Alias = @('Node', 'MCP'); Desc = 'MCP Server' }
        AitherReasoning = @{ Port = 8093; Script = '0764'; Alias = @('Reasoning', 'Traces'); Desc = 'Thinking Traces' }
        AitherPulse     = @{ Port = 8081; Script = '0765'; Alias = @('Pulse', 'Events'); Desc = 'Event Bus' }
        AitherCanvas    = @{ Port = 8188; Script = '0734'; Alias = @('Canvas', 'Comfy', 'ImageGen'); Desc = 'Image Generation' }
        AitherVeil      = @{ Port = 3000; Script = '0766'; Alias = @('Veil', 'Dashboard', 'UI'); Desc = 'Dashboard' }
        AitherPrism     = @{ Port = 8106; Script = '0780'; Alias = @('Prism', 'Video'); Desc = 'Video Extraction' }
        AitherTrainer   = @{ Port = 8107; Script = '0779'; Alias = @('Trainer', 'Training'); Desc = 'Model Training' }
        vLLMOrchestrator = @{ Port = 8200; Script = $null; Alias = @('Orchestrator', 'LLM'); External = $true; Desc = 'vLLM Orchestrator (Docker)' }
        vLLMReasoning   = @{ Port = 8201; Script = $null; Alias = @('Reasoning-vLLM'); External = $true; Desc = 'vLLM Reasoning (Docker)' }
        vLLMVision      = @{ Port = 8202; Script = $null; Alias = @('Vision-vLLM'); External = $true; Desc = 'vLLM Vision (Docker)' }
        vLLMCoding      = @{ Port = 8203; Script = $null; Alias = @('Coding-vLLM'); External = $true; Desc = 'vLLM Coding (Docker)' }
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
        Write-AitherLog -Level Warning -Message "Service '$Name' not found. Available: $($AitherServices.Keys -join ', ')" -Source 'Start-AitherService'
        return
    }
    
    $def = $AitherServices[$svcName]
    $svcPort = if ($Port) { $Port } else { $def.Port }
    
    # Check if already running
    $conn = Get-NetTCPConnection -LocalPort $svcPort -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        if ($ShowOutput) { Write-AitherLog -Level Information -Message "✓ $svcName already running on port $svcPort (PID: $($conn.OwningProcess))" -Source 'Start-AitherService' }
        $result = [PSCustomObject]@{ Name = $svcName; Status = 'AlreadyRunning'; Port = $svcPort; PID = $conn.OwningProcess }
        if ($PassThru) { return $result }
        return
    }
    
    # External services
    if ($def.External) {
        Write-AitherLog -Level Warning -Message "$svcName is an external service. Start it manually." -Source 'Start-AitherService'
        return
    }
    
    if (-not $def.Script) {
        Write-AitherLog -Level Warning -Message "$svcName has no start script defined." -Source 'Start-AitherService'
        return
    }
    
    if ($PSCmdlet.ShouldProcess($svcName, "Start service on port $svcPort")) {
        $scriptPath = Get-AitherScriptsPath
        $startScript = Get-ChildItem -Path $scriptPath -Filter "$($def.Script)*.ps1" | Select-Object -First 1
        
        if (-not $startScript) {
            Write-AitherLog -Level Warning -Message "Start script $($def.Script) not found for $svcName" -Source 'Start-AitherService'
            return
        }
        
        if ($ShowOutput) { Write-AitherLog -Level Information -Message "▶ Starting $svcName on port $svcPort..." -Source 'Start-AitherService' }
        
        # Start in background
        $params = @('-NoProfile', '-File', $startScript.FullName)
        if ($ShowOutput) { $params += '-ShowOutput' }
        if ($Port) { $params += @('-Port', $svcPort) }
        
        Start-Process pwsh -ArgumentList $params -WindowStyle Hidden
        
        if ($Wait) {
            $maxWait = 15
            for ($i = 0; $i -lt $maxWait; $i++) {
                Start-Sleep -Seconds 1
                $check = Get-NetTCPConnection -LocalPort $svcPort -State Listen -ErrorAction SilentlyContinue
                if ($check) {
                    if ($ShowOutput) { Write-AitherLog -Level Information -Message "✓ $svcName started (PID: $($check.OwningProcess))" -Source 'Start-AitherService' }
                    $result = [PSCustomObject]@{ Name = $svcName; Status = 'Started'; Port = $svcPort; PID = $check.OwningProcess }
                    if ($PassThru) { return $result }
                    return
                }
            }
            Write-AitherLog -Level Warning -Message "$svcName may not have started. Check logs." -Source 'Start-AitherService'
            $result = [PSCustomObject]@{ Name = $svcName; Status = 'Timeout'; Port = $svcPort; PID = $null }
            if ($PassThru) { return $result }
        } else {
            if ($ShowOutput) { Write-AitherLog -Level Information -Message "→ $svcName starting in background" -Source 'Start-AitherService' }
            $result = [PSCustomObject]@{ Name = $svcName; Status = 'Starting'; Port = $svcPort; PID = $null }
            if ($PassThru) { return $result }
        }
    }
}
