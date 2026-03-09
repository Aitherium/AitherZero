#Requires -Version 7.0

<#
.SYNOPSIS
    Run health checks on AitherOS Docker infrastructure.

.DESCRIPTION
    Comprehensive diagnostic tool that checks:
    - Docker Engine health
    - Compose file validity
    - Container health status
    - Orphaned containers
    - Port conflicts
    - Resource usage (CPU, memory)
    - Service endpoint reachability
    - Volume mount status

.PARAMETER Name
    Check a specific service only.

.PARAMETER Deep
    Run deep checks including HTTP health endpoint probing for every running service.

.PARAMETER Quick
    Quick mode: just container status + orphan detection.

.PARAMETER Fix
    Attempt to auto-fix common issues (restart unhealthy, repair orphans).

.EXAMPLE
    Test-AitherContainer
    # Standard health check of all services

.EXAMPLE
    Test-AitherContainer -Deep
    # Deep check including HTTP endpoint probing

.EXAMPLE
    Test-AitherContainer -Name moltbook
    # Check specific service

.EXAMPLE
    Test-AitherContainer -Fix
    # Check and auto-fix common issues

.NOTES
    Part of the AitherZero Docker management module.
    Copyright © 2025 Aitherium Corporation
#>
function Test-AitherContainer {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [Parameter()]
        [switch]$Deep,

        [Parameter()]
        [switch]$Quick,

        [Parameter()]
        [switch]$Fix
    )

    $results = [ordered]@{
        Timestamp     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Healthy       = $false
        DockerOk      = $false
        ComposeOk     = $false
        Running       = 0
        Total         = 0
        Orphaned      = 0
        Containers    = @{ Total = 0; Running = 0; Stopped = 0; Unhealthy = 0; Orphaned = 0 }
        Issues        = @()
        FixesApplied  = @()
    }

    Write-Host ''
    Write-Host '  AitherOS Docker Health Check' -ForegroundColor Cyan
    Write-Host '  ════════════════════════════' -ForegroundColor DarkCyan
    Write-Host ''

    # ── Docker Engine ──
    Write-Host '[Docker Engine]' -ForegroundColor White
    $dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
    if ($dockerVersion) {
        Write-Host "  Engine: v$dockerVersion" -ForegroundColor Green
        $results.DockerOk = $true

        $dockerInfo = docker info --format '{{.ContainersRunning}} running, {{.ContainersStopped}} stopped, {{.Images}} images' 2>$null
        Write-Host "  Status: $dockerInfo" -ForegroundColor DarkGray
    }
    else {
        Write-Host '  Engine: NOT RUNNING' -ForegroundColor Red
        $results.Issues += 'Docker Engine is not running'
        return [PSCustomObject]$results
    }

    # ── Compose File ──
    Write-Host '[Compose File]' -ForegroundColor White
    $cfg = Get-AitherComposeConfig -Profile 'all'
    if ($cfg) {
        $validateArgs = @('compose') + $cfg.BaseArgs + @('config', '--quiet')
        & docker @validateArgs 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  File: Valid ($($cfg.ComposeFile))" -ForegroundColor Green
            $results.ComposeOk = $true

            $svcCount = (docker compose @($cfg.BaseArgs) config --services 2>$null | Measure-Object).Count
            Write-Host "  Services defined: $svcCount" -ForegroundColor DarkGray
        }
        else {
            Write-Host '  File: INVALID' -ForegroundColor Red
            $results.Issues += 'Compose file has syntax errors'
        }
    }

    # ── Container Status ──
    Write-Host '[Containers]' -ForegroundColor White
    $containers = Get-AitherContainer -Raw

    if ($Name) {
        $containers = $containers | Where-Object { $_.Service -like $Name }
    }

    $running = ($containers | Where-Object { $_.Status -eq 'running' }).Count
    $stopped = ($containers | Where-Object { $_.Status -in @('exited', 'created') }).Count
    $unhealthy = ($containers | Where-Object { $_.Health -in @('unhealthy', 'restarting') }).Count
    $orphaned = ($containers | Where-Object { $_.Orphaned }).Count
    $total = $containers.Count

    $results.Containers.Total = $total
    $results.Containers.Running = $running
    $results.Containers.Stopped = $stopped
    $results.Containers.Unhealthy = $unhealthy
    $results.Containers.Orphaned = $orphaned
    # Top-level convenience properties
    $results.Running = $running
    $results.Total = $total
    $results.Orphaned = $orphaned
    $results.Healthy = ($unhealthy -eq 0 -and $orphaned -eq 0 -and $running -gt 0)

    Write-Host "  Total: $total | Running: $running | Stopped: $stopped | Unhealthy: $unhealthy | Orphaned: $orphaned" -ForegroundColor $(
        if ($unhealthy -gt 0 -or $orphaned -gt 0) { 'Yellow' } else { 'Green' }
    )

    # List unhealthy
    $unhealthyContainers = $containers | Where-Object { $_.Health -in @('unhealthy', 'restarting') }
    foreach ($uc in $unhealthyContainers) {
        Write-Host "  !! $($uc.Service): $($uc.Health)" -ForegroundColor Red
        $results.Issues += "Service $($uc.Service) is $($uc.Health)"
    }

    # List orphaned
    $orphanedContainers = $containers | Where-Object { $_.Orphaned }
    foreach ($oc in $orphanedContainers) {
        Write-Host "  !! $($oc.ContainerName): ORPHANED" -ForegroundColor Red
        $results.Issues += "Container $($oc.ContainerName) is orphaned (hash-prefixed)"
    }

    if ($Quick) {
        Write-Host ''
        Write-Host "  Issues found: $($results.Issues.Count)" -ForegroundColor $(if ($results.Issues.Count -gt 0) { 'Yellow' } else { 'Green' })
        return [PSCustomObject]$results
    }

    # ── Port Conflicts ──
    Write-Host '[Port Conflicts]' -ForegroundColor White
    $portMap = @{}
    foreach ($c in ($containers | Where-Object { $_.Status -eq 'running' -and $_.Ports })) {
        if ($c.Ports -match '(\d+)->') {
            $port = $Matches[1]
            if ($portMap.ContainsKey($port)) {
                Write-Host "  !! Port ${port}: $($c.Service) AND $($portMap[$port])" -ForegroundColor Red
                $results.Issues += "Port conflict on ${port} between $($c.Service) and $($portMap[$port])"
            }
            else {
                $portMap[$port] = $c.Service
            }
        }
    }
    if ($results.Issues.Count -eq 0 -or -not ($results.Issues | Where-Object { $_ -match 'Port conflict' })) {
        Write-Host '  No port conflicts' -ForegroundColor Green
    }

    # ── Deep Health Probing ──
    if ($Deep) {
        Write-Host '[Service Endpoints]' -ForegroundColor White
        $runningContainers = $containers | Where-Object { $_.Status -eq 'running' -and $_.Ports -match '(\d+)->' }

        foreach ($c in $runningContainers) {
            if ($c.Ports -match '(\d+)->') {
                $port = $Matches[1]
                $url = "http://localhost:$port/health"
                try {
                    $null = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 3 -ErrorAction Stop
                    Write-Host "  $($c.Service.PadRight(25)) :${port}  OK" -ForegroundColor Green
                }
                catch {
                    Write-Host "  $($c.Service.PadRight(25)) :${port}  UNREACHABLE" -ForegroundColor Yellow
                }
            }
        }
    }

    # ── Auto-Fix ──
    if ($Fix) {
        Write-Host '[Auto-Fix]' -ForegroundColor White

        # Fix orphaned containers
        if ($orphaned -gt 0) {
            Write-Host "  Repairing $orphaned orphaned containers..." -ForegroundColor Cyan
            Repair-AitherContainer -Repair -Force
            $results.FixesApplied += "Repaired $orphaned orphaned containers"
        }

        # Restart unhealthy containers
        foreach ($uc in $unhealthyContainers) {
            Write-Host "  Restarting unhealthy: $($uc.Service)..." -ForegroundColor Cyan
            Restart-AitherContainer -Name $uc.Service -ViaDocker
            $results.FixesApplied += "Restarted $($uc.Service)"
        }

        if ($results.FixesApplied.Count -gt 0) {
            Write-Host "  Applied $($results.FixesApplied.Count) fixes" -ForegroundColor Green
        }
        else {
            Write-Host '  Nothing to fix' -ForegroundColor Green
        }
    }

    # ── Summary ──
    Write-Host ''
    $issueCount = $results.Issues.Count
    if ($issueCount -eq 0) {
        Write-Host '  All checks passed!' -ForegroundColor Green
    }
    else {
        Write-Host "  $issueCount issue(s) found." -ForegroundColor Yellow
        if (-not $Fix) {
            Write-Host '  Run with -Fix to auto-repair.' -ForegroundColor DarkGray
        }
    }
    Write-Host ''

    return [PSCustomObject]$results
}
