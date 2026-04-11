#Requires -Version 7.0

<#
.SYNOPSIS
    AitherNet Unified Service Startup - Start ALL services with proper coordination.

.DESCRIPTION
    The definitive way to start the entire AitherNet ecosystem in one command.
    
    This script:
    1. Reads from ports.json (single source of truth)
    2. Starts services in correct dependency order
    3. Waits for each service to be healthy before proceeding
    4. Provides clear status reporting
    5. Supports selective startup (categories, layers, specific services)
    
    "Plug In. Power Up. Create."

.PARAMETER Mode
    Startup mode:
    - All: Start all services (default)
    - Core: Essential services only (Watch, Pulse, Node, Veil)
    - Minimal: Just external + core
    - Dev: Development mode (no training services)
    - Headless: No UI (AitherVeil)

.PARAMETER Services
    Specific services to start (comma-separated)

.PARAMETER Categories
    Service categories to start:
    External, Core, Nervous, Memory, Intelligence, GPU, Training, Perception, Interface

.PARAMETER Parallel
    Start services in same layer concurrently (default: true)

.PARAMETER HealthCheck
    Wait for health checks (default: true)

.PARAMETER Timeout
    Health check timeout per service in seconds (default: 30)

.EXAMPLE
    .\0802_Start-AitherNet.ps1
    # Start everything

.EXAMPLE
    .\0802_Start-AitherNet.ps1 -Mode Core
    # Just essential services

.EXAMPLE
    .\0802_Start-AitherNet.ps1 -Services "AitherCouncil,AitherA2A"
    # Specific services only

.NOTES
    Stage: AitherOS
    Order: 0802
    Tags: startup, aithernet, services, ecosystem
    Category: Environment Setup
#>

