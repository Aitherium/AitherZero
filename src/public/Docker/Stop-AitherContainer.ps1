#Requires -Version 7.0

<#
.SYNOPSIS
    Stop AitherOS Docker containers.

.DESCRIPTION
    Stops AitherOS services via Docker Compose or direct Docker stop.
    When using compose, ALWAYS includes --profile to prevent orphan issues.

.PARAMETER Name
    One or more service names to stop. E.g., 'moltbook', 'llm'.

.PARAMETER Profile
    Stop all services in a profile group.

.PARAMETER All
    Stop ALL AitherOS containers (compose down --profile all).

.PARAMETER Remove
    Also remove stopped containers (compose down vs stop).

.PARAMETER Timeout
    Seconds to wait for graceful shutdown before killing. Default: 30.

.EXAMPLE
    Stop-AitherContainer -Name moltbook
    # Stops the moltbook container

.EXAMPLE
    Stop-AitherContainer -All
    # Stops all AitherOS containers

.EXAMPLE
    Stop-AitherContainer -All -Remove
    # Stops and removes all containers (compose down)

.EXAMPLE
    Stop-AitherContainer -Profile social
    # Stops all social profile services

.NOTES
    Part of the AitherZero Docker management module.
    Copyright © 2025 Aitherium Corporation
#>
function Stop-AitherContainer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Service', 'ServiceName')]
        [string[]]$Name,

        [Parameter()]
        [ValidateSet('core', 'intelligence', 'perception', 'memory', 'training',
                     'autonomic', 'security', 'agents', 'social', 'creative',
                     'gpu', 'gateway', 'mcp', 'external', 'desktop', 'all')]
        [string]$Profile = 'all',

        [Parameter()]
        [switch]$All,

        [Parameter()]
        [switch]$Remove,

        [Parameter()]
        [int]$Timeout = 30
    )

    begin {
        $cfg = Get-AitherComposeConfig -Profile $Profile
        if (-not $cfg) { return }
        $allNames = @()
    }

    process {
        if ($Name) { $allNames += $Name }
    }

    end {
        if ($All -or ($allNames.Count -eq 0 -and -not $Name)) {
            # Full compose down/stop
            $dockerArgs = @('compose') + $cfg.BaseArgs

            if ($Remove) {
                $dockerArgs += @('down', '--timeout', $Timeout.ToString())
                $action = 'Stop and remove all containers'
            }
            else {
                $dockerArgs += @('stop', '--timeout', $Timeout.ToString())
                $action = 'Stop all containers'
            }

            if ($PSCmdlet.ShouldProcess('all AitherOS services', $action)) {
                Write-Host "$action..." -ForegroundColor Yellow
                & docker @dockerArgs
                if ($LASTEXITCODE -eq 0) {
                    Write-Host 'All services stopped.' -ForegroundColor Green
                }
                else {
                    Write-Error 'Failed to stop services.'
                }
            }
        }
        else {
            # Stop specific services
            foreach ($svc in $allNames) {
                $svcClean = $svc.ToLower() -replace '^aitheros-', '' -replace '^aither-', ''
                $containerName = "aitheros-$svcClean"

                if ($PSCmdlet.ShouldProcess($containerName, 'Stop')) {
                    Write-Host "Stopping $containerName..." -ForegroundColor Yellow
                    docker stop --time $Timeout $containerName 2>&1 | Out-Null

                    if ($Remove) {
                        docker rm $containerName 2>&1 | Out-Null
                    }

                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "Stopped $containerName" -ForegroundColor Green
                    }
                    else {
                        Write-Warning "Failed to stop $containerName"
                    }
                }
            }
        }
    }
}
