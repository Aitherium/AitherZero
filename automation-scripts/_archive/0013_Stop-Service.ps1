<#
.SYNOPSIS
    Stops a specific AitherZero service or process.

.DESCRIPTION
    Stops a service by name (ComfyUI, Ollama, AitherNode, Cloudflared) or by Process ID (PID).
    Uses the same detection logic as Get-ServiceStatus to identify services by port or process name.

.PARAMETER Name
    The name of the service to stop (ComfyUI, Ollama, AitherNode, Cloudflared).

.PARAMETER Id
    The Process ID (PID) to stop.

.PARAMETER Force
    Forces the process to stop.

.EXAMPLE
    ./0013_Stop-Service.ps1 -Name ComfyUI
    Stops the ComfyUI service.

.EXAMPLE
    ./0013_Stop-Service.ps1 -Id 1234 -Force
    Forcefully stops process with PID 1234.
#>

param(
    [Parameter(Mandatory=$true, ParameterSetName="ByName")]
    [ValidateSet("ComfyUI", "Ollama", "AitherNode", "Cloudflared")]
    [string]$Name,

    [Parameter(Mandatory=$true, ParameterSetName="ById")]
    [int]$Id,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Get-ServicePid {
    param([string]$ServiceName)
    
    $Pid = $null
    
    switch ($ServiceName) {
        "ComfyUI" {
            # Check Port 8188
            $conn = Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction SilentlyContinue
            if ($conn) { $Pid = $conn.OwningProcess }
        }
        "Ollama" {
            # Check Port 11434
            $conn = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue
            if ($conn) { $Pid = $conn.OwningProcess }
        }
        "AitherNode" {
            # Check Port 8080
            $conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
            if ($conn) { $Pid = $conn.OwningProcess }
        }
        "Cloudflared" {
            # Check Process Name
            $proc = Get-CimInstance Win32_Process -Filter "Name like 'cloudflared%'" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) { $Pid = $proc.ProcessId }
        }
    }
    
    return $Pid
}

try {
    $TargetPid = $null

    if ($PSCmdlet.ParameterSetName -eq "ByName") {
        Write-Host "Looking for service: $Name..."
        $TargetPid = Get-ServicePid -ServiceName $Name
        
        if (-not $TargetPid) {
            Write-Warning "Service '$Name' not found or not running."
            return
        }
    } else {
        $TargetPid = $Id
    }

    $Process = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    
    if ($Process) {
        Write-Host "Stopping process '$($Process.ProcessName)' (PID: $TargetPid)..."
        Stop-Process -Id $TargetPid -Force:$Force -ErrorAction Stop
        Write-Host "Successfully stopped process (PID: $TargetPid)." -ForegroundColor Green
    } else {
        Write-Warning "Process with PID $TargetPid not found."
    }

} catch {
    Write-Error "Failed to stop service: $_"
    exit 1
}