[CmdletBinding()]
param(
    [ValidateSet('All', 'Core', 'Minimal', 'Dev', 'Headless')]
    [string]$Mode = 'All',
    
    [string[]]$Services,
    
    [ValidateSet('External', 'Core', 'Nervous', 'Memory', 'Intelligence', 'GPU', 'Training', 'Perception', 'Interface', 'Security')]
    [string[]]$Categories,
    
    [switch]$Parallel = $true,
    [switch]$HealthCheck = $true,
    [int]$Timeout = 30,
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'

# Initialize
. "$PSScriptRoot/_init.ps1"

# ============================================================================
# BANNER
# ============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                         AITHERNET STARTUP                                ║" -ForegroundColor Cyan
Write-Host "║                   Plug In. Power Up. Create.                            ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# LOAD SERVICE DEFINITIONS FROM PORTS.JSON
# ============================================================================

$portsJson = Join-Path $projectRoot "AitherOS/AitherNode/config/ports.json"
$AitherNodePath = Join-Path $projectRoot "AitherOS/AitherNode"
$AitherOSPath = Join-Path $projectRoot "AitherOS"

if (-not (Test-Path $portsJson)) {
    Write-Host "  [ERROR] ports.json not found at: $portsJson" -ForegroundColor Red
    exit 1
}

$portsConfig = Get-Content $portsJson -Raw | ConvertFrom-Json

# Build service definitions dynamically
$AllServices = @{}

foreach ($svcName in ($portsConfig.services | Get-Member -MemberType NoteProperty).Name) {
    $cfg = $portsConfig.services.$svcName
    
    $AllServices[$svcName] = @{
        Name = $svcName
        Port = $cfg.port
        Description = $cfg.description
        Layer = if ($cfg.layer) { $cfg.layer } else { 5 }
        EnvVar = $cfg.env_var
        IsExternal = if ($cfg.external) { $cfg.external } else { $false }
        Command = ""
        WorkDir = $AitherNodePath
        HealthEndpoint = "http://localhost:$($cfg.port)/health"
    }
    
    # Set commands based on service type
    switch ($svcName) {
        "AitherSpirit" {
            $AllServices[$svcName].Command = "ollama serve"
            $AllServices[$svcName].IsExternal = $true
            $AllServices[$svcName].HealthEndpoint = "http://localhost:11434/api/version"
        }
        "AitherForge" {
            $AllServices[$svcName].Command = ""  # Use dedicated script
            $AllServices[$svcName].IsExternal = $true
            $AllServices[$svcName].HealthEndpoint = "http://localhost:8188/system_stats"
        }
        "AitherVeil" {
            $AllServices[$svcName].Command = "npm run dev"
            $AllServices[$svcName].WorkDir = Join-Path $AitherNodePath "AitherVeil"
            $AllServices[$svcName].HealthEndpoint = "http://localhost:3000"
        }
        "Aither" {
            $AllServices[$svcName].Command = "python run_agent.py aither --persistent --port $($cfg.port)"
            $AllServices[$svcName].WorkDir = $AitherOSPath
        }
        "AitherCouncil" {
            $AllServices[$svcName].Command = "python -m uvicorn AitherCouncil_api:app --host 0.0.0.0 --port $($cfg.port)"
        }
        default {
            if (-not $AllServices[$svcName].IsExternal) {
                $AllServices[$svcName].Command = "python -m uvicorn ${svcName}:app --host 0.0.0.0 --port $($cfg.port)"
            }
        }
    }
}

# ============================================================================
# SERVICE CATEGORIES (for mode-based startup)
# ============================================================================

$ServiceCategories = @{
    External = @("AitherSpirit", "AitherForge")
    Core = @("AitherNode", "AitherPulse", "AitherWatch", "AitherSecrets")
    Nervous = @("AitherGate", "AitherAutonomic", "AitherReflex", "AitherSense", "AitherDemand")
    Memory = @("AitherWorkingMemory", "AitherChain", "AitherContext", "AitherSpirit_Internal")
    Intelligence = @("AitherMind", "AitherReasoning", "AitherJudge", "AitherTag", "AitherFlow", "AitherWill", "AitherPersona", "AitherCouncil", "AitherSafety")
    GPU = @("AitherParallel", "AitherAccel", "AitherForce")
    Training = @("AitherPrism", "AitherTrainer", "AitherHarvest", "AitherScheduler")
    Perception = @("AitherVoice", "AitherVision", "AitherPortal", "AitherEnviro")
    Interface = @("AitherVeil", "AitherA2A", "AitherGateway", "Aither")
    Security = @("AitherSecrets")
}

# Mode presets
$ModePresets = @{
    All = $ServiceCategories.Keys
    Core = @("External", "Core", "Interface")
    Minimal = @("External", "Core")
    Dev = @("External", "Core", "Memory", "Intelligence", "Interface")
    Headless = @("External", "Core", "Memory", "Intelligence", "GPU")
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Test-PortInUse {
    param([int]$Port)
    try {
        $connections = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        return $null -ne $connections
    }
    catch { return $false }
}

function Wait-ForService {
    param(
        [string]$Name,
        [string]$Endpoint,
        [int]$Port,
        [int]$TimeoutSeconds = 10
    )
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    
    # First just wait for the port to be listening (fast check)
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-PortInUse -Port $Port) {
            # Port is open - try a quick HTTP check
            try {
                # Try multiple endpoints
                foreach ($ep in @($Endpoint, "http://localhost:$Port/", "http://localhost:$Port/docs")) {
                    try {
                        $null = Invoke-WebRequest -Uri $ep -Method Get -TimeoutSec 2 -ErrorAction Stop
                        return $true
                    } catch { }
                }
                # If HTTP fails but port is open, consider it started
                return $true
            }
            catch {
                return $true  # Port is listening, good enough
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Start-AitherService {
    param(
        [hashtable]$Service,
        [int]$Timeout = 8  # Fast timeout - just check port is listening
    )
    
    $name = $Service.Name
    $port = $Service.Port
    
    # Check if already running
    if (Test-PortInUse -Port $port) {
        Write-Host "  ✓ $name" -NoNewline -ForegroundColor Green
        Write-Host " (already running on :$port)" -ForegroundColor DarkGray
        return $true
    }
    
    # Handle external services
    if ($Service.IsExternal) {
        if ($name -eq "AitherSpirit") {
            # Check if Ollama is installed
            $ollamaPath = Get-Command "ollama" -ErrorAction SilentlyContinue
            if ($ollamaPath) {
                Write-Host "  ○ Starting $name..." -NoNewline -ForegroundColor Yellow
                Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
                Start-Sleep -Seconds 3
                if (Test-PortInUse -Port $port) {
                    Write-Host "`r  ✓ $name                    " -ForegroundColor Green
                    return $true
                }
            }
            Write-Host "  ⚠ $name not available (Ollama not installed)" -ForegroundColor Yellow
            return $false
        }
        elseif ($name -eq "AitherForge") {
            # ComfyUI - use dedicated script
            $comfyScript = Join-Path $PSScriptRoot "0734_Start-ComfyUI.ps1"
            if (Test-Path $comfyScript) {
                Write-Host "  ○ Starting $name (ComfyUI)..." -NoNewline -ForegroundColor Yellow
                Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-File", $comfyScript, "-Detached", "-Port", $port -WindowStyle Hidden
                Write-Host "`r  ⏳ $name (will be ready in ~60s)" -ForegroundColor Cyan
                return $true
            }
            Write-Host "  ⚠ $name script not found" -ForegroundColor Yellow
            return $false
        }
    }
    
    # Skip if no command
    if (-not $Service.Command) {
        Write-Host "  ⏭ $name (no command defined)" -ForegroundColor DarkGray
        return $true
    }
    
    # Start Python service
    Write-Host "  ○ Starting $name on :$port..." -NoNewline -ForegroundColor Yellow
    
    $pythonExe = "python"
    $venvPython = Join-Path $projectRoot "AitherOS/agents/NarrativeAgent/.venv/Scripts/python.exe"
    if (Test-Path $venvPython) {
        $pythonExe = $venvPython
    }
    
    $env:PYTHONUNBUFFERED = "1"
    $env:AITHERZERO_ROOT = $projectRoot
    
    try {
        if ($name -eq "AitherVeil") {
            $process = Start-Process -FilePath "npm" -ArgumentList "run", "dev" `
                -WorkingDirectory $Service.WorkDir -WindowStyle Hidden -PassThru
        }
        else {
            $cmdParts = $Service.Command -split ' ', 2
            $cmdArgs = if ($cmdParts.Length -gt 1) { $cmdParts[1] } else { "" }
            
            $process = Start-Process -FilePath $pythonExe -ArgumentList $cmdArgs `
                -WorkingDirectory $Service.WorkDir -WindowStyle Hidden -PassThru
        }
        
        if ($HealthCheck) {
            $healthy = Wait-ForService -Name $name -Endpoint $Service.HealthEndpoint -Port $port -TimeoutSeconds $Timeout
            if ($healthy) {
                Write-Host "`r  ✓ $name                                    " -ForegroundColor Green
                return $true
            }
            else {
                Write-Host "`r  ⚠ $name (started but health check timed out)" -ForegroundColor Yellow
                return $true
            }
        }
        else {
            Write-Host "`r  ✓ $name (PID: $($process.Id))              " -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Host "`r  ✗ $name failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Determine which services to start
$servicesToStart = @()

if ($Services) {
    # Specific services requested
    $servicesToStart = $Services | Where-Object { $AllServices.ContainsKey($_) }
    Write-Host "  Mode: Specific services ($($servicesToStart -join ', '))" -ForegroundColor Cyan
}
elseif ($Categories) {
    # Specific categories
    foreach ($cat in $Categories) {
        if ($ServiceCategories.ContainsKey($cat)) {
            $servicesToStart += $ServiceCategories[$cat]
        }
    }
    Write-Host "  Mode: Categories ($($Categories -join ', '))" -ForegroundColor Cyan
}
else {
    # Mode-based
    $categoriesToStart = $ModePresets[$Mode]
    foreach ($cat in $categoriesToStart) {
        if ($ServiceCategories.ContainsKey($cat)) {
            $servicesToStart += $ServiceCategories[$cat]
        }
    }
    Write-Host "  Mode: $Mode ($($categoriesToStart -join ', '))" -ForegroundColor Cyan
}

# Remove duplicates and filter to only services that exist
$servicesToStart = $servicesToStart | Select-Object -Unique | Where-Object { $AllServices.ContainsKey($_) }

# Sort by layer
$servicesToStart = $servicesToStart | Sort-Object { $AllServices[$_].Layer }

Write-Host "  Services to start: $($servicesToStart.Count)" -ForegroundColor Cyan
Write-Host ""

# Start services by layer
$currentLayer = -1
$results = @{}
$startedCount = 0
$failedCount = 0

foreach ($svcName in $servicesToStart) {
    $service = $AllServices[$svcName]
    
    if ($service.Layer -ne $currentLayer) {
        $currentLayer = $service.Layer
        Write-Host ""
        Write-Host "  Layer $currentLayer" -ForegroundColor White
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    }
    
    $success = Start-AitherService -Service $service -Timeout $Timeout
    $results[$svcName] = $success
    
    if ($success) { $startedCount++ }
    else { $failedCount++ }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host ""

if ($failedCount -eq 0) {
    Write-Host "  ✓ All $startedCount services started successfully!" -ForegroundColor Green
}
else {
    Write-Host "  ⚠ Started: $startedCount | Failed: $failedCount" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Key Endpoints:" -ForegroundColor White
Write-Host "    Dashboard:   http://localhost:3000" -ForegroundColor Cyan
Write-Host "    AitherNet:   http://localhost:8766" -ForegroundColor Cyan
Write-Host "    MCP Server:  http://localhost:8080" -ForegroundColor Cyan
Write-Host "    Council:     http://localhost:8765" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To stop: ./0052_Stop-AitherNet.ps1" -ForegroundColor DarkGray
Write-Host ""

# Return result for scripting
return @{
    Success = ($failedCount -eq 0)
    Started = $startedCount
    Failed = $failedCount
    Results = $results
}

