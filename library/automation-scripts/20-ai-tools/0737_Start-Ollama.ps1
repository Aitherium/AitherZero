<#
.SYNOPSIS
    Starts the Ollama service.

.DESCRIPTION
    Starts the Ollama service in the background.
    Checks if it's already running first.

.EXAMPLE
    ./0737_Start-Ollama.ps1
#>
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$ShowOutput,
    
    [Parameter()]
    [switch]$Detached
)

$ErrorActionPreference = "Stop"

# Check if already running
$conn = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue
if ($conn) {
    if ($ShowOutput) { Write-Host "Ollama is already running on port 11434 (PID: $($conn.OwningProcess))." -ForegroundColor Yellow }
    exit 0
}

if ($ShowOutput) { Write-Host "Starting Ollama..." }

if (Get-Command "ollama" -ErrorAction SilentlyContinue) {
    # Start as a background process
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    
    # Wait for it to come up
    $retries = 10
    while ($retries -gt 0) {
        Start-Sleep -Seconds 1
        $conn = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue
        if ($conn) {
            if ($ShowOutput) { Write-Host "Ollama started successfully on port 11434." -ForegroundColor Green }
            exit 0
        }
        $retries--
    }
    
    Write-Error "Timed out waiting for Ollama to start."
} else {
    Write-Error "Ollama executable not found in PATH. Please install Ollama first."
}
