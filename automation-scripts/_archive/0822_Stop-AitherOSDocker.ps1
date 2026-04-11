<#
.SYNOPSIS
    Stop AitherOS Docker containers.

.DESCRIPTION
    Stops and optionally removes AitherOS containers started via docker-compose.

.PARAMETER Profile
    Docker compose profile to stop: core, all, etc.
    Default: all

.PARAMETER Remove
    Remove containers after stopping (down instead of stop).

.PARAMETER RemoveVolumes
    Also remove volumes (data will be lost!).

.PARAMETER ShowOutput
    Display docker compose output.

.EXAMPLE
    .\0822_Stop-AitherOSDocker.ps1
    # Stop all containers

.EXAMPLE
    .\0822_Stop-AitherOSDocker.ps1 -Remove -RemoveVolumes
    # Stop, remove containers and volumes (clean slate)
#>
[CmdletBinding()]
param(
    [ValidateSet("core", "intelligence", "perception", "memory", "training", "autonomic", "gateway", "gpu", "external", "agents", "all")]
    [string]$Profile = "all",
    
    [switch]$Remove,
    
    [switch]$RemoveVolumes,
    
    [switch]$ShowOutput
)

# Initialize script environment
$scriptPath = $PSScriptRoot
. (Join-Path $scriptPath "_init.ps1")

Write-AitherLog "Stopping AitherOS Docker containers..." -Level INFO -Source "DockerStop"

# Check for Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-AitherLog "Docker not found." -Level ERROR -Source "DockerStop"
    exit 1
}

# Find compose file
$composeFile = Join-Path $env:AITHERZERO_ROOT "docker-compose.aitheros.yml"
if (-not (Test-Path $composeFile)) {
    Write-AitherLog "docker-compose.aitheros.yml not found at: $composeFile" -Level ERROR -Source "DockerStop"
    exit 1
}

# Build command
$stopArgs = @("compose", "-f", $composeFile, "--profile", $Profile)

if ($Remove) {
    $stopArgs += "down"
    if ($RemoveVolumes) {
        $stopArgs += "-v"
        Write-AitherLog "WARNING: Removing volumes - data will be lost!" -Level WARN -Source "DockerStop"
    }
} else {
    $stopArgs += "stop"
}

Write-AitherLog "Docker command: docker $($stopArgs -join ' ')" -Level DEBUG -Source "DockerStop"
Write-AitherLog "Stopping profile: $Profile" -Level INFO -Source "DockerStop"

# Execute
try {
    if ($ShowOutput) {
        & docker @stopArgs
    } else {
        & docker @stopArgs 2>&1 | ForEach-Object { Write-Verbose $_ }
    }
    
    if ($LASTEXITCODE -ne 0) {
        throw "Docker compose stop failed with exit code $LASTEXITCODE"
    }
    
    Write-AitherLog "AitherOS containers stopped successfully" -Level SUCCESS -Source "DockerStop"
    
} catch {
    Write-AitherLog "Docker compose stop failed: $_" -Level ERROR -Source "DockerStop"
    exit 1
}

# Show remaining containers
$remaining = docker ps --filter "name=aither-" --format "{{.Names}}" 2>$null
if ($remaining) {
    Write-AitherLog "Remaining AitherOS containers:" -Level INFO -Source "DockerStop"
    $remaining | ForEach-Object { Write-Host "  - $_" }
} else {
    Write-AitherLog "All AitherOS containers stopped" -Level SUCCESS -Source "DockerStop"
}
