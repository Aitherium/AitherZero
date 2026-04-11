#Requires -Version 7.0

<#
.SYNOPSIS
    Restart AitherOS Docker containers.

.DESCRIPTION
    Restarts AitherOS services. Tries Genesis API first for graceful dependency-aware
    restart, falls back to Docker Compose with correct --profile flags.

.PARAMETER Name
    One or more service names to restart. Required.

.PARAMETER Profile
    The compose profile to use. Defaults to 'all'.

.PARAMETER Build
    Rebuild images before restarting.

.PARAMETER NoCache
    Force full rebuild without cache (implies -Build).

.PARAMETER ViaGenesis
    Force restart via Genesis API (default: auto-detect).

.PARAMETER ViaDocker
    Force restart via direct Docker (skip Genesis).

.EXAMPLE
    Restart-AitherContainer -Name moltbook
    # Restarts moltbook (tries Genesis first, falls back to Docker)

.EXAMPLE
    Restart-AitherContainer -Name llm -Build
    # Rebuilds and restarts the LLM service

.EXAMPLE
    Restart-AitherContainer -Name genesis -ViaDocker
    # Restarts Genesis directly via Docker (can't restart itself via API)

.EXAMPLE
    'moltbook', 'moltroad' | Restart-AitherContainer
    # Pipeline restart of multiple services

.NOTES
    Part of the AitherZero Docker management module.
    Copyright © 2025 Aitherium Corporation
#>
function Restart-AitherContainer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
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
        [switch]$ViaGenesis,

        [Parameter()]
        [switch]$ViaDocker
    )

    begin {
        $cfg = Get-AitherComposeConfig -Profile $Profile
        if (-not $cfg) { return }

        # Check if Genesis is reachable (unless forced to Docker)
        $genesisAvailable = $false
        if (-not $ViaDocker) {
            try {
                $null = Invoke-RestMethod -Uri 'http://localhost:8001/health' -Method Get -TimeoutSec 3 -ErrorAction Stop
                $genesisAvailable = $true
            }
            catch {
                $genesisAvailable = $false
            }
        }
    }

    process {
        foreach ($svc in $Name) {
            $svcClean = $svc.ToLower() -replace '^aitheros-', '' -replace '^aither-', ''
            $containerName = "aitheros-$svcClean"
            $composeSvc = "aither-$svcClean"

            if (-not $PSCmdlet.ShouldProcess($containerName, 'Restart')) { continue }

            # If rebuild requested, use compose
            if ($Build -or $NoCache) {
                Write-Host "Rebuilding and restarting $containerName..." -ForegroundColor Cyan

                if ($NoCache) {
                    $buildArgs = @('compose') + $cfg.BaseArgs + @('build', '--no-cache', $composeSvc)
                    & docker @buildArgs
                    if ($LASTEXITCODE -ne 0) {
                        Write-Error "Build failed for $containerName"
                        continue
                    }
                }

                $upArgs = @('compose') + $cfg.BaseArgs + @('up', '-d')
                if ($Build -and -not $NoCache) { $upArgs += '--build' }
                $upArgs += $composeSvc
                & docker @upArgs

                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Rebuilt and restarted $containerName" -ForegroundColor Green
                }
                else {
                    Write-Error "Failed to restart $containerName"
                }
                continue
            }

            # Try Genesis API for graceful restart (handles dependencies)
            if (($genesisAvailable -or $ViaGenesis) -and -not $ViaDocker -and $svcClean -ne 'genesis') {
                # Genesis expects PascalCase service name like "AitherMoltbook"
                $pascalName = 'Aither' + (Get-Culture).TextInfo.ToTitleCase($svcClean)
                $url = "http://localhost:8001/services/$pascalName/restart"

                Write-Host "Restarting $containerName via Genesis..." -ForegroundColor Cyan
                try {
                    $null = Invoke-RestMethod -Uri $url -Method Post -TimeoutSec 10 -ErrorAction Stop
                    Write-Host "Restarted $containerName (via Genesis)" -ForegroundColor Green
                    continue
                }
                catch {
                    Write-Warning "Genesis restart failed for $containerName, falling back to Docker..."
                }
            }

            # Fallback: Docker compose restart (profile-safe)
            Write-Host "Restarting $containerName via Docker..." -ForegroundColor Cyan
            $dockerArgs = @('compose') + $cfg.BaseArgs + @('restart', $composeSvc)
            & docker @dockerArgs

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Restarted $containerName" -ForegroundColor Green
            }
            else {
                Write-Error "Failed to restart $containerName"
            }
        }
    }
}
