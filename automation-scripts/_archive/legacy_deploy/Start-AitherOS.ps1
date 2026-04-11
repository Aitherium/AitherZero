#Requires -Version 7.0
<#
.SYNOPSIS
    AitherOS Deployment - Reads services directly from services.yaml
.DESCRIPTION
    Simple, clean deployment system for AitherOS services.
    NO NSSM. NO Windows Services. Just Python processes managed cleanly.
    Reads ALL service definitions from AitherOS/config/services.yaml
.EXAMPLE
    ./Start-AitherOS.ps1                    # Start minimal profile
    ./Start-AitherOS.ps1 -Profile standard  # Start standard profile  
    ./Start-AitherOS.ps1 -Profile core      # Start core profile
    ./Start-AitherOS.ps1 -Services Node,LLM # Start specific services
    ./Start-AitherOS.ps1 -Stop              # Stop all services
    ./Start-AitherOS.ps1 -Status            # Show status
.NOTES
    Version: 2.0.0
#>

[CmdletBinding()]
param(
    [string]$Profile = 'full',
    [string[]]$Services,
    [switch]$Stop,
    [switch]$Restart,
    [switch]$Status,
    [switch]$Force,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$script:ROOT = Split-Path $PSScriptRoot -Parent
$script:CONFIG_PATH = Join-Path $PSScriptRoot 'config.json'
$script:PIDS_PATH = Join-Path $PSScriptRoot 'running.json'
$script:LOG_DIR = Join-Path $script:ROOT 'logs' 'aither'

# ============================================================================
# YAML PARSER (Simple - handles services.yaml structure)
# ============================================================================

function ConvertFrom-SimpleYaml {
    param([string]$Content)
    
    $result = @{
        settings = @{}
        groups = @{}
        services = @{}
        models = @{}
    }
    
    $currentSection = $null
    $currentItem = $null
    $currentItemName = $null
    $indent = 0
    
    foreach ($line in $Content -split "`n") {
        # Skip comments and empty lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        
        # Detect section headers (settings:, groups:, services:, models:)
        if ($line -match '^(settings|groups|services|models):') {
            $currentSection = $matches[1]
            $currentItem = $null
            continue
        }
        
        if (-not $currentSection) { continue }
        
        # Detect service/group name (2-space indent, ends with :)
        if ($line -match '^  ([A-Za-z0-9_]+):$') {
            $currentItemName = $matches[1]
            $currentItem = @{}
            $result[$currentSection][$currentItemName] = $currentItem
            continue
        }
        
        # Parse key-value pairs (4-space indent)
        if ($line -match '^    ([a-z_]+):\s*(.*)$' -and $currentItem) {
            $key = $matches[1]
            $value = $matches[2].Trim()
            
            # Handle different value types
            if ($value -match '^\[(.+)\]$') {
                # Array like [item1, item2]
                $currentItem[$key] = $matches[1] -split ',\s*' | ForEach-Object { $_.Trim() }
            } elseif ($value -match '^(\d+)$') {
                # Integer
                $currentItem[$key] = [int]$matches[1]
            } elseif ($value -eq 'true') {
                $currentItem[$key] = $true
            } elseif ($value -eq 'false') {
                $currentItem[$key] = $false
            } elseif ($value -match '^"(.+)"$') {
                $currentItem[$key] = $matches[1]
            } else {
                $currentItem[$key] = $value
            }
        }
    }
    
    return $result
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

function Get-DeployConfig {
    if (-not (Test-Path $script:CONFIG_PATH)) {
        throw "Config file not found: $script:CONFIG_PATH"
    }
    return Get-Content $script:CONFIG_PATH -Raw | ConvertFrom-Json -AsHashtable
}

function Get-ServicesYaml {
    $config = Get-DeployConfig
    $yamlPath = $config.paths.servicesYaml
    
    if (-not (Test-Path $yamlPath)) {
        throw "services.yaml not found: $yamlPath"
    }
    
    $content = Get-Content $yamlPath -Raw
    return ConvertFrom-SimpleYaml -Content $content
}

function Get-RunningServices {
    if (Test-Path $script:PIDS_PATH) {
        return Get-Content $script:PIDS_PATH -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{}
}

function Save-RunningServices {
    param([hashtable]$Services)
    $Services | ConvertTo-Json -Depth 5 | Set-Content $script:PIDS_PATH -Force
}

# ============================================================================
# UTILITIES
# ============================================================================

function Write-AitherLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $colors = @{ 'INFO' = 'Cyan'; 'WARN' = 'Yellow'; 'ERROR' = 'Red'; 'SUCCESS' = 'Green' }
    $icons = @{ 'INFO' = '○'; 'WARN' = '⚠'; 'ERROR' = '✗'; 'SUCCESS' = '✓' }
    
    $timestamp = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$timestamp] $($icons[$Level]) " -NoNewline
    Write-Host $Message -ForegroundColor $colors[$Level]
}

function Test-PortInUse {
    param([int]$Port)
    $null -ne (Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Stop-ProcessOnPort {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($conn) {
        $pid = $conn.OwningProcess | Select-Object -First 1
        if ($pid -and $pid -ne 0) {
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }
}

function Wait-ForPort {
    param([int]$Port, [int]$TimeoutSeconds = 60)
    $start = Get-Date
    while ((Get-Date) - $start -lt [TimeSpan]::FromSeconds($TimeoutSeconds)) {
        if (Test-PortInUse -Port $Port) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# ============================================================================
# SERVICE MANAGEMENT
# ============================================================================

function Start-AitherService {
    param(
        [string]$ServiceName,
        [hashtable]$ServiceConfig
    )
    
    $port = $ServiceConfig.port
    if (-not $port) {
        Write-AitherLog "$ServiceName has no port defined, skipping" -Level 'WARN'
        return @{ success = $false; reason = 'no_port' }
    }
    
    # Skip external services (ollama, comfyui)
    $type = $ServiceConfig.type
    if ($type -in @('ollama', 'comfyui')) {
        Write-AitherLog "$ServiceName is external ($type), checking availability..." -Level 'INFO'
        if (Test-PortInUse -Port $port) {
            Write-AitherLog "$ServiceName already running on port $port" -Level 'SUCCESS'
            return @{ success = $true; external = $true; port = $port }
        } else {
            Write-AitherLog "$ServiceName not running on port $port (start it externally)" -Level 'WARN'
            return @{ success = $false; reason = 'external_not_running' }
        }
    }
    
    # Check if port is already in use
    if (Test-PortInUse -Port $port) {
        if ($Force) {
            Write-AitherLog "Port $port in use, killing..." -Level 'WARN'
            Stop-ProcessOnPort -Port $port
        } else {
            Write-AitherLog "$ServiceName port $port already in use" -Level 'WARN'
            return @{ success = $true; port = $port; note = 'already_running' }
        }
    }
    
    # Ensure log directory
    if (-not (Test-Path $script:LOG_DIR)) {
        New-Item -ItemType Directory -Path $script:LOG_DIR -Force | Out-Null
    }
    
    # Get Python path
    $config = Get-DeployConfig
    $python = $config.python.executable
    if (-not (Test-Path $python)) {
        $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    }
    
    Write-AitherLog "Starting $ServiceName on port $port..." -Level 'INFO'
    
    $logFile = Join-Path $script:LOG_DIR "$ServiceName.log"
    $errFile = Join-Path $script:LOG_DIR "$ServiceName.err"
    
    # Build command based on service type
    $module = $ServiceConfig.module
    $args = $ServiceConfig.args
    
    if ($type -eq 'nextjs') {
        # Next.js service (AitherVeil)
        $workdir = Join-Path $script:ROOT 'AitherOS' 'AitherVeil'
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/c cd /d `"$workdir`" && npm run dev > `"$logFile`" 2> `"$errFile`""
        $psi.WorkingDirectory = $workdir
    } elseif ($type -eq 'agent') {
        # Agent service - path is relative to AitherOS/config/ in services.yaml
        # e.g. "../agents/GenesisAgent/service.py" means AitherOS/agents/GenesisAgent/service.py
        $agentPath = $ServiceConfig.path
        if ($agentPath -match '^\.\./agents/') {
            # Strip the ../ and build from AitherOS
            $agentPath = $agentPath -replace '^\.\./agents/', ''
            $agentPath = Join-Path $script:ROOT 'AitherOS' 'agents' $agentPath
        } else {
            $agentPath = Join-Path $script:ROOT 'AitherOS' $agentPath
        }
        
        if (-not (Test-Path $agentPath)) {
            Write-AitherLog "$ServiceName agent not found: $agentPath" -Level 'WARN'
            return @{ success = $false; reason = 'agent_not_found' }
        }
        
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $python
        $psi.Arguments = "`"$agentPath`""
        $psi.WorkingDirectory = Split-Path $agentPath -Parent
    } elseif ($args) {
        # Service with custom args (like Genesis using uvicorn)
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $python
        $psi.Arguments = "-m $args"
        $psi.WorkingDirectory = $script:ROOT
    } elseif ($module) {
        # Standard Python module
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $python
        $psi.Arguments = "-m $module"
        $psi.WorkingDirectory = Join-Path $script:ROOT 'AitherOS'
    } else {
        Write-AitherLog "$ServiceName has no module or args defined" -Level 'ERROR'
        return @{ success = $false; reason = 'no_module' }
    }
    
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    
    # Set environment
    $psi.EnvironmentVariables['AITHERZERO_ROOT'] = $script:ROOT
    $psi.EnvironmentVariables['PYTHONPATH'] = $script:ROOT
    
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        
        # Wait for port
        $timeout = $ServiceConfig.lifecycle?.startup_timeout ?? 60
        $started = Wait-ForPort -Port $port -TimeoutSeconds $timeout
        
        if ($started) {
            Write-AitherLog "$ServiceName started (PID: $($process.Id))" -Level 'SUCCESS'
            return @{
                success = $true
                pid = $process.Id
                port = $port
                startTime = (Get-Date).ToString('o')
            }
        } else {
            Write-AitherLog "$ServiceName failed to start within ${timeout}s" -Level 'ERROR'
            if (-not $process.HasExited) { $process.Kill() }
            return @{ success = $false; reason = 'timeout' }
        }
    } catch {
        Write-AitherLog "Failed to start $ServiceName`: $_" -Level 'ERROR'
        return @{ success = $false; reason = $_.Exception.Message }
    }
}

function Stop-AitherService {
    param([string]$ServiceName, [hashtable]$ServiceInfo)
    
    if ($ServiceInfo.pid) {
        try {
            $process = Get-Process -Id $ServiceInfo.pid -ErrorAction SilentlyContinue
            if ($process) {
                Write-AitherLog "Stopping $ServiceName (PID: $($ServiceInfo.pid))..." -Level 'INFO'
                Stop-Process -Id $ServiceInfo.pid -Force
                Write-AitherLog "$ServiceName stopped" -Level 'SUCCESS'
            }
        } catch {
            Write-AitherLog "Error stopping $ServiceName`: $_" -Level 'WARN'
        }
    }
    if ($ServiceInfo.port) {
        Stop-ProcessOnPort -Port $ServiceInfo.port
    }
}

# ============================================================================
# MAIN COMMANDS
# ============================================================================

function Show-ServiceList {
    $yaml = Get-ServicesYaml
    
    Write-Host "`n╔═══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    AitherOS Services (from services.yaml)                  ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan
    
    Write-Host "PROFILES:" -ForegroundColor Yellow
    foreach ($name in $yaml.groups.Keys | Sort-Object) {
        $group = $yaml.groups[$name]
        $desc = $group.description ?? ''
        $count = ($group.services | Measure-Object).Count
        Write-Host "  $($name.PadRight(15)) - $desc ($count services)" -ForegroundColor Gray
    }
    
    Write-Host "`nSERVICES ($($yaml.services.Count) total):" -ForegroundColor Yellow
    $byGroup = $yaml.services.GetEnumerator() | Group-Object { $_.Value.group ?? 'other' }
    foreach ($grp in $byGroup | Sort-Object Name) {
        Write-Host "`n  [$($grp.Name.ToUpper())]" -ForegroundColor Magenta
        foreach ($svc in $grp.Group | Sort-Object { $_.Value.port }) {
            $name = $svc.Key
            $port = $svc.Value.port
            $desc = $svc.Value.description ?? ''
            Write-Host "    $($name.PadRight(20)) :$($port.ToString().PadRight(6)) $desc" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

function Show-Status {
    $yaml = Get-ServicesYaml
    $running = Get-RunningServices
    
    Write-Host "`n╔═══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                         AitherOS Service Status                           ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan
    
    $runningCount = 0
    $totalCount = 0
    
    foreach ($name in $yaml.services.Keys | Sort-Object) {
        $svc = $yaml.services[$name]
        $port = $svc.port
        if (-not $port) { continue }
        
        $totalCount++
        $isRunning = Test-PortInUse -Port $port
        if ($isRunning) { $runningCount++ }
        
        $icon = if ($isRunning) { '●' } else { '○' }
        $color = if ($isRunning) { 'Green' } else { 'DarkGray' }
        $procId = $running[$name]?.pid ?? ''
        
        Write-Host "  $icon " -NoNewline -ForegroundColor $color
        Write-Host "$($name.PadRight(20))" -NoNewline
        Write-Host " :$($port.ToString().PadRight(6))" -NoNewline -ForegroundColor DarkGray
        if ($isRunning -and $procId) {
            Write-Host " PID:$procId" -ForegroundColor DarkGray
        } else {
            Write-Host ""
        }
    }
    
    Write-Host "`n  Running: $runningCount / $totalCount services`n" -ForegroundColor $(if ($runningCount -gt 0) { 'Green' } else { 'Yellow' })
}

function Start-Services {
    param([string]$ProfileName, [string[]]$ServiceNames)
    
    $yaml = Get-ServicesYaml
    $running = Get-RunningServices
    
    # Determine services to start
    if ($ServiceNames) {
        $toStart = $ServiceNames
    } else {
        $profile = $yaml.groups[$ProfileName]
        if (-not $profile) {
            Write-AitherLog "Unknown profile: $ProfileName. Use -List to see available profiles." -Level 'ERROR'
            return
        }
        $toStart = $profile.services
        if ($toStart -contains 'ALL') {
            $toStart = $yaml.services.Keys
        }
    }
    
    Write-Host "`n╔═══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                      Starting AitherOS Services                           ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan
    
    Write-AitherLog "Profile: $ProfileName ($($toStart.Count) services)" -Level 'INFO'
    
    # Build dependency order
    $started = @{}
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($s in $toStart) { $queue.Enqueue($s) }
    
    $maxAttempts = $toStart.Count * 2
    $attempts = 0
    
    while ($queue.Count -gt 0 -and $attempts -lt $maxAttempts) {
        $attempts++
        $serviceName = $queue.Dequeue()
        
        if ($started.ContainsKey($serviceName)) { continue }
        if (-not $yaml.services.ContainsKey($serviceName)) {
            Write-AitherLog "Unknown service: $serviceName" -Level 'WARN'
            continue
        }
        
        $svc = $yaml.services[$serviceName]
        $deps = $svc.depends_on ?? @()
        
        # Check dependencies
        $depsReady = $true
        foreach ($dep in $deps) {
            if (-not $started.ContainsKey($dep) -and $toStart -contains $dep) {
                $depsReady = $false
                break
            }
        }
        
        if (-not $depsReady) {
            $queue.Enqueue($serviceName)
            continue
        }
        
        # Start the service
        $result = Start-AitherService -ServiceName $serviceName -ServiceConfig $svc
        $started[$serviceName] = $true
        
        if ($result.success) {
            $running[$serviceName] = $result
        }
    }
    
    Save-RunningServices -Services $running
    Write-Host ""
}

function Stop-Services {
    $running = Get-RunningServices
    $yaml = Get-ServicesYaml
    
    Write-Host "`n╔═══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║                      Stopping AitherOS Services                           ║" -ForegroundColor Red
    Write-Host "╚═══════════════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Red
    
    foreach ($name in $running.Keys) {
        Stop-AitherService -ServiceName $name -ServiceInfo $running[$name]
    }
    
    # Also kill anything on known ports
    foreach ($name in $yaml.services.Keys) {
        $port = $yaml.services[$name].port
        if ($port -and (Test-PortInUse -Port $port)) {
            Write-AitherLog "Killing process on port $port..." -Level 'INFO'
            Stop-ProcessOnPort -Port $port
        }
    }
    
    @{} | ConvertTo-Json | Set-Content $script:PIDS_PATH -Force
    Write-Host ""
}

# ============================================================================
# ENTRY POINT
# ============================================================================

try {
    if ($List) {
        Show-ServiceList
    } elseif ($Status) {
        Show-Status
    } elseif ($Stop) {
        Stop-Services
        Show-Status
    } elseif ($Restart) {
        Stop-Services
        Start-Sleep -Seconds 2
        Start-Services -ProfileName $Profile -ServiceNames $Services
        Show-Status
    } else {
        Start-Services -ProfileName $Profile -ServiceNames $Services
        Show-Status
    }
} catch {
    Write-AitherLog "Fatal error: $_" -Level 'ERROR'
    throw
}
