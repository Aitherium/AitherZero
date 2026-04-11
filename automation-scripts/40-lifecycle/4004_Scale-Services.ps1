#Requires -Version 7.0
<#
.SYNOPSIS
    Scales AitherOS service replicas.

.DESCRIPTION
    Scales service replicas using Docker Compose scale command.
    Useful for scaling stateless services like workers.

.PARAMETER Service
    Service name to scale.

.PARAMETER Replicas
    Number of replicas. Default: 1

.EXAMPLE
    .\4004_Scale-Services.ps1 -Service parallel -Replicas 3

.NOTES
    Category: lifecycle
    Dependencies: Docker
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Service,
    
    [int]$Replicas = 1
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$dockerDir = Join-Path $workspaceRoot "docker"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Scaling AitherOS Service" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

Write-Host "Service:  $Service" -ForegroundColor Yellow
Write-Host "Replicas: $Replicas" -ForegroundColor Yellow
Write-Host ""

# Build compose command
$composeFile = Join-Path $dockerDir "docker-compose.yml"
$composeArgs = @(
    "compose"
    "-f", $composeFile
    "up"
    "-d"
    "--scale", "$Service=$Replicas"
    "--no-recreate"
    $Service
)

Write-Host "docker $($composeArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

Push-Location $dockerDir

try {
    & docker @composeArgs
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to scale service"
        exit 1
    }
} finally {
    Pop-Location
}

# Verify scaling
Write-Host ""
Write-Host "Verifying scale..." -ForegroundColor Gray

$containers = docker compose -f $composeFile ps --filter "name=$Service" --format json 2>$null | ConvertFrom-Json

Write-Host "  Running instances: $($containers.Count)" -ForegroundColor Green

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Service scaled to $Replicas replicas!" -ForegroundColor Green
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
