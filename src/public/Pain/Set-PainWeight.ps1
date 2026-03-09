#Requires -Version 7.0

<#
.SYNOPSIS
    Updates the weight of a pain point.
.DESCRIPTION
    Quickly adjusts the weight multiplier for a specific pain point.
    Higher weights make the pain signal more severe.
.PARAMETER PulseUrl
    URL of the AitherPulse server. Defaults to http://localhost:8081.
.PARAMETER Id
    The ID of the pain point to update.
.PARAMETER Weight
    New weight value (0.0 - 10.0).
.EXAMPLE
    Set-PainWeight -Id test_failure -Weight 5.0
    
    Sets test failure pain to maximum severity weight.
.EXAMPLE
    Set-PainWeight -Id cpu_high -Weight 0.5
    
    Reduces the impact of high CPU pain.
.NOTES
    Author: AitherZero
    Domain: Pain
#>

function Set-PainWeight {
[CmdletBinding()]
param(
    [Parameter()]
    [string]$PulseUrl = $env:AITHERPULSE_URL ?? 'http://localhost:8081',
    
    [Parameter(Mandatory)]
    [string]$Id,
    
    [Parameter(Mandatory)]
    [ValidateRange(0.0, 10.0)]
    [float]$Weight
)

$ErrorActionPreference = 'Stop'

try {
    $response = Invoke-RestMethod -Uri "$PulseUrl/pain-points/$Id/weight?weight=$Weight" -Method Put -TimeoutSec 10
    
    Write-AitherLog -Level Information -Message "✓ Updated '$Id' weight to $Weight" -Source 'Set-PainWeight'
    
    # Show impact preview
    $severityMultiplier = switch ($Weight) {
        { $_ -ge 5 } { "Critical impact (5x+ severity)" }
        { $_ -ge 3 } { "High impact (3x+ severity)" }
        { $_ -ge 1.5 } { "Moderate impact (1.5x+ severity)" }
        { $_ -ge 1 } { "Normal impact (1x severity)" }
        { $_ -lt 1 } { "Reduced impact (<1x severity)" }
        default { "Unknown" }
    }
    Write-AitherLog -Level Information -Message "  Effect: $severityMultiplier" -Source 'Set-PainWeight'
    
    return $response
}
catch {
    if ($_.Exception.Message -like "*Unable to connect*") {
        Write-AitherLog -Level Warning -Message "AitherPulse is not running at $PulseUrl" -Source 'Set-PainWeight'
    } elseif ($_.Exception.Message -like "*404*") {
        Write-AitherLog -Level Warning -Message "Pain point '$Id' not found" -Source 'Set-PainWeight'
    } else {
        throw $_
    }
}
}
