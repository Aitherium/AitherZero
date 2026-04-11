#Requires -Version 7.0
<#
.SYNOPSIS
    Stops the AitherOS Genesis bootloader and all services.

.DESCRIPTION
    Gracefully stops all AitherOS services using Docker Compose.

.PARAMETER Timeout
    Timeout in seconds for graceful shutdown. Default: 30

.PARAMETER RemoveVolumes
    Remove volumes when stopping. Default: $false

.PARAMETER RemoveOrphans
    Remove orphan containers. Default: $true

.EXAMPLE
    .\4002_Stop-Genesis.ps1 -Verbose

.NOTES
    Category: lifecycle
    Dependencies: Docker
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [int]$Timeout = 30,
    [switch]$RemoveVolumes,
    [switch]$RemoveOrphans = $true
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$dockerDir = Join-Path $workspaceRoot "docker"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Stopping AitherOS Genesis" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Validate Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed."
    exit 1
}

# Signal graceful shutdown to Genesis first
Write-Host "Signaling graceful shutdown to Genesis..." -ForegroundColor Yellow

try {
    $shutdownResponse = Invoke-RestMethod -Uri "http://localhost:8001/api/shutdown" -Method Post -TimeoutSec 5 -ErrorAction SilentlyContinue
    Write-Host "  Genesis acknowledged shutdown" -ForegroundColor Gray
    Start-Sleep -Seconds 5  # Give Genesis time to start shutdown
} catch {
    Write-Host "  Genesis not responding, proceeding with Docker stop" -ForegroundColor Gray
}

# Build compose command
$composeFile = Join-Path $dockerDir "docker-compose.yml"
$composeArgs = @(
    "compose"
    "-f", $composeFile
    "down"
    "--timeout", $Timeout.ToString()
)

if ($RemoveVolumes) {
    $composeArgs += "--volumes"
    Write-Warning "Volumes will be removed!"
}

if ($RemoveOrphans) {
    $composeArgs += "--remove-orphans"
}

Write-Host ""
Write-Host "Stopping containers..." -ForegroundColor Yellow
Write-Host "docker $($composeArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

Push-Location $dockerDir

try {
    & docker @composeArgs
    
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Some containers may not have stopped cleanly"
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  AitherOS Genesis stopped!" -ForegroundColor Green
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
