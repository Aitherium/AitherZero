#Requires -Version 7.0
<#
.SYNOPSIS
    Starts AitherSearch - Intelligent Web Search Service
.DESCRIPTION
    Starts the AitherSearch service which provides:
    - Multi-provider web search (Perplexity, Brave, DuckDuckGo)
    - AI model search (Civitai, HuggingFace)
    - Auto-search trigger detection
    - Result caching and quota management
    - AitherPulse integration for health monitoring

.PARAMETER Configure
    Open interactive configuration wizard for API keys and defaults

.PARAMETER TestProviders
    Test all configured search providers

.PARAMETER SetDefault
    Set default web search provider (perplexity, brave, duckduckgo)

.PARAMETER ShowOutput
    Show detailed output during startup

.PARAMETER Port
    Override default port (8113)

.EXAMPLE
    ./0812_Start-AitherSearch.ps1
    Start the search service

.EXAMPLE
    ./0812_Start-AitherSearch.ps1 -Configure
    Open interactive configuration wizard

.EXAMPLE
    ./0812_Start-AitherSearch.ps1 -SetDefault duckduckgo
    Set DuckDuckGo as default web provider

.NOTES
    Stage: AI Tools
    Order: 0812
    Tags: aitheros, search, perplexity, brave, duckduckgo, civitai
    Dependencies: 0800_Start-AitherOS.ps1 (for Pulse)
