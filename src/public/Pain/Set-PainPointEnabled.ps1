#Requires -Version 7.0

<#
.SYNOPSIS
    Enables or disables a pain point.
.DESCRIPTION
    Toggles the enabled status of a specific pain point without
    removing it from the configuration.
.PARAMETER PulseUrl
    URL of the AitherPulse server. Defaults to http://localhost:8081.
.PARAMETER Id
    The ID of the pain point to toggle.
.PARAMETER Enable
    Enable the pain point.
.PARAMETER Disable
    Disable the pain point.
.EXAMPLE
    Set-PainPointEnabled -Id cpu_high -Disable
    
    Disables the high CPU pain signal.
.EXAMPLE
    Set-PainPointEnabled -Id test_failure -Enable
    
    Enables the test failure pain signal.
.NOTES
    Author: AitherZero
    Domain: Pain
#>

function Set-PainPointEnabled {
[CmdletBinding()]
param(
    [Parameter()]
    [string]$PulseUrl = $env:AITHERPULSE_URL ?? 'http://localhost:8081',
    
    [Parameter(Mandatory)]
    [string]$Id,
    
    [Parameter(ParameterSetName = 'Enable')]
    [switch]$Enable,
    
    [Parameter(ParameterSetName = 'Disable')]
    [switch]$Disable
)

$ErrorActionPreference = 'Stop'

try {
    $enabled = if ($Enable) { "true" } else { "false" }
    
    $response = Invoke-RestMethod -Uri "$PulseUrl/pain-points/$Id/toggle?enabled=$enabled" -Method Put -TimeoutSec 10
    
    if ($Enable) {
        Write-AitherLog -Level Information -Message "✓ Enabled pain point '$Id'" -Source 'Set-PainPointEnabled'
    } else {
        Write-AitherLog -Level Information -Message "✓ Disabled pain point '$Id'" -Source 'Set-PainPointEnabled'
    }
    
    return $response
}
catch {
    if ($_.Exception.Message -like "*Unable to connect*") {
        Write-AitherLog -Level Warning -Message "AitherPulse is not running at $PulseUrl" -Source 'Set-PainPointEnabled'
    } elseif ($_.Exception.Message -like "*404*") {
        Write-AitherLog -Level Warning -Message "Pain point '$Id' not found" -Source 'Set-PainPointEnabled'
    } else {
        throw $_
    }
}
}
