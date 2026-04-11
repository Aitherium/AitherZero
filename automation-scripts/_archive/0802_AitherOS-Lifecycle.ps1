#Requires -Version 7.0
<#
.SYNOPSIS
    AitherOS Service Lifecycle Manager - Unified start/stop/restart/status.

.DESCRIPTION
    Single cohesive script for all AitherOS lifecycle operations.
    Reads service definitions from services.yaml (single source of truth).
    
    Features:
    - Dependency-ordered startup (respects depends_on in services.yaml)
    - Graceful shutdown with reverse dependency order
    - Health check validation after startup
    - Real-time status dashboard
    - Restart with configurable delay

.PARAMETER Action
    The lifecycle action: Start, Stop, Restart, Status

.PARAMETER Services
    Service group or comma-separated list: All, Full, Core, Minimal, GPU, MCP, Mesh

.PARAMETER WaitForHealthy
    Wait for services to pass health checks after starting

.PARAMETER TimeoutSeconds
    Timeout for health check wait (default: 60)

.PARAMETER Force
    Force kill processes on stop

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    ./0802_AitherOS-Lifecycle.ps1 -Action Start -Services Core -ShowOutput
    Start core services with output

.EXAMPLE
    ./0802_AitherOS-Lifecycle.ps1 -Action Status
    Show status of all services

.EXAMPLE
    ./0802_AitherOS-Lifecycle.ps1 -Action Restart -Services Mesh -WaitForHealthy
    Restart mesh services and wait for health checks

.NOTES
    Stage: AI Tools
    Order: 0802
    Tags: aitheros, lifecycle, services, orchestration
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Stop', 'Restart', 'Status')]
    [string]$Action,
    
    [ValidateSet('All', 'Full', 'Core', 'Canvas', 'Minimal', 'MCP', 'GPU', 'Mesh')]
    [string]$Services = 'Core',
    
    [switch]$WaitForHealthy,
    [int]$TimeoutSeconds = 60,
    [switch]$Force,
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/_init.ps1"

# ============================================================================
# CONFIGURATION
# ============================================================================
$AitherNodePath = Join-Path $projectRoot "AitherOS/AitherNode"
$VenvScripts = Join-Path $projectRoot "AitherOS/agents/NarrativeAgent/.venv/Scripts"
$PythonExe = Join-Path $VenvScripts "python.exe"
$ServicesYaml = Join-Path $projectRoot "AitherOS/config/services.yaml"
$AitherVeilPath = Join-Path $projectRoot "AitherOS/AitherVeil"

# ComfyUI locations
$ComfyPaths = @("D:\ComfyUI", "D:\ComfyUI", "C:\ComfyUI", "$env:USERPROFILE\ComfyUI")
$ComfyUIPath = $ComfyPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