#>
[CmdletBinding()]
param(
    [switch]$Configure,
    [switch]$TestProviders,
    [ValidateSet('perplexity', 'brave', 'duckduckgo')]
    [string]$SetDefault,
    [switch]$ShowOutput,
    [int]$Port = 8113
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/_init.ps1"

# ============================================================================
# PATHS
# ============================================================================
$AitherNodePath = Join-Path $projectRoot "AitherOS/AitherNode"
$VenvScripts = Join-Path $projectRoot "AitherOS/agents/NarrativeAgent/.venv/Scripts"
$PythonExe = Join-Path $VenvScripts "python.exe"
$SearchConfigScript = Join-Path $AitherNodePath "services/cognition/search_config.py"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
function Write-Log {
    param([string]$Msg, [string]$Level = "Info")
    $icon = switch ($Level) { "OK" { "✓" } "Err" { "✗" } "Warn" { "⚠" } "Info" { "ℹ" } default { "○" } }
    $color = switch ($Level) { "OK" { "Green" } "Err" { "Red" } "Warn" { "Yellow" } "Info" { "Cyan" } default { "White" } }
    Write-Host "[Search] $icon $Msg" -ForegroundColor $color
}

function Test-Port([int]$PortNum) {
    $null -ne (Get-NetTCPConnection -LocalPort $PortNum -State Listen -ErrorAction SilentlyContinue)
}

function Stop-Port([int]$PortNum) {
    Get-NetTCPConnection -LocalPort $PortNum -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        if ($p -and $p.Id -ne 0) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# VALIDATE PREREQUISITES
# ============================================================================
if (-not (Test-Path $PythonExe)) {
    Write-Log "Python venv not found. Run: ./0761_Setup-AitherNode.ps1" "Err"
    exit 1
}

# ============================================================================
# CONFIGURATION MODE
# ============================================================================
if ($Configure) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║              AitherSearch Configuration Wizard                    ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    $env:PYTHONPATH = $AitherNodePath
    & $PythonExe $SearchConfigScript
    exit 0
}

# ============================================================================
# SET DEFAULT PROVIDER
# ============================================================================
if ($SetDefault) {
    Write-Log "Setting default web provider to: $SetDefault"
    
    $env:PYTHONPATH = $AitherNodePath
    $script = @"
import sys
sys.path.insert(0, r'$AitherNodePath')
from services.cognition.search_config import get_config_manager
mgr = get_config_manager()
if mgr.set_default_provider('$SetDefault', 'web'):
    print(f'✅ Default web provider set to: $SetDefault')
else:
    print('❌ Failed to set default provider')
"@
    
    & $PythonExe -c $script
    exit 0
}

# ============================================================================
# TEST PROVIDERS
# ============================================================================
if ($TestProviders) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║              Testing Search Providers                             ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    # Check if service is running
    if (Test-Port $Port) {
        Write-Log "Service running on :$Port - using API"
        
        $providers = @("perplexity", "brave", "duckduckgo", "civitai", "huggingface")
        foreach ($prov in $providers) {
            Write-Host "  Testing $prov... " -NoNewline
            try {
                $result = Invoke-RestMethod -Uri "http://localhost:$Port/config/test-provider/$prov" -Method POST -TimeoutSec 30
                if ($result.working) {
                    Write-Host "✅ Working" -ForegroundColor Green
                } elseif ($result.available) {
                    Write-Host "⚠️ Available but test failed: $($result.error)" -ForegroundColor Yellow
                } else {
                    Write-Host "❌ Not configured" -ForegroundColor Red
                }
            }
            catch {
                Write-Host "❌ Error: $_" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Log "Service not running. Start it first with: ./0812_Start-AitherSearch.ps1" "Warn"
    }
    exit 0
}

# ============================================================================
# START SERVICE
# ============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║                    AitherSearch                                   ║" -ForegroundColor Magenta
Write-Host "║           Intelligent Web Search & Research Engine                ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# Check if already running
if (Test-Port $Port) {
    Write-Log "Already running on :$Port" "Warn"
    
    # Show status
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 5
        Write-Host ""
        Write-Host "  Status: " -NoNewline
        Write-Host $health.status -ForegroundColor Green
        Write-Host "  Providers: " -NoNewline
        $available = ($health.providers | Where-Object { $_.available }).name -join ", "
        Write-Host $available -ForegroundColor Cyan
    }
    catch {
        Write-Log "Could not fetch status" "Warn"
    }
    exit 0
}

# Check if Pulse is running (recommended dependency)
if (-not (Test-Port 8081)) {
    Write-Log "AitherPulse not running (recommended). Health events will be limited." "Warn"
}

# Set environment
$env:PYTHONUNBUFFERED = "1"
$env:AITHERZERO_ROOT = $projectRoot
$env:PYTHONPATH = $AitherNodePath

# Start the service
Write-Log "Starting on :$Port..."

$args = "-m uvicorn services.cognition.AitherSearch:app --host 0.0.0.0 --port $Port"

try {
    if ($ShowOutput) {
        # Run in foreground with output
        & $PythonExe -m uvicorn services.cognition.AitherSearch:app --host 0.0.0.0 --port $Port
    }
    else {
        # Run in background
        $proc = Start-Process -FilePath $PythonExe -ArgumentList $args -WorkingDirectory $AitherNodePath -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 2
        
        if ($proc.HasExited) {
            Write-Log "Failed to start (exit code: $($proc.ExitCode))" "Err"
            exit 1
        }
        
        # Wait for service to be ready
        $maxWait = 10
        $ready = $false
        for ($i = 0; $i -lt $maxWait; $i++) {
            if (Test-Port $Port) {
                $ready = $true
                break
            }
            Start-Sleep -Seconds 1
        }
        
        if ($ready) {
            Write-Log "Started successfully on :$Port (PID: $($proc.Id))" "OK"
            
            # Show provider status
            try {
                Start-Sleep -Seconds 1
                $health = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 5
                Write-Host ""
                $webProviders = ($health.providers | Where-Object { $_.type -eq "web" -and $_.available }).name -join ", "
                $modelProviders = ($health.providers | Where-Object { $_.type -eq "model" -and $_.available }).name -join ", "
                
                Write-Host "  Web Providers:   " -NoNewline
                if ($webProviders) { Write-Host $webProviders -ForegroundColor Green }
                else { Write-Host "None configured" -ForegroundColor Yellow }
                
                Write-Host "  Model Providers: " -NoNewline
                if ($modelProviders) { Write-Host $modelProviders -ForegroundColor Green }
                else { Write-Host "None configured" -ForegroundColor Yellow }
                
                Write-Host ""
                Write-Host "  Endpoints:" -ForegroundColor White
                Write-Host "    http://localhost:$Port/search       - Web search" -ForegroundColor Cyan
                Write-Host "    http://localhost:$Port/search/models - Model search" -ForegroundColor Cyan
                Write-Host "    http://localhost:$Port/config        - Configuration" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Configure: ./0812_Start-AitherSearch.ps1 -Configure" -ForegroundColor DarkGray
            }
            catch {
                # Service started but health check failed - still OK
            }
        }
        else {
            Write-Log "Service started but not responding on :$Port" "Warn"
        }
    }
}
catch {
    Write-Log "Failed to start: $_" "Err"
    exit 1
}

