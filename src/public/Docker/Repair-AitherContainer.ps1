#Requires -Version 7.0

<#
.SYNOPSIS
    Detect and repair orphaned AitherOS Docker containers.

.DESCRIPTION
    Finds containers with hash-prefixed names (e.g., 04f7a44d9008_aitheros-moltbook)
    that occur when Docker Compose loses track of containers. This typically happens
    when compose commands are run without --profile on a profiled compose file.

    In detection mode, reports orphaned containers without changing anything.
    In repair mode, stops orphans, removes them, and recreates with clean names.

.PARAMETER Repair
    Actually fix the orphaned containers. Without this, only reports findings.

.PARAMETER Profile
    The compose profile to use when recreating. Default: 'all'.

.PARAMETER Force
    Skip confirmation prompts during repair.

.EXAMPLE
    Repair-AitherContainer
    # Detect orphaned containers (dry run)

.EXAMPLE
    Repair-AitherContainer -Repair
    # Fix all orphaned containers

.EXAMPLE
    Repair-AitherContainer -Repair -Force
    # Fix without confirmation prompts

.NOTES
    This function exists because ALL services in the compose file use
    profiles. Running 'docker compose up' without --profile sees ZERO services,
    causing Docker to create new containers with hash-prefixed names instead of
    reusing existing ones.

    PREVENTION: Always use --profile (or this module's functions which do it automatically).
    Copyright © 2025 Aitherium Corporation
#>
function Repair-AitherContainer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]$Repair,

        [Parameter()]
        [ValidateSet('core', 'intelligence', 'perception', 'memory', 'training',
                     'autonomic', 'security', 'agents', 'social', 'creative',
                     'gpu', 'gateway', 'mcp', 'external', 'desktop', 'all')]
        [string]$Profile = 'all',

        [Parameter()]
        [switch]$Force
    )

    $cfg = Get-AitherComposeConfig -Profile $Profile
    if (-not $cfg) { return }

    Write-Host 'Scanning for orphaned containers...' -ForegroundColor Cyan

    # Find all containers (running or stopped) with hash-prefixed names
    $allNames = docker ps -a --filter 'name=aitheros' --format '{{.Names}}\t{{.State}}' 2>&1
    $orphans = @()
    $stoppedDuplicates = @()

    foreach ($line in $allNames) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\t'
        $name = $parts[0]
        $state = if ($parts.Count -gt 1) { $parts[1] } else { 'unknown' }

        if ($name -match '^[0-9a-f]{12}_aitheros-(.+)$') {
            $serviceName = $Matches[1]
            $orphans += [PSCustomObject]@{
                ContainerName = $name
                ServiceName   = $serviceName
                CleanName     = "aitheros-$serviceName"
                ComposeSvc    = "aither-$serviceName"
                State         = $state
            }
        }
    }

    # Also find stopped duplicates that block clean names
    foreach ($orphan in $orphans) {
        $cleanState = docker inspect --format '{{.State.Status}}' $orphan.CleanName 2>$null
        if ($cleanState -and $cleanState -ne 'running') {
            $stoppedDuplicates += $orphan.CleanName
        }
    }

    # Report findings
    if ($orphans.Count -eq 0) {
        Write-Host 'No orphaned containers found. Everything looks clean!' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host "Found $($orphans.Count) orphaned container(s):" -ForegroundColor Yellow
    foreach ($o in $orphans) {
        $stateColor = if ($o.State -eq 'running') { 'Green' } else { 'DarkGray' }
        Write-Host "  $($o.ContainerName)" -ForegroundColor Red -NoNewline
        Write-Host " ($($o.State))" -ForegroundColor $stateColor -NoNewline
        Write-Host " -> should be: $($o.CleanName)" -ForegroundColor DarkGray
    }

    if ($stoppedDuplicates.Count -gt 0) {
        Write-Host ''
        Write-Host "$($stoppedDuplicates.Count) stopped duplicate(s) blocking clean names:" -ForegroundColor Yellow
        foreach ($d in $stoppedDuplicates) {
            Write-Host "  $d (stopped)" -ForegroundColor DarkGray
        }
    }

    if (-not $Repair) {
        Write-Host ''
        Write-Host 'Run with -Repair to fix these containers.' -ForegroundColor Cyan
        Write-Host 'This will: stop orphans -> remove orphans -> remove stopped duplicates -> recreate with clean names' -ForegroundColor DarkGray
        return
    }

    # Confirmation
    if (-not $Force) {
        Write-Host ''
        $confirm = Read-Host "Fix $($orphans.Count) orphaned containers? (y/n)"
        if ($confirm -notin @('y', 'yes')) {
            Write-Host 'Aborted.' -ForegroundColor Yellow
            return
        }
    }

    # Step 1: Remove stopped duplicates that block clean names
    if ($stoppedDuplicates.Count -gt 0) {
        Write-Host ''
        Write-Host 'Removing stopped duplicates...' -ForegroundColor Yellow
        foreach ($dup in $stoppedDuplicates) {
            if ($PSCmdlet.ShouldProcess($dup, 'Remove stopped duplicate')) {
                docker rm $dup 2>$null | Out-Null
                Write-Host "  Removed: $dup" -ForegroundColor DarkGray
            }
        }
    }

    # Step 2: Stop and remove orphaned containers
    Write-Host 'Stopping orphaned containers...' -ForegroundColor Yellow
    $orphanNames = $orphans | ForEach-Object { $_.ContainerName }
    if ($PSCmdlet.ShouldProcess(($orphanNames -join ', '), 'Stop and remove')) {
        docker stop @orphanNames 2>$null | Out-Null
        docker rm @orphanNames 2>$null | Out-Null
        Write-Host "  Removed $($orphanNames.Count) orphaned containers" -ForegroundColor Green
    }

    # Step 3: Recreate with clean names via compose (with profile!)
    $composeSvcs = $orphans | ForEach-Object { $_.ComposeSvc } | Sort-Object -Unique
    Write-Host 'Recreating with clean names...' -ForegroundColor Cyan

    if ($PSCmdlet.ShouldProcess(($composeSvcs -join ', '), 'Recreate via compose')) {
        $upArgs = @('compose') + $cfg.BaseArgs + @('up', '-d') + $composeSvcs
        & docker @upArgs

        if ($LASTEXITCODE -eq 0) {
            Write-Host ''
            Write-Host "Successfully repaired $($orphans.Count) containers!" -ForegroundColor Green

            # Verify
            $stillOrphaned = docker ps -a --format '{{.Names}}' 2>$null |
                Where-Object { $_ -match '^\w{12}_aitheros-' }
            if ($stillOrphaned) {
                Write-Warning "Some orphans remain: $($stillOrphaned -join ', ')"
            }
            else {
                Write-Host 'All containers have clean names.' -ForegroundColor Green
            }
        }
        else {
            Write-Error 'Compose recreate failed. Check docker compose logs for details.'
        }
    }
}
