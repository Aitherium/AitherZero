#Requires -Version 7.0

<#
.SYNOPSIS
    Start AitherOS Docker containers using compose profiles.

.DESCRIPTION
    Starts AitherOS services via Docker Compose with the correct --profile flag.
    ALWAYS includes --profile to prevent orphaned container creation.

    Can start all services, a specific profile group, or individual services by name.

.PARAMETER Name
    One or more service names to start. E.g., 'moltbook', 'genesis', 'llm'.
    Maps to the compose service name (aither-{name}).

.PARAMETER Profile
    Start all services in a profile group. Defaults to 'all'.

.PARAMETER Build
    Rebuild images before starting (--build flag).

.PARAMETER NoCache
    Force full rebuild without cache (implies -Build).

.PARAMETER Detach
    Run in detached mode (default: true).

.PARAMETER Wait
    Wait for services to be healthy before returning.

.EXAMPLE
    Start-AitherContainer
    # Starts all AitherOS services (--profile all)

.EXAMPLE
    Start-AitherContainer -Name moltbook, moltroad
    # Starts specific services

.EXAMPLE
    Start-AitherContainer -Profile social
    # Starts all social services (Moltbook, Bluesky, etc.)

.EXAMPLE
    Start-AitherContainer -Name moltbook -Build
    # Rebuilds and starts moltbook

.EXAMPLE
    Start-AitherContainer -Name llm -NoCache
    # Full rebuild (no cache) and start LLM service

.NOTES
    Part of the AitherZero Docker management module.
    Copyright © 2025 Aitherium Corporation
#>
function Start-AitherContainer {
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
        [switch]$Build,

        [Parameter()]
        [switch]$NoCache,

        [Parameter()]
        [switch]$Detach = $true,

        [Parameter()]
        [switch]$Wait
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
        # Build the docker compose command
        $dockerArgs = @('compose') + $cfg.BaseArgs

        if ($NoCache -and $allNames.Count -gt 0) {
            # Two-step: build --no-cache, then up
            $buildArgs = $dockerArgs + @('build', '--no-cache')
            $serviceArgs = $allNames | ForEach-Object {
                $clean = $_.ToLower() -replace '^aither-', ''
                "aither-$clean"
            }
            $buildArgs += $serviceArgs

            $target = ($serviceArgs -join ', ')
            if ($PSCmdlet.ShouldProcess($target, 'Rebuild (no-cache)')) {
                Write-Host "Building (no-cache): $target" -ForegroundColor Yellow
                & docker @buildArgs
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Build failed for: $target"
                    return
                }
            }
        }

        $dockerArgs += 'up'
        if ($Detach) { $dockerArgs += '-d' }
        if ($Build -and -not $NoCache) { $dockerArgs += '--build' }
        if ($Wait) { $dockerArgs += '--wait' }

        # Add specific service names if provided
        if ($allNames.Count -gt 0) {
            $serviceArgs = $allNames | ForEach-Object {
                $clean = $_.ToLower() -replace '^aither-', ''
                "aither-$clean"
            }
            $dockerArgs += $serviceArgs
            $target = $serviceArgs -join ', '
        }
        else {
            $target = "all services (profile: $Profile)"
        }

        if ($PSCmdlet.ShouldProcess($target, 'Start')) {
            Write-Host "Starting: $target" -ForegroundColor Cyan
            & docker @dockerArgs

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Started successfully." -ForegroundColor Green
            }
            else {
                Write-Error "Failed to start: $target"
            }
        }
    }
}
