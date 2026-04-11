#Requires -Version 7.0

<#
.SYNOPSIS
    Starts the AitherPulse background service for real-time metrics.
.DESCRIPTION
    Collects system performance data and AitherZero execution metrics in a loop.
    Updates JSON files in the Web Dashboard's public/data directory for live visualization.
    Can be run as a background job or a blocking process.
.NOTES
    Stage: Reporting
    Order: 0530
    Tags: pulse, monitoring, service, realtime
#>

[CmdletBinding()]
param(
    [int]$IntervalSeconds = 5,
    [int]$HistoryRetentionCount = 1000,
    [switch]$Daemon,
    [switch]$RunOnce
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Initialize
. "$PSScriptRoot/_init.ps1"

if (-not $projectRoot) {
    Write-Error "AitherZero project root not found"
    exit 1
}

# Paths
$WebDataDir = Join-Path $projectRoot "AitherZero/library/integrations/AitherZero-WebDash/public/data"
$PulseDir = Join-Path $WebDataDir "pulse"
if (-not (Test-Path $PulseDir)) {
    New-Item -Path $PulseDir -ItemType Directory -Force | Out-Null
}

$RealtimeFile = Join-Path $PulseDir "pulse-realtime.json"
$HistoryFile = Join-Path $PulseDir "pulse-history.json"

# Helper: Get System Metrics (Cross-platform compatible-ish)
function Get-SystemMetrics {
    $cpu = 0
    $mem = 0
    
    if ($IsWindows) {
        $os = Get-CimInstance Win32_OperatingSystem
        $mem = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB, 2) # MB
        
        # CPU is harder to get instantly without a counter, using a quick sample
        $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples.CookedValue
    }
    elseif ($IsLinux) {
        # Simplified Linux metrics
        $memInfo = Get-Content /proc/meminfo
        $total = [int]($memInfo | Select-String "MemTotal:\s+(\d+)").Matches.Groups[1].Value
        $free = [int]($memInfo | Select-String "MemAvailablD:\s+(\d+)").Matches.Groups[1].Value
        $mem = [math]::Round(($total - $free) / 1024, 2)
        
        # Load avg as proxy for CPU
        $cpu = (Get-Content /proc/loadavg).Split(' ')[0]
    }

    return @{
        CPU = [math]::Round($cpu, 1)
        MemoryMB = $mem
        Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    }
}

# Helper: Get Quality Metrics (Pain Signals)
function Get-QualityMetrics {
    $testFailures = 0
    $errorCount = 0
    
    # 1. Check Test Results
    $testResultsDir = Join-Path $projectRoot "AitherZero/library/tests/results"
    if (Test-Path $testResultsDir) {
        $latestTest = Get-ChildItem -Path $testResultsDir -Filter "UnitTests-*.xml" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestTest) {
            try {
                [xml]$xml = Get-Content $latestTest.FullName
                $testFailures = [int]$xml.'test-results'.failures + [int]$xml.'test-results'.errors
            } catch {
                # Ignore parsing errors
            }
        }
    }

    # 2. Check Error Logs
    $logDir = Join-Path $projectRoot "AitherZero/library/logs"
    $todayLog = Join-Path $logDir "aitherzero-$(Get-Date -Format 'yyyy-MM-dd').log"
    if (Test-Path $todayLog) {
        try {
            # Count [Error] occurrences in the last 100 lines to be fast
            $errorCount = (Get-Content $todayLog -Tail 100 | Select-String "\[Error\]").Count
        } catch {
            # Ignore read errors
        }
    }

    return @{
        TestFailures = $testFailures
        ErrorCount = $errorCount
    }
}

# Helper: Atomic Write
function Write-JsonAtomic {
    param($Path, $Data)
    $tempPath = "$Path.tmp"
    $Data | ConvertTo-Json -Depth 5 -Compress | Set-Content $tempPath
    Move-Item -Path $tempPath -Destination $Path -Force
}

# Main Loop
$running = $true
Write-Host "Starting AitherPulse Service (Interval: ${IntervalSeconds}s)..." -ForegroundColor Cyan

while ($running) {
    try {
        $sysMetrics = Get-SystemMetrics
        $qualMetrics = Get-QualityMetrics
        
        # Merge metrics safely
        $metrics = @{}
        if ($sysMetrics -is [System.Collections.IDictionary]) {
            $sysMetrics.Keys | ForEach-Object { $metrics[$_] = $sysMetrics[$_] }
        }
        if ($qualMetrics -is [System.Collections.IDictionary]) {
            $qualMetrics.Keys | ForEach-Object { $metrics[$_] = $qualMetrics[$_] }
        }
        
        # 1. Update Realtime File
        Write-JsonAtomic -Path $RealtimeFile -Data $metrics
        
        # 2. Update History
        $history = @()
        if (Test-Path $HistoryFile) {
            try {
                $history = @(Get-Content $HistoryFile -Raw | ConvertFrom-Json)
            } catch {
                Write-Warning "Corrupt history file, starting fresh."
            }
        }
        
        $history += $metrics
        
        # Prune history
        if ($history.Count -gt $HistoryRetentionCount) {
            $history = $history | Select-Object -Last $HistoryRetentionCount
        }
        
        Write-JsonAtomic -Path $HistoryFile -Data $history
        
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        
        if ($RunOnce) {
            $running = $false
        } else {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    catch {
        Write-Error "Pulse Error: $_"
        if ($RunOnce) { $running = $false }
        Start-Sleep -Seconds 5
    }
}

Write-Host "`nAitherPulse Stopped." -ForegroundColor Cyan

