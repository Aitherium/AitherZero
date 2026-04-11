#Requires -Version 7.0
<#
.SYNOPSIS
    Restarts AitherOS services.

.DESCRIPTION
    Restarts specific services or all services. Supports both
    Docker Compose restart and Genesis API restart.

.PARAMETER Services
    Specific services to restart. If not specified, restarts all.

.PARAMETER Method
    Restart method: "compose" or "genesis". Default: "genesis"

.PARAMETER Timeout
    Timeout in seconds. Default: 30

.EXAMPLE
    .\4003_Restart-Services.ps1 -Services llm,mind -Verbose

.NOTES
    Category: lifecycle
    Dependencies: Docker
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [string[]]$Services,
    
    [ValidateSet("compose", "genesis")]
    [string]$Method = "genesis",
    
    [int]$Timeout = 30
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$dockerDir = Join-Path $workspaceRoot "docker"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Restarting AitherOS Services" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

$targetServices = if ($Services) { $Services -join ", " } else { "all services" }
Write-Host "Target: $targetServices" -ForegroundColor Yellow
Write-Host "Method: $Method" -ForegroundColor Gray
Write-Host ""

if ($Method -eq "genesis") {
    # Use Genesis API for restart
    $genesisUrl = "http://localhost:8001"
    
    if ($Services) {
        foreach ($service in $Services) {
            Write-Host "Restarting: $service" -ForegroundColor Yellow
            try {
                $response = Invoke-RestMethod -Uri "$genesisUrl/api/services/$service/restart" -Method Post -TimeoutSec $Timeout
                Write-Host "  Status: $($response.status)" -ForegroundColor Green
            } catch {
                Write-Host "  Failed: $_" -ForegroundColor Red
            }
        }
    } else {
        # Restart all via shutdown + boot
        Write-Host "Performing full restart via Genesis..." -ForegroundColor Yellow
        
        try {
            # Shutdown
            Invoke-RestMethod -Uri "$genesisUrl/api/shutdown" -Method Post -TimeoutSec 10 | Out-Null
            Write-Host "  Shutdown initiated" -ForegroundColor Gray
            Start-Sleep -Seconds 10
            
            # Boot
            Invoke-RestMethod -Uri "$genesisUrl/api/boot" -Method Post -TimeoutSec 10 | Out-Null
            Write-Host "  Boot initiated" -ForegroundColor Gray
            
            Write-Host "  Restart complete!" -ForegroundColor Green
        } catch {
            Write-Warning "Genesis API not available, falling back to Docker Compose"
            $Method = "compose"
        }
    }
}

if ($Method -eq "compose") {
    # Use Docker Compose for restart
    $composeFile = Join-Path $dockerDir "docker-compose.yml"
    $composeArgs = @(
        "compose"
        "-f", $composeFile
        "restart"
        "--timeout", $Timeout.ToString()
    )
    
    if ($Services) {
        $composeArgs += $Services
    }
    
    Write-Host "docker $($composeArgs -join ' ')" -ForegroundColor DarkGray
    
    Push-Location $dockerDir
    try {
        & docker @composeArgs
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Services restarted!" -ForegroundColor Green
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
