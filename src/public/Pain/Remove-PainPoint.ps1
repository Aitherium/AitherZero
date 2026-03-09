#Requires -Version 7.0

<#
.SYNOPSIS
    Removes a pain point from AitherPulse configuration.
.DESCRIPTION
    Deletes a pain point configuration from the system.
    Use with caution as this permanently removes the pain signal.
.PARAMETER PulseUrl
    URL of the AitherPulse server. Defaults to http://localhost:8081.
.PARAMETER Id
    The ID of the pain point to remove.
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    Remove-PainPoint -Id custom_build_slow
    
    Removes a custom pain point after confirmation.
.EXAMPLE
    Remove-PainPoint -Id custom_build_slow -Force
    
    Removes without confirmation.
.NOTES
    Author: AitherZero
    Domain: Pain
#>

function Remove-PainPoint {
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$PulseUrl = $env:AITHERPULSE_URL ?? 'http://localhost:8081',
    
    [Parameter(Mandatory)]
    [string]$Id,
    
    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

try {
    # Check if pain point exists
    try {
        $existing = Invoke-RestMethod -Uri "$PulseUrl/pain-points/$Id" -Method Get -TimeoutSec 10
    } catch {
        Write-Warning "Pain point '$Id' not found"
        return
    }
    
    # Confirm deletion
    if (-not $Force) {
        Write-Host ""
        Write-Host "About to delete pain point:" -ForegroundColor Yellow
        Write-Host "  ID: $($existing.id)"
        Write-Host "  Name: $($existing.name)"
        Write-Host "  Category: $($existing.category)"
        Write-Host ""
        
        $confirm = Read-Host "Are you sure? (y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Cancelled" -ForegroundColor Gray
            return
        }
    }
    
    if ($PSCmdlet.ShouldProcess($Id, "Remove pain point")) {
        $response = Invoke-RestMethod -Uri "$PulseUrl/pain-points/$Id" -Method Delete -TimeoutSec 10
        
        if ($response.deleted) {
            Write-Host "✓ Pain point '$Id' deleted" -ForegroundColor Red
        }
        
        return $response
    }
}
catch {
    if ($_.Exception.Message -like "*Unable to connect*") {
        Write-Warning "AitherPulse is not running at $PulseUrl"
    } else {
        throw $_
    }
}
}
