#Requires -Version 7.0

<#
.SYNOPSIS
    Uninstall (teardown) AitherOS Docker services.

.DESCRIPTION
    Stops and removes all AitherOS Docker containers, optionally removing images,
    volumes, and networks. Use this for clean teardown or fresh reinstall.

.PARAMETER RemoveImages
    Also remove all aitheros Docker images.

.PARAMETER RemoveVolumes
    Also remove named Docker volumes (WARNING: destroys data).

.PARAMETER RemoveNetworks
    Also remove the aither-network Docker network.

.PARAMETER RemoveAll
    Remove everything: containers, images, volumes, networks. Nuclear option.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER KeepData
    Keep the data volumes even when using -RemoveAll (preserves secrets, chronicle, etc.).

.EXAMPLE
    Uninstall-AitherContainer
    # Stops and removes all containers only

.EXAMPLE
    Uninstall-AitherContainer -RemoveImages
    # Removes containers and images

.EXAMPLE
    Uninstall-AitherContainer -RemoveAll
    # Full teardown: containers, images, volumes, networks

.EXAMPLE
    Uninstall-AitherContainer -RemoveAll -KeepData
    # Full teardown but preserve data volumes

.NOTES
    Part of the AitherZero Docker management module.
    Copyright © 2025 Aitherium Corporation
#>
function Uninstall-AitherContainer {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter()]
        [switch]$RemoveImages,

        [Parameter()]
        [switch]$RemoveVolumes,

        [Parameter()]
        [switch]$RemoveNetworks,

        [Parameter()]
        [switch]$RemoveAll,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$KeepData
    )

    $cfg = Get-AitherComposeConfig -Profile 'all'
    if (-not $cfg) { return }

    if ($RemoveAll) {
        $RemoveImages = $true
        $RemoveVolumes = -not $KeepData
        $RemoveNetworks = $true
    }

    # Confirmation for destructive operations
    if (($RemoveVolumes -or $RemoveAll) -and -not $Force) {
        Write-Warning 'This will PERMANENTLY DELETE data volumes (secrets, chronicle, memory, etc.).'
        $confirm = Read-Host 'Type "yes" to confirm'
        if ($confirm -ne 'yes') {
            Write-Host 'Aborted.' -ForegroundColor Yellow
            return
        }
    }

    # Step 1: Stop and remove containers
    if ($PSCmdlet.ShouldProcess('all AitherOS containers', 'Stop and remove')) {
        Write-Host 'Stopping and removing all AitherOS containers...' -ForegroundColor Yellow
        $downArgs = @('compose') + $cfg.BaseArgs + @('down', '--timeout', '30')
        if ($RemoveVolumes) { $downArgs += '--volumes' }
        & docker @downArgs

        # Also clean up any orphaned containers
        $orphans = docker ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -match 'aitheros-' }
        foreach ($orphan in $orphans) {
            Write-Host "  Removing orphan: $orphan" -ForegroundColor DarkGray
            docker rm -f $orphan 2>$null | Out-Null
        }
        Write-Host 'Containers removed.' -ForegroundColor Green
    }

    # Step 2: Remove images
    if ($RemoveImages) {
        if ($PSCmdlet.ShouldProcess('all aitheros images', 'Remove')) {
            Write-Host 'Removing AitherOS Docker images...' -ForegroundColor Yellow
            $images = docker images --format '{{.Repository}}:{{.Tag}}' 2>$null |
                Where-Object { $_ -match '^aitheros-' }
            foreach ($img in $images) {
                docker rmi $img 2>$null | Out-Null
                Write-Host "  Removed: $img" -ForegroundColor DarkGray
            }

            # Also remove base images
            foreach ($base in @('aitheros-base:latest', 'aitheros-base-ml:latest', 'aitheros-base-browser:latest')) {
                if (docker images -q $base 2>$null) {
                    docker rmi $base 2>$null | Out-Null
                    Write-Host "  Removed: $base" -ForegroundColor DarkGray
                }
            }
            Write-Host 'Images removed.' -ForegroundColor Green
        }
    }

    # Step 3: Remove networks
    if ($RemoveNetworks) {
        if ($PSCmdlet.ShouldProcess('aither-network', 'Remove network')) {
            Write-Host 'Removing Docker network...' -ForegroundColor Yellow
            docker network rm aither-network 2>$null | Out-Null
            Write-Host 'Network removed.' -ForegroundColor Green
        }
    }

    Write-Host ''
    Write-Host 'AitherOS Docker teardown complete.' -ForegroundColor Green
    if (-not $RemoveImages) {
        Write-Host 'Images kept. Run with -RemoveImages to also clean images.' -ForegroundColor DarkGray
    }
    if (-not $RemoveVolumes) {
        Write-Host 'Data volumes kept. Run with -RemoveVolumes to also delete data.' -ForegroundColor DarkGray
    }
    Write-Host 'Run Install-AitherContainer to redeploy.' -ForegroundColor DarkGray
}
