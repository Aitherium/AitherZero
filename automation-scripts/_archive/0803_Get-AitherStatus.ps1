#Requires -Version 7.0

<#
.SYNOPSIS
    Shows the status of all Aither ecosystem services.
.DESCRIPTION
    Checks the health and status of all Aither services including:
    - Port availability
    - Health endpoint responses
    - Process information
    - Uptime and metrics
.PARAMETER Detailed
    Show detailed metrics for each service
.PARAMETER Watch
    Continuously monitor services (refresh every N seconds)
.PARAMETER Json
    Output as JSON for automation
.EXAMPLE
    .\0803_Get-AitherStatus.ps1
    Shows status of all services.
.EXAMPLE
    .\0803_Get-AitherStatus.ps1 -Watch 5
    Continuously monitors services, refreshing every 5 seconds.
.NOTES
    Stage: AitherOS
    Order: 0803
    Tags: status, monitoring, health, services
#>

[CmdletBinding()]
param(
    [switch]$Detailed,
    [int]$Watch = 0,
    [switch]$Json
)

$ErrorActionPreference = 'SilentlyContinue'

# Service definitions
$Services = @(
    @{ Key = "Brain";    Name = "AitherOrchestrator"; Port = 8767; Health = "/health"; Icon = "🧠" }
    @{ Key = "Gateway";  Name = "A2A Gateway";       Port = 8766; Health = "/health"; Icon = "🌐" }
    @{ Key = "Demiurge"; Name = "AitherDemiurge";    Port = 8140; Health = "/";       Icon = "⚒️" }
    @{ Key = "Will";     Name = "AitherWill";        Port = 8097; Health = "/";       Icon = "🔥" }
    @{ Key = "Pulse";    Name = "AitherPulse";       Port = 8081; Health = "/health"; Icon = "💓" }
    @{ Key = "Veil";     Name = "AitherVeil";        Port = 3000; Health = "/";       Icon = "🎭" }
    @{ Key = "Node";     Name = "AitherNode";        Port = 8090; Health = "/health"; Icon = "🔌" }
    @{ Key = "Ollama";   Name = "Ollama";            Port = 11434; Health = "/api/tags"; Icon = "🦙" }
    @{ Key = "Canvas";   Name = "ComfyUI";           Port = 8188; Health = "/";       Icon = "🎨" }
)

function Get-ServiceStatus {
    param([hashtable]$Service)
    
    $status = @{
        Name = $Service.Name
        Port = $Service.Port
        Icon = $Service.Icon
        Running = $false
        Healthy = $false
        ResponseTime = $null
        Error = $null
        PID = $null
    }
    
    # Check port
    try {
        $conn = Get-NetTCPConnection -LocalPort $Service.Port -ErrorAction SilentlyContinue
        if ($conn) {
            $status.Running = $true
            $status.PID = ($conn | Select-Object -First 1).OwningProcess
        }
    }
    catch { }
    
    # Check health endpoint
    if ($status.Running) {
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $response = Invoke-RestMethod -Uri "http://localhost:$($Service.Port)$($Service.Health)" -Method Get -TimeoutSec 5
            $sw.Stop()
            
            $status.Healthy = $true
            $status.ResponseTime = $sw.ElapsedMilliseconds
        }
        catch {
            $status.Error = $_.Exception.Message
        }
    }
    
    return $status
}

function Show-Status {
    $results = @()
    
    foreach ($svc in $Services) {
        $results += Get-ServiceStatus -Service $svc
    }
    
    if ($Json) {
        return $results | ConvertTo-Json -Depth 3
    }
    
    # Clear screen for watch mode
    if ($Watch -gt 0) {
        Clear-Host
    }
    
    # Header
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    AITHER ECOSYSTEM STATUS                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host ""
    
    # Status table
    $onlineCount = 0
    $offlineCount = 0
    
    foreach ($r in $results) {
        $icon = $r.Icon
        $name = $r.Name.PadRight(15)
        $port = ":$($r.Port)".PadRight(7)
        
        if ($r.Healthy) {
            $onlineCount++
            $statusIcon = "●"
            $statusColor = "Green"
            $statusText = "ONLINE"
            $extra = "$(($r.ResponseTime))ms"
        }
        elseif ($r.Running) {
            $onlineCount++
            $statusIcon = "◐"
            $statusColor = "Yellow"
            $statusText = "DEGRADED"
            $extra = $r.Error
        }
        else {
            $offlineCount++
            $statusIcon = "○"
            $statusColor = "DarkGray"
            $statusText = "OFFLINE"
            $extra = ""
        }
        
        Write-Host "  $icon " -NoNewline
        Write-Host "$name" -NoNewline -ForegroundColor White
        Write-Host "$port" -NoNewline -ForegroundColor DarkGray
        Write-Host "$statusIcon " -NoNewline -ForegroundColor $statusColor
        Write-Host "$statusText".PadRight(10) -NoNewline -ForegroundColor $statusColor
        
        if ($Detailed -and $extra) {
            Write-Host " $extra" -ForegroundColor DarkGray
        }
        else {
            Write-Host ""
        }
    }
    
    # Summary
    Write-Host ""
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    
    $totalColor = if ($offlineCount -eq 0) { "Green" } elseif ($onlineCount -gt 0) { "Yellow" } else { "Red" }
    Write-Host "  Online: " -NoNewline
    Write-Host "$onlineCount" -NoNewline -ForegroundColor Green
    Write-Host " | Offline: " -NoNewline
    Write-Host "$offlineCount" -NoNewline -ForegroundColor $(if ($offlineCount -gt 0) { "Red" } else { "DarkGray" })
    Write-Host " | Total: $($Services.Count)" -ForegroundColor DarkGray
    Write-Host ""
    
    if ($Watch -gt 0) {
        Write-Host "  Refreshing every ${Watch}s... (Ctrl+C to stop)" -ForegroundColor DarkGray
    }
    
    return $results
}

# Main
if ($Watch -gt 0) {
    while ($true) {
        Show-Status | Out-Null
        Start-Sleep -Seconds $Watch
    }
}
else {
    $results = Show-Status
    if ($Json) {
        Write-Output $results
    }
}
