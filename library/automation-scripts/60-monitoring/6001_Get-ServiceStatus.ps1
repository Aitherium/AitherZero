#Requires -Version 7.0
<#
.SYNOPSIS
    Shows the status of all AitherOS services.

.DESCRIPTION
    Checks the health and status of all AitherOS services including:
    - Genesis bootloader status
    - Container status via Docker
    - Health endpoint responses
    - Response times and metrics

.PARAMETER Detailed
    Show detailed metrics for each service.

.PARAMETER Watch
    Continuously monitor services (refresh every N seconds).

.PARAMETER Json
    Output as JSON for automation.

.PARAMETER Source
    Status source: "genesis" (use Genesis API) or "docker" (direct Docker query).
    Default: "genesis"

.EXAMPLE
    .\5001_Get-ServiceStatus.ps1
    Shows status of all services via Genesis API.

.EXAMPLE
    .\5001_Get-ServiceStatus.ps1 -Watch 5 -Detailed
    Continuously monitors services with details, refreshing every 5 seconds.

.EXAMPLE
    .\5001_Get-ServiceStatus.ps1 -Source docker -Json
    Gets status directly from Docker and outputs as JSON.

.NOTES
    Category: monitoring
    Dependencies: Docker, Genesis API
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [switch]$Detailed,
    [int]$Watch = 0,
    [switch]$Json,
    
    [ValidateSet("genesis", "docker")]
    [string]$Source = "genesis"
)

$ErrorActionPreference = 'SilentlyContinue'

# Service definitions for direct Docker checking
$KnownServices = @(
    @{ Name = "Genesis";      Port = 8001;  Health = "/health";     Icon = "⚡" }
    @{ Name = "Chronicle";    Port = 8121;  Health = "/health";     Icon = "📜" }
    @{ Name = "Veil";         Port = 3000;  Health = "/api/health"; Icon = "🎭" }
    @{ Name = "Node";         Port = 8090;  Health = "/health";     Icon = "🔌" }
    @{ Name = "LLM";          Port = 8100;  Health = "/health";     Icon = "🧠" }
    @{ Name = "Orchestrator"; Port = 8767;  Health = "/health";     Icon = "🎯" }
    @{ Name = "Mind";         Port = 8125;  Health = "/health";     Icon = "💭" }
    @{ Name = "Oracle";       Port = 8104;  Health = "/health";     Icon = "🦙" }
    @{ Name = "Ollama";       Port = 11434; Health = "/api/tags";   Icon = "🦙" }
    @{ Name = "ComfyUI";      Port = 8188;  Health = "/";           Icon = "🎨" }
)

function Get-GenesisStatus {
    <#
    .SYNOPSIS
        Get status from Genesis API
    #>
    try {
        $services = Invoke-RestMethod -Uri "http://localhost:8001/api/services" -TimeoutSec 5
        $bootStatus = Invoke-RestMethod -Uri "http://localhost:8001/api/boot/status" -TimeoutSec 5
        
        return @{
            Success = $true
            Services = $services
            BootStatus = $bootStatus
        }
    } catch {
        return @{
            Success = $false
            Error = "Genesis API not available: $_"
        }
    }
}

function Get-DockerStatus {
    <#
    .SYNOPSIS
        Get status directly from Docker
    #>
    $results = @()
    
    try {
        $containers = docker ps -a --filter "label=aitheros.service" --format "{{.Names}}|{{.Status}}|{{.Ports}}" 2>$null
        
        foreach ($line in $containers) {
            if ($line) {
                $parts = $line -split '\|'
                $name = $parts[0] -replace '^aitheros-', ''
                $status = $parts[1]
                $ports = $parts[2]
                
                $isRunning = $status -match "^Up"
                $isHealthy = $status -match "healthy"
                
                $results += @{
                    Name = $name
                    ContainerName = $parts[0]
                    Status = if ($isRunning) { "running" } else { "stopped" }
                    Health = if ($isHealthy) { "healthy" } elseif ($isRunning) { "starting" } else { "stopped" }
                    Ports = $ports
                    RawStatus = $status
                }
            }
        }
    } catch {
        Write-Warning "Failed to query Docker: $_"
    }
    
    return $results
}

function Test-ServiceHealth {
    param(
        [string]$Port,
        [string]$Endpoint = "/health"
    )
    
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-RestMethod -Uri "http://localhost:$Port$Endpoint" -TimeoutSec 5 -ErrorAction Stop
        $sw.Stop()
        
        return @{
            Healthy = $true
            ResponseTime = $sw.ElapsedMilliseconds
        }
    } catch {
        return @{
            Healthy = $false
            ResponseTime = $null
            Error = $_.Exception.Message
        }
    }
}

