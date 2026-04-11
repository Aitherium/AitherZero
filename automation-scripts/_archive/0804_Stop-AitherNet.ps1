<#
.SYNOPSIS
    Gracefully stops all AitherNet services.

.DESCRIPTION
    This script cleanly shuts down all Aither services in the correct order:
    1. Sends graceful shutdown signals (SIGTERM)
    2. Waits for clean exit
    3. Force kills if necessary
    4. Verifies all ports are released
    
    Uses ports.json as the single source of truth - NO HARDCODING.

.PARAMETER Force
    Skip graceful shutdown and force kill immediately.

.PARAMETER Verify
    Only check what's running, don't stop anything.

.EXAMPLE
    .\0804_Stop-AitherNet.ps1
    # Graceful shutdown of all services

.EXAMPLE
    .\0804_Stop-AitherNet.ps1 -Force
    # Force kill everything immediately

.NOTES
    Stage: AitherOS
    Order: 0804
    Tags: shutdown, aithernet, services
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Verify,
    [switch]$ShowOutput
)

# ============================================================================
# INITIALIZATION
# ============================================================================
. "$PSScriptRoot/_init.ps1"

$scriptName = "Stop-AitherNet"
$ErrorActionPreference = "SilentlyContinue"

# ============================================================================
# LOAD PORTS FROM SINGLE SOURCE OF TRUTH
# ============================================================================
$portsJsonPath = Join-Path $env:AITHERZERO_ROOT "AitherOS\AitherNode\config\ports.json"

if (-not (Test-Path $portsJsonPath)) {
    Write-Host "❌ ports.json not found at: $portsJsonPath" -ForegroundColor Red
    exit 1
}

$portsConfig = Get-Content $portsJsonPath -Raw | ConvertFrom-Json
$services = $portsConfig.services.PSObject.Properties

# Also include external services
$additionalPorts = @{
    "Ollama" = 11434
    "ComfyUI" = 8188
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║                    AITHERNET SHUTDOWN                             ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

# ============================================================================
# SCAN WHAT'S RUNNING
# ============================================================================
function Get-RunningServices {
    $running = @()
    
    # Check all services from ports.json
    foreach ($svc in $services) {
        $name = $svc.Name
        $port = $svc.Value.port
        
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($conn) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.Id -ne 0) {
                $running += [PSCustomObject]@{
                    Name = $name
                    Port = $port
                    PID = $proc.Id
                    ProcessName = $proc.ProcessName
                    Memory = [math]::Round($proc.WorkingSet64 / 1MB, 1)
                }
            }
        }
    }
    
    # Check additional ports
    foreach ($item in $additionalPorts.GetEnumerator()) {
        $conn = Get-NetTCPConnection -LocalPort $item.Value -State Listen -ErrorAction SilentlyContinue
        if ($conn) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.Id -ne 0) {
                # Check if already in list
                if ($running.Port -notcontains $item.Value) {
                    $running += [PSCustomObject]@{
                        Name = $item.Key
                        Port = $item.Value
                        PID = $proc.Id
                        ProcessName = $proc.ProcessName
                        Memory = [math]::Round($proc.WorkingSet64 / 1MB, 1)
                    }
                }
            }
        }
    }
    
    return $running
}

$runningServices = Get-RunningServices

