#Requires -Version 7.0

<#
.SYNOPSIS
    Gets configured pain points from AitherPulse.
.DESCRIPTION
    Retrieves all pain point configurations including their weights,
    thresholds, and enabled status. Can filter by category or specific ID.
.PARAMETER PulseUrl
    URL of the AitherPulse server. Defaults to http://localhost:8081.
.PARAMETER Id
    Get a specific pain point by ID.
.PARAMETER Category
    Filter pain points by category.
.PARAMETER EnabledOnly
    Only show enabled pain points.
.PARAMETER DisabledOnly
    Only show disabled pain points.
.EXAMPLE
    Get-PainPoints
    
    Lists all configured pain points.
.EXAMPLE
    Get-PainPoints -Category quality
    
    Lists only quality-related pain points.
.EXAMPLE
    Get-PainPoints -Id test_failure
    
    Gets detailed info about a specific pain point.
.NOTES
    Author: AitherZero
    Domain: Pain
#>

function Get-PainPoints {
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter()]
    [string]$PulseUrl = $env:AITHERPULSE_URL ?? 'http://localhost:8081',
    
    [Parameter(ParameterSetName = 'ById')]
    [string]$Id,
    
    [Parameter(ParameterSetName = 'List')]
    [ValidateSet('resource', 'quality', 'cost', 'reliability', 'security', 'performance', 'loop', 'infrastructure', 'development', 'git')]
    [string]$Category,
    
    [Parameter(ParameterSetName = 'List')]
    [switch]$EnabledOnly,
    
    [Parameter(ParameterSetName = 'List')]
    [switch]$DisabledOnly
)

$ErrorActionPreference = 'Stop'

try {
    if ($PSCmdlet.ParameterSetName -eq 'ById' -and $Id) {
        # Get specific pain point
        $response = Invoke-RestMethod -Uri "$PulseUrl/pain-points/$Id" -Method Get -TimeoutSec 10
        return $response
    }
    
    # Get all pain points
    $response = Invoke-RestMethod -Uri "$PulseUrl/pain-points" -Method Get -TimeoutSec 10
    $painPoints = $response.pain_points
    
    # Apply filters
    if ($Category) {
        $painPoints = $painPoints | Where-Object { $_.category -eq $Category }
    }
    
    if ($EnabledOnly) {
        $painPoints = $painPoints | Where-Object { $_.enabled -eq $true }
    }
    
    if ($DisabledOnly) {
        $painPoints = $painPoints | Where-Object { $_.enabled -eq $false }
    }
    
    # Format output
    $painPoints | ForEach-Object {
        [PSCustomObject]@{
            Id             = $_.id
            Name           = $_.name
            Category       = $_.category
            Weight         = $_.weight
            Threshold      = $_.threshold
            ThresholdType  = $_.threshold_type
            Enabled        = $_.enabled
            AutoInterrupt  = $_.auto_interrupt
            HaltOnCritical = $_.halt_on_critical
            CooldownSec    = $_.cooldown_seconds
            DecayRate      = $_.decay_rate
        }
    } | Format-Table -AutoSize
    
    Write-AitherLog -Level Information -Message "Total: $($painPoints.Count) pain points" -Source 'Get-PainPoints'
}
catch {
    if ($_.Exception.Message -like "*Unable to connect*") {
        Write-AitherLog -Level Warning -Message "AitherPulse is not running at $PulseUrl" -Source 'Get-PainPoints'
    } elseif ($_.Exception.Message -like "*404*") {
        Write-AitherLog -Level Warning -Message "Pain point '$Id' not found" -Source 'Get-PainPoints'
    } else {
        throw $_
    }
}
}