function Show-Status {
    $results = @()
    $genesisOnline = $false
    
    # Try Genesis first if requested
    if ($Source -eq "genesis") {
        $genesisData = Get-GenesisStatus
        
        if ($genesisData.Success) {
            $genesisOnline = $true
            $results = $genesisData.Services | ForEach-Object {
                $svc = $_
                $known = $KnownServices | Where-Object { $_.Name -eq $svc.name }
                @{
                    Name = $svc.name
                    Port = $svc.port
                    Status = $svc.status
                    Health = $svc.health
                    Icon = if ($known) { $known.Icon } else { "📦" }
                    ContainerId = $svc.container_id
                    DependsOn = $svc.depends_on
                }
            }
        } else {
            Write-Host "Genesis API not available, falling back to Docker..." -ForegroundColor Yellow
        }
    }
    
    # Fallback to Docker if Genesis not available
    if (-not $genesisOnline) {
        $dockerStatus = Get-DockerStatus
        $results = $dockerStatus | ForEach-Object {
            $svc = $_
            $known = $KnownServices | Where-Object { $_.Name -eq $svc.Name }
            @{
                Name = $svc.Name
                Port = if ($known) { $known.Port } else { $null }
                Status = $svc.Status
                Health = $svc.Health
                Icon = if ($known) { $known.Icon } else { "📦" }
                ContainerId = $svc.ContainerName
            }
        }
    }
    
    # JSON output
    if ($Json) {
        return $results | ConvertTo-Json -Depth 5
    }
    
    # Clear screen for watch mode
    if ($Watch -gt 0) {
        Clear-Host
    }
    
    # Display header
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    AITHEROS SERVICE STATUS                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  Source: $Source" -ForegroundColor DarkGray
    Write-Host ""
    
    # Count stats
    $runningCount = ($results | Where-Object { $_.Status -eq "running" }).Count
    $stoppedCount = ($results | Where-Object { $_.Status -ne "running" }).Count
    $healthyCount = ($results | Where-Object { $_.Health -eq "healthy" }).Count
    $totalCount = $results.Count
    
    # Display services
    foreach ($svc in ($results | Sort-Object Name)) {
        $icon = $svc.Icon
        $name = $svc.Name.PadRight(16)
        $port = if ($svc.Port) { ":$($svc.Port)".PadRight(7) } else { "       " }
        
        $statusIcon = switch ($svc.Status) {
            "running" { "●" }
            "stopped" { "○" }
            "not_found" { "○" }
            default { "◐" }
        }
        
        $statusColor = switch ($svc.Status) {
            "running" { if ($svc.Health -eq "healthy") { "Green" } else { "Yellow" } }
            "stopped" { "DarkGray" }
            "not_found" { "DarkGray" }
            default { "Yellow" }
        }
        
        $healthText = if ($svc.Health) { $svc.Health.ToUpper().PadRight(10) } else { "".PadRight(10) }
        
        Write-Host "  $icon " -NoNewline
        Write-Host "$name" -NoNewline -ForegroundColor White
        Write-Host "$port" -NoNewline -ForegroundColor DarkGray
        Write-Host "$statusIcon " -NoNewline -ForegroundColor $statusColor
        Write-Host "$healthText" -NoNewline -ForegroundColor $statusColor
        
        if ($Detailed -and $svc.Port) {
            $healthCheck = Test-ServiceHealth -Port $svc.Port
            if ($healthCheck.Healthy) {
                Write-Host " ($($healthCheck.ResponseTime)ms)" -ForegroundColor DarkGray
            } else {
                Write-Host ""
            }
        } else {
            Write-Host ""
        }
    }
    
    # Summary
    Write-Host ""
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    
    $summaryColor = if ($stoppedCount -eq 0) { "Green" } elseif ($runningCount -gt 0) { "Yellow" } else { "Red" }
    
    Write-Host "  Running: " -NoNewline
    Write-Host "$runningCount" -NoNewline -ForegroundColor Green
    Write-Host " | Healthy: " -NoNewline
    Write-Host "$healthyCount" -NoNewline -ForegroundColor $(if ($healthyCount -eq $runningCount) { "Green" } else { "Yellow" })
    Write-Host " | Stopped: " -NoNewline
    Write-Host "$stoppedCount" -NoNewline -ForegroundColor $(if ($stoppedCount -gt 0) { "Red" } else { "DarkGray" })
    Write-Host " | Total: $totalCount" -ForegroundColor DarkGray
    Write-Host ""
    
    if ($Watch -gt 0) {
        Write-Host "  Refreshing every ${Watch}s... (Ctrl+C to stop)" -ForegroundColor DarkGray
    }
    
    # Quick links
    if ($runningCount -gt 0) {
        Write-Host ""
        Write-Host "  Quick Links:" -ForegroundColor Yellow
        Write-Host "    Genesis Dashboard: http://localhost:8001/dashboard" -ForegroundColor Gray
        Write-Host "    Veil Dashboard:    http://localhost:3000" -ForegroundColor Gray
    }
    
    Write-Host ""
    
    return $results
}

# Main execution
if ($Watch -gt 0) {
    while ($true) {
        Show-Status | Out-Null
        Start-Sleep -Seconds $Watch
    }
} else {
    $results = Show-Status
    if ($Json) {
        Write-Output $results
    }
}
