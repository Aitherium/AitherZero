#Requires -Version 7.0

<#
.SYNOPSIS
    Get the status of AitherOS Docker containers.

.DESCRIPTION
    Lists all AitherOS containers with their status, health, ports, CPU/memory usage,
    and uptime. Detects orphaned containers (hash-prefixed names) and warns about them.

    Supports filtering by name, profile, status (running/stopped/unhealthy), and
    pipeline output for further processing.

.PARAMETER Name
    Filter by service name (supports wildcards). E.g., 'moltbook', '*social*', 'genesis'.

.PARAMETER Profile
    Filter to services belonging to a specific compose profile.

.PARAMETER Running
    Show only running containers.

.PARAMETER Stopped
    Show only stopped/exited containers.

.PARAMETER Unhealthy
    Show only unhealthy or restarting containers.

.PARAMETER Orphaned
    Show only orphaned containers (hash-prefixed names not managed by compose).

.PARAMETER Raw
    Return raw PSCustomObjects instead of formatted table output.

.EXAMPLE
    Get-AitherContainer
    # Lists all AitherOS containers with status

.EXAMPLE
    Get-AitherContainer -Running
    # Lists only running containers

.EXAMPLE
    Get-AitherContainer -Unhealthy
    # Lists containers that are unhealthy or restarting

.EXAMPLE
    Get-AitherContainer -Name '*mcp*'
    # Lists all MCP-related containers

.EXAMPLE
    Get-AitherContainer -Orphaned
    # Detects orphaned/hash-prefixed containers (the bug we fixed)

.NOTES
    Part of the AitherZero Docker management module.
    Copyright © 2025 Aitherium Corporation
#>
function Get-AitherContainer {
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string]$Name,

        [Parameter()]
        [ValidateSet('core', 'intelligence', 'perception', 'memory', 'training',
                     'autonomic', 'security', 'agents', 'social', 'creative',
                     'gpu', 'gateway', 'mcp', 'external', 'desktop', 'all')]
        [string]$Profile,

        [Parameter(ParameterSetName = 'Running')]
        [switch]$Running,

        [Parameter(ParameterSetName = 'Stopped')]
        [switch]$Stopped,

        [Parameter(ParameterSetName = 'Unhealthy')]
        [switch]$Unhealthy,

        [Parameter(ParameterSetName = 'Orphaned')]
        [switch]$Orphaned,

        [Parameter()]
        [switch]$Raw
    )

    # Verify Docker is available
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Error 'Docker is not installed or not in PATH.'
        return
    }

    # Get all aitheros containers
    $format = '{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}\t{{.State}}'
    $rawLines = docker ps -a --filter "name=aitheros" --format $format 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker command failed: $rawLines"
        return
    }

    $containers = @()
    foreach ($line in $rawLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\t'
        if ($parts.Count -lt 5) { continue }

        $containerName = $parts[0]
        $isOrphaned = $containerName -match '^\w{12}_aitheros-'
        $cleanName = if ($isOrphaned) { ($containerName -split '_', 2)[1] } else { $containerName }
        $serviceName = $cleanName -replace '^aitheros-', ''

        # Parse health from status string
        $statusStr = $parts[1]
        $health = if ($statusStr -match '\(healthy\)') { 'healthy' }
                  elseif ($statusStr -match '\(unhealthy\)') { 'unhealthy' }
                  elseif ($statusStr -match '\(starting\)') { 'starting' }
                  elseif ($statusStr -match 'Restarting') { 'restarting' }
                  elseif ($parts[4] -eq 'exited') { 'stopped' }
                  else { 'unknown' }

        $containers += [PSCustomObject]@{
            PSTypeName    = 'AitherOS.Container'
            Service       = $serviceName
            ContainerName = $containerName
            Status        = $parts[4]  # running, exited, restarting, created
            Health        = $health
            StatusDetail  = $statusStr
            Image         = $parts[2]
            Ports         = $parts[3]
            Orphaned      = $isOrphaned
        }
    }

    # Apply filters
    if ($Name) {
        $containers = $containers | Where-Object { $_.Service -like $Name -or $_.ContainerName -like $Name }
    }

    if ($Running) {
        $containers = $containers | Where-Object { $_.Status -eq 'running' }
    }
    elseif ($Stopped) {
        $containers = $containers | Where-Object { $_.Status -in @('exited', 'created') }
    }
    elseif ($Unhealthy) {
        $containers = $containers | Where-Object { $_.Health -in @('unhealthy', 'restarting') }
    }
    elseif ($Orphaned) {
        $containers = $containers | Where-Object { $_.Orphaned }
    }

    # Sort by service name
    $containers = $containers | Sort-Object Service

    # Warn about orphaned containers
    $orphanCount = ($containers | Where-Object Orphaned).Count
    if ($orphanCount -gt 0 -and -not $Orphaned) {
        Write-Warning "$orphanCount orphaned container(s) detected (hash-prefixed names). Run 'Repair-AitherContainer' to fix."
    }

    if ($Raw) {
        return $containers
    }

    # Formatted output
    if ($containers.Count -eq 0) {
        Write-Host 'No AitherOS containers found matching criteria.' -ForegroundColor Yellow
        return
    }

    foreach ($c in $containers) {
        $statusColor = switch ($c.Health) {
            'healthy'    { 'Green' }
            'starting'   { 'Cyan' }
            'unhealthy'  { 'Red' }
            'restarting' { 'Yellow' }
            'stopped'    { 'DarkGray' }
            default      { 'Gray' }
        }
        $orphanTag = if ($c.Orphaned) { ' [ORPHANED]' } else { '' }
        $icon = switch ($c.Health) {
            'healthy'    { '[OK]' }
            'starting'   { '[..]' }
            'unhealthy'  { '[!!]' }
            'restarting' { '[~~]' }
            'stopped'    { '[--]' }
            default      { '[??]' }
        }

        Write-Host "$icon " -ForegroundColor $statusColor -NoNewline
        Write-Host "$($c.Service.PadRight(28))" -ForegroundColor White -NoNewline
        Write-Host "$($c.Health.PadRight(12))" -ForegroundColor $statusColor -NoNewline
        if ($orphanTag) {
            Write-Host $orphanTag -ForegroundColor Red -NoNewline
        }
        Write-Host " $($c.Ports)" -ForegroundColor DarkGray
    }

    Write-Host "`n  Total: $($containers.Count) containers" -ForegroundColor DarkGray
    $runCount = ($containers | Where-Object { $_.Status -eq 'running' }).Count
    $stoppedCount = ($containers | Where-Object { $_.Status -ne 'running' }).Count
    Write-Host "  Running: $runCount  Stopped: $stoppedCount" -ForegroundColor DarkGray

    # Return objects for pipeline
    return $containers
}
