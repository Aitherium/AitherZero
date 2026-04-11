#Requires -Version 7.0

<#
.SYNOPSIS
    Install (deploy) AitherOS Docker services.

.DESCRIPTION
    Performs first-time setup and deployment of AitherOS Docker infrastructure.
    Handles base image building, compose validation, network creation, volume
    provisioning, and initial service startup.

    This is the recommended way to deploy AitherOS on any platform with Docker
    and PowerShell 7+.

.PARAMETER Profile
    Which profile group to install. Default: 'all'.

.PARAMETER SkipBaseImage
    Skip building the base Docker image (if already built).

.PARAMETER SkipPull
    Skip pulling external images (Redis, Postgres, etc.).

.PARAMETER DryRun
    Show what would be done without executing.

.PARAMETER Force
    Force rebuild of all images even if they exist.

.EXAMPLE
    Install-AitherContainer
    # Full install: base image + all services

.EXAMPLE
    Install-AitherContainer -Profile core
    # Install only core services

.EXAMPLE
    Install-AitherContainer -SkipBaseImage
    # Skip base image build (already done), just start services

.EXAMPLE
    Install-AitherContainer -DryRun
    # Preview what will happen without doing anything

.NOTES
    Part of the AitherZero Docker management module.
    Requires: Docker, Docker Compose v2
    Copyright © 2025 Aitherium Corporation
#>
function Install-AitherContainer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [ValidateSet('core', 'intelligence', 'perception', 'memory', 'training',
                     'autonomic', 'security', 'agents', 'social', 'creative',
                     'gpu', 'gateway', 'mcp', 'external', 'desktop', 'all')]
        [string]$Profile = 'all',

        [Parameter()]
        [switch]$SkipBaseImage,

        [Parameter()]
        [switch]$SkipPull,

        [Parameter()]
        [switch]$DryRun,

        [Parameter()]
        [switch]$Force
    )

    $cfg = Get-AitherComposeConfig -Profile $Profile
    if (-not $cfg) { return }

    Write-Host ''
    Write-Host '  ╔══════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '  ║        AitherOS Docker Installation          ║' -ForegroundColor Cyan
    Write-Host '  ╚══════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''

    # Step 1: Verify prerequisites
    Write-Host '[1/6] Checking prerequisites...' -ForegroundColor Cyan

    $dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
    if (-not $dockerVersion) {
        Write-Error 'Docker is not running. Please start Docker Desktop or Docker Engine.'
        return
    }
    Write-Host "  Docker: v$dockerVersion" -ForegroundColor Green

    $composeVersion = docker compose version --short 2>$null
    if (-not $composeVersion) {
        Write-Error 'Docker Compose v2 is required. Install: https://docs.docker.com/compose/install/'
        return
    }
    Write-Host "  Compose: v$composeVersion" -ForegroundColor Green

    # Validate compose file
    $validateArgs = @('compose') + $cfg.BaseArgs + @('config', '--quiet')
    & docker @validateArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Compose file validation failed: $($cfg.ComposeFile)"
        return
    }
    Write-Host "  Compose file: Valid" -ForegroundColor Green

    # Step 2: Generate .env if missing
    Write-Host '[2/6] Checking environment...' -ForegroundColor Cyan
    $envFile = Join-Path $cfg.ProjectRoot '.env'
    if (-not (Test-Path $envFile)) {
        Write-Host '  Generating .env from host hardware detection...' -ForegroundColor Yellow
        $hwScript = Join-Path $cfg.ProjectRoot 'scripts/detect-host-hardware.ps1'
        if (Test-Path $hwScript) {
            if (-not $DryRun) { & pwsh -File $hwScript }
            Write-Host '  .env generated' -ForegroundColor Green
        }
        else {
            Write-Warning '  Hardware detection script not found. Using defaults.'
        }
    }
    else {
        Write-Host '  .env exists' -ForegroundColor Green
    }

    # Step 3: Build base images
    Write-Host '[3/6] Building base images...' -ForegroundColor Cyan
    if (-not $SkipBaseImage) {
        $baseDockerfile = Join-Path $cfg.ProjectRoot 'docker/base/Dockerfile.unified-base'
        if (Test-Path $baseDockerfile) {
            $baseExists = docker images -q aitheros-base:latest 2>$null
            if (-not $baseExists -or $Force) {
                if ($DryRun) {
                    Write-Host "  [DRY RUN] Would build aitheros-base:latest" -ForegroundColor DarkGray
                }
                elseif ($PSCmdlet.ShouldProcess('aitheros-base:latest', 'Build base image')) {
                    Write-Host '  Building aitheros-base:latest (this takes 5-10 min first time)...' -ForegroundColor Yellow
                    docker build -f $baseDockerfile -t aitheros-base:latest $cfg.ProjectRoot
                    if ($LASTEXITCODE -ne 0) {
                        Write-Error 'Base image build failed.'
                        return
                    }
                    Write-Host '  Base image built' -ForegroundColor Green
                }
            }
            else {
                Write-Host '  Base image exists (use -Force to rebuild)' -ForegroundColor Green
            }
        }
        else {
            Write-Host '  No unified base Dockerfile found, services will build individually' -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '  Skipped (--SkipBaseImage)' -ForegroundColor DarkGray
    }

    # Step 4: Pull external images
    Write-Host '[4/6] Pulling external images...' -ForegroundColor Cyan
    if (-not $SkipPull) {
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would pull external images" -ForegroundColor DarkGray
        }
        else {
            $pullArgs = @('compose') + $cfg.BaseArgs + @('pull', '--ignore-buildable', '--quiet')
            & docker @pullArgs 2>$null
            Write-Host '  External images pulled' -ForegroundColor Green
        }
    }
    else {
        Write-Host '  Skipped (--SkipPull)' -ForegroundColor DarkGray
    }

    # Step 5: Build service images
    Write-Host '[5/6] Building service images...' -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would build all service images" -ForegroundColor DarkGray
    }
    elseif ($PSCmdlet.ShouldProcess("$Profile profile services", 'Build')) {
        $buildArgs = @('compose') + $cfg.BaseArgs + @('build')
        if ($Force) { $buildArgs += '--no-cache' }
        & docker @buildArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error 'Service image build failed.'
            return
        }
        Write-Host '  Service images built' -ForegroundColor Green
    }

    # Step 6: Start services
    Write-Host '[6/6] Starting services...' -ForegroundColor Cyan
    if ($DryRun) {
        $svcCount = (docker compose @($cfg.BaseArgs) config --services 2>$null | Measure-Object).Count
        Write-Host "  [DRY RUN] Would start $svcCount services (profile: $Profile)" -ForegroundColor DarkGray
    }
    elseif ($PSCmdlet.ShouldProcess("$Profile profile", 'Start services')) {
        $upArgs = @('compose') + $cfg.BaseArgs + @('up', '-d')
        & docker @upArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error 'Service startup failed.'
            return
        }
        Write-Host '  Services started' -ForegroundColor Green
    }

    # Summary
    Write-Host ''
    Write-Host '  Installation complete!' -ForegroundColor Green
    Write-Host '  Run Get-AitherContainer to see service status.' -ForegroundColor DarkGray
    Write-Host '  Run Get-AitherContainerLog -Name <service> to check logs.' -ForegroundColor DarkGray
    Write-Host ''
}