# ============================================================================
# LOAD SERVICE DEFINITIONS FROM services.yaml
# ============================================================================
function Get-ServiceDefinitions {
    if (-not (Test-Path $ServicesYaml)) {
        Write-Error "services.yaml not found at $ServicesYaml"
        exit 1
    }
    
    # Use Python to parse YAML (PowerShell doesn't have native YAML support)
    $yamlContent = & $PythonExe -c @"
import yaml
import json
with open(r'$ServicesYaml', 'r') as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
"@
    
    return $yamlContent | ConvertFrom-Json
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
function Write-Log {
    param([string]$Name, [string]$Msg, [string]$Level = "Info")
    if (-not $ShowOutput) { return }
    $icon = switch ($Level) { 
        "OK" { "✔" } 
        "Err" { "❌—" } 
        "Warn" { "âš " } 
        "Wait" { "â—Œ" }
        default { "â—‹" } 
    }
    $color = switch ($Level) { 
        "OK" { "Green" } 
        "Err" { "Red" } 
        "Warn" { "Yellow" }
        "Wait" { "DarkGray" }
        default { "Cyan" } 
    }
    Write-Host "[$Name] $icon $Msg" -ForegroundColor $color
}

function Test-Port([int]$Port) {
    $null -ne (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Test-ServiceHealth([string]$Name, [int]$Port) {
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        # Fall back to port check
        return (Test-Port $Port)
    }
}

function Stop-ServiceByPort([int]$Port, [string]$Name) {
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) { return $false }
    
    foreach ($conn in $conns) {
        $p = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($p -and $p.Id -ne 0) {
            Write-Log $Name "Stopping PID:$($p.Id)"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
    return $true
}

function Get-DependencyOrder {
    param([hashtable]$AllServices, [string[]]$ToStart)
    
    # Build dependency graph and topological sort
    $ordered = [System.Collections.ArrayList]::new()
    $visited = @{}
    $visiting = @{}
    
    function Visit($name) {
        if ($visiting[$name]) {
            Write-Warning "Circular dependency detected: $name"
            return
        }
        if ($visited[$name]) { return }
        
        $visiting[$name] = $true
        $svc = $AllServices[$name]
        if ($svc -and $svc.depends_on) {
            foreach ($dep in $svc.depends_on) {
                if ($ToStart -contains $dep) {
                    Visit $dep
                }
            }
        }
        $visiting[$name] = $false
        $visited[$name] = $true
        [void]$ordered.Add($name)
    }
    
    foreach ($name in $ToStart) {
        Visit $name
    }
    
    return $ordered
}

# ============================================================================
# START FUNCTIONS
# ============================================================================
function Start-ComfyUI {
    if (Test-Port 8188) {
        Write-Log "Canvas" "Already running :8188" "Warn"
        return $true
    }
    if (-not $ComfyUIPath) {
        Write-Log "Canvas" "ComfyUI not found" "Err"
        return $false
    }
    $comfyPy = Join-Path $ComfyUIPath "venv\Scripts\python.exe"
    $mainPy = Join-Path $ComfyUIPath "main.py"
    if (-not (Test-Path $comfyPy)) {
        Write-Log "Canvas" "ComfyUI venv missing" "Err"
        return $false
    }
    Write-Log "Canvas" "Starting :8188..."
    $cmd = "/c cd /d `"$ComfyUIPath`" && `"$comfyPy`" `"$mainPy`" --listen 0.0.0.0 --port 8188 --enable-cors-header"
    Start-Process -FilePath "cmd.exe" -ArgumentList $cmd -WindowStyle Hidden
    Write-Log "Canvas" "Started (loading ~30s)" "OK"
    return $true
}

function Start-Ollama {
    if (Test-Port 11434) {
        Write-Log "Spirit" "Already running :11434" "OK"
        return $true
    }
    $ollama = Get-Command "ollama" -ErrorAction SilentlyContinue
    if (-not $ollama) {
        Write-Log "Spirit" "Ollama not installed" "Warn"
        return $false
    }
    Write-Log "Spirit" "Starting :11434..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Write-Log "Spirit" "Started" "OK"
    return $true
}

function Start-AitherVeil {
    if (Test-Port 3000) {
        Write-Log "Veil" "Already running :3000" "Warn"
        return $true
    }
    if (-not (Test-Path $AitherVeilPath)) {
        Write-Log "Veil" "AitherVeil not found" "Err"
        return $false
    }
    $npm = Get-Command "npm" -ErrorAction SilentlyContinue
    if (-not $npm) {
        Write-Log "Veil" "npm not installed" "Err"
        return $false
    }
    Write-Log "Veil" "Starting :3000..."
    $cmd = "/c cd /d `"$AitherVeilPath`" && npm start"
    Start-Process -FilePath "cmd.exe" -ArgumentList $cmd -WindowStyle Hidden
    Write-Log "Veil" "Started" "OK"
    return $true
}

function Start-PythonService {
    param([string]$Name, [int]$Port, [string]$Module)
    
    if (Test-Port $Port) {
        Write-Log $Name "Already running :$Port" "Warn"
        return $true
    }
    if (-not (Test-Path $PythonExe)) {
        Write-Log $Name "Python venv missing" "Err"
        return $false
    }
    
    $args = "-m uvicorn ${Module}:app --host 0.0.0.0 --port $Port"
    Write-Log $Name "Starting :$Port..."
    
    $env:PYTHONUNBUFFERED = "1"
    $env:AITHERZERO_ROOT = $projectRoot
    $env:PYTHONPATH = $AitherNodePath
    
    try {
        $proc = Start-Process -FilePath $PythonExe -ArgumentList $args -WorkingDirectory $AitherNodePath -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 300
        if ($proc.HasExited) {
            Write-Log $Name "Died immediately" "Err"
            return $false
        }
        Write-Log $Name "Started PID:$($proc.Id)" "OK"
        return $true
    } catch {
        Write-Log $Name "Failed: $_" "Err"
        return $false
    }
}

# ============================================================================
# MAIN ACTIONS
# ============================================================================
function Invoke-Start {
    param([object]$Config, [string[]]$ServiceList)
    
    $allServices = @{}
    foreach ($prop in $Config.services.PSObject.Properties) {
        $allServices[$prop.Name] = $prop.Value
    }
    
    # Get dependency-ordered list
    $ordered = Get-DependencyOrder -AllServices $allServices -ToStart $ServiceList
    
    if ($ShowOutput) {
        Write-Host ""
        Write-Host "═”═══════════════════════════════════════════════════════════════════—" -ForegroundColor Magenta
        Write-Host "═‘                    AITHEROS STARTUP                              ═‘" -ForegroundColor Magenta
        Write-Host "═š═══════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
        Write-Host ""
        Write-Host "Starting $($ordered.Count) services (dependency order):" -ForegroundColor Cyan
        Write-Host "  $($ordered -join ' â†’ ')" -ForegroundColor DarkGray
        Write-Host ""
    }
    
    $started = 0
    $failed = 0
    
    foreach ($name in $ordered) {
        $svc = $allServices[$name]
        if (-not $svc) { continue }
        
        $port = $svc.port
        $type = $svc.type
        $module = $svc.module
        
        $ok = switch ($type) {
            "comfyui" { Start-ComfyUI }
            "ollama"  { Start-Ollama }
            "nextjs"  { Start-AitherVeil }
            default   { 
                if ($module) {
                    Start-PythonService -Name $name -Port $port -Module $module
                } else {
                    Write-Log $name "No module defined" "Warn"
                    $false
                }
            }
        }
        
        if ($ok) { $started++ } else { $failed++ }
        Start-Sleep -Milliseconds 100
    }
    
    # Wait for healthy if requested
    if ($WaitForHealthy) {
        if ($ShowOutput) {
            Write-Host ""
            Write-Host "Waiting for services to become healthy..." -ForegroundColor Cyan
        }
        
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $allHealthy = $false
        
        while ((Get-Date) -lt $deadline) {
            $healthy = 0
            foreach ($name in $ordered) {
                $svc = $allServices[$name]
                if ($svc -and (Test-ServiceHealth -Name $name -Port $svc.port)) {
                    $healthy++
                }
            }
            
            if ($healthy -eq $ordered.Count) {
                $allHealthy = $true
                break
            }
            
            Start-Sleep -Seconds 2
        }
        
        if (-not $allHealthy -and $ShowOutput) {
            Write-Host "  âš  Some services didn't become healthy in time" -ForegroundColor Yellow
        }
    }
    
    # Final status
    $online = @()
    $offline = @()
    
    foreach ($name in $ordered) {
        $svc = $allServices[$name]
        if (-not $svc) { continue }
        if (Test-Port $svc.port) {
            $online += "${name}:$($svc.port)"
        } else {
            $offline += $name
        }
    }
    
    if ($ShowOutput) {
        Write-Host ""
        Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        if ($offline.Count -eq 0) {
            Write-Host "  ✔ All $($online.Count) services online!" -ForegroundColor Green
        } else {
            Write-Host "  Online: $($online.Count) | Offline: $($offline.Count)" -ForegroundColor Yellow
            Write-Host "  Offline: $($offline -join ', ')" -ForegroundColor Red
        }
        Write-Host ""
    }
    
    return @{ Started = $started; Failed = $failed; Online = $online; Offline = $offline }
}

function Invoke-Stop {
    param([object]$Config, [string[]]$ServiceList)
    
    $allServices = @{}
    foreach ($prop in $Config.services.PSObject.Properties) {
        $allServices[$prop.Name] = $prop.Value
    }
    
    # Reverse dependency order for shutdown
    $ordered = Get-DependencyOrder -AllServices $allServices -ToStart $ServiceList
    [array]::Reverse($ordered)
    
    if ($ShowOutput) {
        Write-Host ""
        Write-Host "═”═══════════════════════════════════════════════════════════════════—" -ForegroundColor Red
        Write-Host "═‘                    AITHEROS SHUTDOWN                             ═‘" -ForegroundColor Red
        Write-Host "═š═══════════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
    }
    
    $stopped = 0
    
    foreach ($name in $ordered) {
        $svc = $allServices[$name]
        if (-not $svc) { continue }
        
        if (Stop-ServiceByPort -Port $svc.port -Name $name) {
            Write-Log $name "Stopped" "OK"
            $stopped++
        } else {
            Write-Log $name "Not running" "Warn"
        }
    }
    
    # Force cleanup
    if ($Force) {
        if ($ShowOutput) { Write-Host "`nCleaning up lingering processes..." -ForegroundColor Yellow }
        
        Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match "Aither|uvicorn|server.py|mcp_.*_server" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        
        Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match "ComfyUI|AitherVeil|npm" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        
        Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match "AitherVeil|next" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    
    if ($ShowOutput) {
        Write-Host ""
        Write-Host "  Stopped $stopped service(s)" -ForegroundColor Green
        Write-Host ""
    }
    
    return @{ Stopped = $stopped }
}

function Invoke-Status {
    param([object]$Config)
    
    Write-Host ""
    Write-Host "═”═══════════════════════════════════════════════════════════════════—" -ForegroundColor Cyan
    Write-Host "═‘                    AITHEROS STATUS                               ═‘" -ForegroundColor Cyan
    Write-Host "═š═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    $online = 0
    $offline = 0
    $results = @()
    
    foreach ($prop in $Config.services.PSObject.Properties) {
        $name = $prop.Name
        $svc = $prop.Value
        $port = $svc.port
        
        $running = Test-Port $port
        $healthy = if ($running) { Test-ServiceHealth -Name $name -Port $port } else { $false }
        
        $status = if ($running -and $healthy) { "â— Online" }
                  elseif ($running) { "â— Running" }
                  else { "â—‹ Offline" }
        
        $color = if ($running -and $healthy) { "Green" }
                 elseif ($running) { "Yellow" }
                 else { "DarkGray" }
        
        $results += [PSCustomObject]@{
            Service = $name
            Port = $port
            Status = $status
            Group = $svc.group
        }
        
        if ($running) { $online++ } else { $offline++ }
    }
    
    # Display by group
    $groups = $results | Group-Object Group
    foreach ($group in $groups) {
        Write-Host "  $($group.Name.ToUpper())" -ForegroundColor White
        foreach ($svc in $group.Group) {
            $color = if ($svc.Status -match "Online") { "Green" }
                     elseif ($svc.Status -match "Running") { "Yellow" }
                     else { "DarkGray" }
            Write-Host "    $($svc.Status) $($svc.Service) :$($svc.Port)" -ForegroundColor $color
        }
        Write-Host ""
    }
    
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host "  Total: $($online + $offline) | Online: $online | Offline: $offline" -ForegroundColor Cyan
    Write-Host ""
    
    return @{ Online = $online; Offline = $offline; Results = $results }
}

# ============================================================================
# MAIN
# ============================================================================

# Validate prerequisites
if (-not (Test-Path $PythonExe)) {
    Write-Error "Python venv not found. Run: ./AitherZero/library/automation-scripts/0761_Setup-AitherNode.ps1"
    exit 1
}

# Load configuration
$config = Get-ServiceDefinitions

# Resolve service group to list
$serviceList = switch ($Services) {
    'All'     { $config.services.PSObject.Properties.Name }
    'Full'    { $config.groups.full.services }
    'Core'    { $config.groups.core.services }
    'Minimal' { $config.groups.minimal.services }
    'GPU'     { $config.groups.gpu.services }
    'MCP'     { $config.groups.mcp.services }
    'Mesh'    { $config.groups.mesh.services }
    'Canvas'  { @('Canvas') }
}

# Handle ALL placeholder
if ($serviceList -contains 'ALL') {
    $serviceList = $config.services.PSObject.Properties.Name
}

# Execute action
switch ($Action) {
    'Start' {
        Invoke-Start -Config $config -ServiceList $serviceList
    }
    'Stop' {
        Invoke-Stop -Config $config -ServiceList $serviceList
    }
    'Restart' {
        Invoke-Stop -Config $config -ServiceList $serviceList
        Start-Sleep -Seconds 3
        Invoke-Start -Config $config -ServiceList $serviceList
    }
    'Status' {
        Invoke-Status -Config $config
    }
}


