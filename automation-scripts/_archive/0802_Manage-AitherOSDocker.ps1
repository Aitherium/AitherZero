#Requires -Version 7.0
<#
.SYNOPSIS
    Manage AitherOS Docker deployment.
.DESCRIPTION
    Orchestrates the AitherOS ecosystem using Docker Compose.
    Provides easy commands for starting, stopping, and managing services.

.PARAMETER Action
    Action to perform:
    - Up: Start services
    - Down: Stop services
    - Build: Build images
    - Logs: View logs
    - Status: Show service status
    - Exec: Execute command in container
    - Pull: Pull latest images

.PARAMETER Profiles
    Service profiles to include. Options:
    - core: Node, Pulse, Watch, Secrets, Veil
    - intelligence: Mind, Reasoning, Judge, Flow, Will, Council, Tag
    - perception: Vision, Voice, Portal
    - memory: WorkingMemory, Chain, Enviro, Context
    - training: Prism, Trainer, Harvest
    - autonomic: Autonomic, Reflex, Scheduler, Demand, Force
    - gpu: Parallel, Accel (requires nvidia-docker)
    - gateway: Gateway, A2A
    - external: Redis, Postgres, Ollama
    - all: Everything

.PARAMETER Service
    Specific service for Logs or Exec action

.PARAMETER Command
    Command to execute (for Exec action)

.PARAMETER Detach
    Run in background (default for Up)

.PARAMETER Follow
    Follow log output

.EXAMPLE
    ./0802_Manage-AitherOSDocker.ps1 -Action Up -Profiles core
    Start core services

.EXAMPLE
    ./0802_Manage-AitherOSDocker.ps1 -Action Up -Profiles core,intelligence
    Start core and intelligence services

.EXAMPLE
    ./0802_Manage-AitherOSDocker.ps1 -Action Logs -Service aither-node -Follow
    Follow logs for aither-node

.EXAMPLE
    ./0802_Manage-AitherOSDocker.ps1 -Action Status
    Show status of all services

.NOTES
    Stage: Docker Operations
    Order: 0802
    Tags: aitheros, docker, services, deployment
    Dependencies: Docker, docker-compose
#>
[CmdletBinding()]
param(
    [ValidateSet('Up', 'Down', 'Build', 'Logs', 'Status', 'Exec', 'Pull', 'Restart', 'Clean')]
    [string]$Action = 'Status',

    [ValidateSet('core', 'intelligence', 'perception', 'memory', 'training', 'autonomic', 'gpu', 'gateway', 'external', 'all')]
    [string[]]$Profiles = @('core'),

    [string]$Service,

    [string]$Command,

    [switch]$Detach = $true,

    [switch]$Follow,

    [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/_init.ps1"

# Compose file
$ComposeFile = Join-Path $projectRoot "docker-compose.aitheros.yml"

if (-not (Test-Path $ComposeFile)) {
    Write-Error "Docker compose file not found: $ComposeFile"
    exit 1
}

# Build profile arguments
$ProfileArgs = @()
foreach ($p in $Profiles) {
    $ProfileArgs += "--profile"
    $ProfileArgs += $p
}

function Write-Log {
    param([string]$Msg, [string]$Level = "Info")
    if (-not $ShowOutput) { return }
    $icon = switch ($Level) { "OK" { "✓" } "Err" { "✗" } "Warn" { "⚠" } default { "○" } }
    $color = switch ($Level) { "OK" { "Green" } "Err" { "Red" } "Warn" { "Yellow" } default { "Cyan" } }
    Write-Host "[$icon] $Msg" -ForegroundColor $color
}

function Invoke-Compose {
    param([string[]]$Args)
    $cmd = @("docker", "compose", "-f", $ComposeFile) + $ProfileArgs + $Args
    if ($ShowOutput) {
        Write-Host "Running: $($cmd -join ' ')" -ForegroundColor DarkGray
    }
    & $cmd[0] $cmd[1..($cmd.Length-1)]
}

switch ($Action) {
    'Up' {
        Write-Log "Starting AitherOS services (profiles: $($Profiles -join ', '))..." "Info"
        $args = @("up")
        if ($Detach) { $args += "-d" }
        Invoke-Compose $args
        Write-Log "Services started" "OK"
    }

    'Down' {
        Write-Log "Stopping AitherOS services..." "Info"
        Invoke-Compose @("down")
        Write-Log "Services stopped" "OK"
    }

    'Restart' {
        Write-Log "Restarting AitherOS services..." "Info"
        if ($Service) {
            Invoke-Compose @("restart", $Service)
        } else {
            Invoke-Compose @("down")
            Start-Sleep -Seconds 2
            $args = @("up")
            if ($Detach) { $args += "-d" }
            Invoke-Compose $args
        }
        Write-Log "Services restarted" "OK"
    }

    'Build' {
        Write-Log "Building AitherOS images..." "Info"
        Invoke-Compose @("build", "--parallel")
        Write-Log "Build complete" "OK"
    }

    'Pull' {
        Write-Log "Pulling latest images..." "Info"
        Invoke-Compose @("pull")
        Write-Log "Pull complete" "OK"
    }

    'Logs' {
        $args = @("logs")
        if ($Follow) { $args += "-f" }
        if ($Service) { $args += $Service }
        Invoke-Compose $args
    }

    'Status' {
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
        Write-Host "║                   AITHEROS DOCKER STATUS                         ║" -ForegroundColor Magenta
        Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
        Write-Host ""

        # Get container status
        $containers = docker ps -a --filter "name=aither" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        if ($containers) {
            Write-Host $containers
        } else {
            Write-Host "No AitherOS containers found." -ForegroundColor Yellow
        }
        Write-Host ""
    }

    'Exec' {
        if (-not $Service) {
            Write-Error "Service name required for Exec action. Use -Service parameter."
            exit 1
        }
        if (-not $Command) {
            # Default to interactive shell
            docker exec -it $Service /bin/bash
        } else {
            docker exec $Service $Command.Split(' ')
        }
    }

    'Clean' {
        Write-Log "Cleaning up AitherOS Docker resources..." "Warn"
        Invoke-Compose @("down", "-v", "--rmi", "local", "--remove-orphans")
        Write-Log "Cleanup complete" "OK"
    }
}