if ($runningServices.Count -eq 0) {
    Write-Host "✅ No AitherNet services are running." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($runningServices.Count) running services:" -ForegroundColor Yellow
Write-Host ""
$runningServices | Format-Table -Property Name, Port, PID, ProcessName, @{L='Memory(MB)';E={$_.Memory}} -AutoSize
Write-Host ""

if ($Verify) {
    Write-Host "Verify mode - no services stopped." -ForegroundColor Cyan
    exit 0
}

# ============================================================================
# SHUTDOWN SEQUENCE
# ============================================================================

# Define shutdown order (reverse of startup - dependent services first)
$shutdownOrder = @(
    # Layer 4: UI/Frontend
    "AitherVeil",
    
    # Layer 3: High-level services
    "AitherCouncil", "AitherA2A", "AitherCanvas",
    
    # Layer 2: Processing services
    "AitherMind", "AitherVision", "AitherVoice", "AitherReasoning",
    "AitherParallel", "AitherWorkingMemory", "AitherAccel", "AitherForce",
    "AitherTrainer", "AitherPrism", "AitherHarvest",
    "AitherScheduler", "AitherAutonomic", "AitherGate", "AitherFlow",
    
    # Layer 1: Core services
    "AitherPulse", "AitherWatch", "AitherSpirit", "AitherSense",
    "AitherWill", "AitherContext", "AitherPersona", "AitherSafety",
    "AitherSecrets", "AitherReflex", "AitherChain",
    
    # Layer 0: Foundation
    "AitherNode", "Aither",
    
    # External
    "ComfyUI", "Ollama"
)

function Stop-ServiceGracefully {
    param(
        [string]$Name,
        [int]$Port,
        [int]$PID
    )
    
    Write-Host "  Stopping $Name (port $Port, PID $PID)..." -NoNewline
    
    if ($Force) {
        Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue
        Write-Host " KILLED" -ForegroundColor Red
        return
    }
    
    # Try graceful shutdown via HTTP (if service has /shutdown endpoint)
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:$Port/shutdown" -Method POST -TimeoutSec 2 -ErrorAction SilentlyContinue
    } catch { }
    
    # Wait for graceful exit
    $timeout = 5
    $stopped = $false
    for ($i = 0; $i -lt $timeout; $i++) {
        $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
        if (-not $proc) {
            $stopped = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    
    if ($stopped) {
        Write-Host " OK" -ForegroundColor Green
    } else {
        # Force kill
        Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue
        Write-Host " FORCE KILLED" -ForegroundColor Yellow
    }
}

Write-Host "Stopping services..." -ForegroundColor Cyan
Write-Host ""

# Stop in order
foreach ($serviceName in $shutdownOrder) {
    $svc = $runningServices | Where-Object { $_.Name -eq $serviceName }
    if ($svc) {
        Stop-ServiceGracefully -Name $svc.Name -Port $svc.Port -PID $svc.PID
    }
}

# Stop any remaining (not in shutdown order)
$remaining = $runningServices | Where-Object { $shutdownOrder -notcontains $_.Name }
foreach ($svc in $remaining) {
    Stop-ServiceGracefully -Name $svc.Name -Port $svc.Port -PID $svc.PID
}

# ============================================================================
# CLEANUP ORPHANED PROCESSES
# ============================================================================
Write-Host ""
Write-Host "Cleaning up orphaned processes..." -ForegroundColor Cyan

# Kill any remaining Python/Node processes that might be orphaned
$orphanedPython = Get-Process python* -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*Aither*" -or $_.CommandLine -like "*uvicorn*"
}
$orphanedNode = Get-Process node* -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*AitherVeil*" -or $_.CommandLine -like "*next*"
}

$orphanCount = 0
foreach ($proc in $orphanedPython) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    $orphanCount++
}
foreach ($proc in $orphanedNode) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    $orphanCount++
}

if ($orphanCount -gt 0) {
    Write-Host "  Killed $orphanCount orphaned processes" -ForegroundColor Yellow
}

# ============================================================================
# VERIFY SHUTDOWN
# ============================================================================
Write-Host ""
Write-Host "Verifying shutdown..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

$stillRunning = Get-RunningServices

if ($stillRunning.Count -eq 0) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║            ✅ ALL SERVICES STOPPED SUCCESSFULLY                  ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "⚠️  Some services still running:" -ForegroundColor Red
    $stillRunning | Format-Table -Property Name, Port, PID, ProcessName -AutoSize
    
    if (-not $Force) {
        Write-Host ""
        Write-Host "Run with -Force to kill stubborn processes." -ForegroundColor Yellow
    }
}
