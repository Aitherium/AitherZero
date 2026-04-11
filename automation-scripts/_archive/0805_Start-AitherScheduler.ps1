<#
.SYNOPSIS
    Starts the AitherScheduler autonomous training scheduler.

.DESCRIPTION
    Starts the AitherScheduler service which:
    - Manages training job queue with priority
    - Auto-harvests training data at intervals
    - Triggers training when sufficient data available
    - Coordinates with GitHub Actions for distributed training
    - Provides real-time status via SSE

    Port: 8109
    Health: http://localhost:8109/health
    Events: http://localhost:8109/events (SSE stream)

.PARAMETER Port
    Port to run the scheduler on. Default: 8109

.PARAMETER AutoStart
    Automatically start the scheduler loop.

.PARAMETER ShowOutput
    Show detailed output during execution.

.EXAMPLE
    .\0805_Start-AitherScheduler.ps1 -ShowOutput
    Starts the scheduler with live output.

.EXAMPLE
    .\0805_Start-AitherScheduler.ps1 -Port 8109 -AutoStart
    Starts with auto-scheduling enabled.

.NOTES
    Stage: AitherOS
    Order: 0805
    Category: Training
    Author: AitherZero
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [int]$Port = 8109,
    
    [switch]$AutoStart,
    
    [switch]$Background,
    
    [switch]$ShowOutput
)

# Initialize script environment
. "$PSScriptRoot/_init.ps1"

$script:ExitCode = 0

try {
    $schedulerPath = Join-Path $projectRoot "AitherOS\AitherNode\AitherScheduler.py"
    $venvPython = Join-Path $projectRoot "AitherOS\agents\NarrativeAgent\.venv\Scripts\python.exe"
    
    if (-not (Test-Path $schedulerPath)) {
        Write-Error "AitherScheduler not found at: $schedulerPath"
        exit 1
    }
    
    if (-not (Test-Path $venvPython)) {
        Write-Warning "Python venv not found. Run 0781_Setup-AitherTrainer.ps1 first."
        exit 1
    }
    
    # Check if already running
    $existing = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($existing) {
        if ($ShowOutput) {
            Write-Host "AitherScheduler already running on port $Port" -ForegroundColor Yellow
            Write-Host "  Health: http://localhost:$Port/health" -ForegroundColor Cyan
            Write-Host "  Status: http://localhost:$Port/scheduler/status" -ForegroundColor Cyan
        }
        exit 0
    }
    
    # Set environment variables
    $env:AITHERZERO_ROOT = $projectRoot
    $env:AITHER_TRAINER_URL = "http://localhost:8107"
    $env:AITHER_HARVEST_URL = "http://localhost:8108"
    $env:AITHER_NODE_URL = "http://localhost:8080"
    
    if ($ShowOutput) {
        Write-Host "╔════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║     AitherScheduler - Job Manager      ║" -ForegroundColor Cyan
        Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Starting AitherScheduler on port $Port..." -ForegroundColor White
        Write-Host ""
        Write-Host "Endpoints:" -ForegroundColor Yellow
        Write-Host "  Health:    http://localhost:$Port/health" -ForegroundColor White
        Write-Host "  Status:    http://localhost:$Port/scheduler/status" -ForegroundColor White
        Write-Host "  Jobs:      http://localhost:$Port/jobs" -ForegroundColor White
        Write-Host "  Events:    http://localhost:$Port/events (SSE)" -ForegroundColor White
        Write-Host "  Runners:   http://localhost:$Port/runners" -ForegroundColor White
        Write-Host ""
        Write-Host "Quick Actions:" -ForegroundColor Yellow
        Write-Host "  POST /quick/harvest   - Trigger data harvest" -ForegroundColor DarkGray
        Write-Host "  POST /quick/training  - Start training job" -ForegroundColor DarkGray
        Write-Host "  POST /quick/benchmark - Run benchmarks" -ForegroundColor DarkGray
        Write-Host ""
    }
    
    if ($Background) {
        # Start as background process
        $process = Start-Process -FilePath $venvPython -ArgumentList @(
            "-u",
            $schedulerPath
        ) -PassThru -WindowStyle Hidden
        
        if ($ShowOutput) {
            Write-Host "Started in background (PID: $($process.Id))" -ForegroundColor Green
        }
        
        # Wait for startup
        Start-Sleep -Seconds 2
        
        # Verify it's running
        try {
            $response = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 5
            if ($response.status -eq "healthy") {
                if ($ShowOutput) {
                    Write-Host "AitherScheduler is healthy" -ForegroundColor Green
                }
            }
        } catch {
            Write-Warning "Could not verify scheduler health"
        }
    } else {
        # Run in foreground
        & $venvPython -u $schedulerPath
    }
    
} catch {
    Write-AitherError -ErrorRecord $_ -Context "AitherScheduler-Start"
    $script:ExitCode = 1
}

exit $script:ExitCode
