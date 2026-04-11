#Requires -Version 7.0

<#
.SYNOPSIS
    Adds or updates a pain point configuration in AitherPulse.
.DESCRIPTION
    Creates a new pain point or updates an existing one with specified
    properties. This allows defining custom pain signals for specific
    monitoring needs.
.PARAMETER PulseUrl
    URL of the AitherPulse server. Defaults to http://localhost:8081.
.PARAMETER Id
    Unique identifier for the pain point.
.PARAMETER Name
    Display name for the pain point.
.PARAMETER Description
    Description of what this pain point detects.
.PARAMETER Category
    Category for grouping (resource, quality, cost, etc.).
.PARAMETER Weight
    Weight multiplier for severity (0.0 - 10.0).
.PARAMETER Threshold
    Threshold value that triggers the pain.
.PARAMETER ThresholdType
    Comparison type: gt, gte, lt, lte, eq, neq.
.PARAMETER AutoInterrupt
    Whether to interrupt agents when triggered.
.PARAMETER HaltOnCritical
    Whether to halt all operations when severity > 0.9.
.PARAMETER InterruptMessage
    Message to display when interrupting.
.PARAMETER CooldownSeconds
    Minimum seconds between triggers.
.PARAMETER DecayRate
    How fast pain decays per minute.
.PARAMETER Enabled
    Whether the pain point is enabled.
.EXAMPLE
    Add-PainPoint -Id "custom_build_slow" -Name "Slow Build" -Description "Build taking too long" `
        -Category performance -Weight 2.0 -Threshold 300 -ThresholdType gt `
        -InterruptMessage "Build is taking over 5 minutes!"
    
    Adds a custom pain point for slow builds.
.EXAMPLE
    Add-PainPoint -Id "test_failure" -Weight 5.0
    
    Updates the weight of an existing pain point.
.NOTES
    Author: AitherZero
    Domain: Pain
#>

function Add-PainPoint {
[CmdletBinding()]
param(
    [Parameter()]
    [string]$PulseUrl = $env:AITHERPULSE_URL ?? 'http://localhost:8081',
    
    [Parameter(Mandatory)]
    [string]$Id,
    
    [Parameter()]
    [string]$Name,
    
    [Parameter()]
    [string]$Description,
    
    [Parameter()]
    [ValidateSet('resource', 'quality', 'cost', 'reliability', 'security', 'performance', 'loop', 'infrastructure', 'development', 'git')]
    [string]$Category,
    
    [Parameter()]
    [ValidateRange(0.0, 10.0)]
    [float]$Weight,
    
    [Parameter()]
    [float]$Threshold,
    
    [Parameter()]
    [ValidateSet('gt', 'gte', 'lt', 'lte', 'eq', 'neq')]
    [string]$ThresholdType = 'gt',
    
    [Parameter()]
    [switch]$AutoInterrupt,
    
    [Parameter()]
    [switch]$HaltOnCritical,
    
    [Parameter()]
    [string]$InterruptMessage,
    
    [Parameter()]
    [int]$CooldownSeconds = 60,
    
    [Parameter()]
    [ValidateRange(0.0, 1.0)]
    [float]$DecayRate = 0.1,
    
    [Parameter()]
    [bool]$Enabled = $true
)

$ErrorActionPreference = 'Stop'

try {
    # Try to get existing pain point
    $existing = $null
    try {
        $existing = Invoke-RestMethod -Uri "$PulseUrl/pain-points/$Id" -Method Get -TimeoutSec 10 -ErrorAction SilentlyContinue
    } catch {
        # Pain point doesn't exist, we'll create new
    }
    
    # Build pain point config
    if ($existing) {
        # Update existing - only override provided parameters
        $painPoint = $existing
        
        if ($PSBoundParameters.ContainsKey('Name')) { $painPoint.name = $Name }
        if ($PSBoundParameters.ContainsKey('Description')) { $painPoint.description = $Description }
        if ($PSBoundParameters.ContainsKey('Category')) { $painPoint.category = $Category }
        if ($PSBoundParameters.ContainsKey('Weight')) { $painPoint.weight = $Weight }
        if ($PSBoundParameters.ContainsKey('Threshold')) { $painPoint.threshold = $Threshold }
        if ($PSBoundParameters.ContainsKey('ThresholdType')) { $painPoint.threshold_type = $ThresholdType }
        if ($PSBoundParameters.ContainsKey('AutoInterrupt')) { $painPoint.auto_interrupt = $AutoInterrupt.IsPresent }
        if ($PSBoundParameters.ContainsKey('HaltOnCritical')) { $painPoint.halt_on_critical = $HaltOnCritical.IsPresent }
        if ($PSBoundParameters.ContainsKey('InterruptMessage')) { $painPoint.interrupt_message = $InterruptMessage }
        if ($PSBoundParameters.ContainsKey('CooldownSeconds')) { $painPoint.cooldown_seconds = $CooldownSeconds }
        if ($PSBoundParameters.ContainsKey('DecayRate')) { $painPoint.decay_rate = $DecayRate }
        if ($PSBoundParameters.ContainsKey('Enabled')) { $painPoint.enabled = $Enabled }
        
        Write-AitherLog -Level Information -Message "Updating existing pain point '$Id'..." -Source 'Add-PainPoint'
    } else {
        # Create new - validate required parameters
        if (-not $Name) { throw "Name is required for new pain points" }
        if (-not $Description) { throw "Description is required for new pain points" }
        if (-not $Category) { throw "Category is required for new pain points" }
        if ($null -eq $Threshold) { throw "Threshold is required for new pain points" }
        
        $painPoint = @{
            id               = $Id
            name             = $Name
            description      = $Description
            category         = $Category
            weight           = if ($PSBoundParameters.ContainsKey('Weight')) { $Weight } else { 1.0 }
            threshold        = $Threshold
            threshold_type   = $ThresholdType
            auto_interrupt   = $AutoInterrupt.IsPresent
            halt_on_critical = $HaltOnCritical.IsPresent
            interrupt_message = if ($InterruptMessage) { $InterruptMessage } else { "" }
            cooldown_seconds = $CooldownSeconds
            decay_rate       = $DecayRate
            enabled          = $Enabled
        }
        
        Write-AitherLog -Level Information -Message "Creating new pain point '$Id'..." -Source 'Add-PainPoint'
    }
    
    # Send to API
    $response = Invoke-RestMethod -Uri "$PulseUrl/pain-points" -Method Post `
        -Body ($painPoint | ConvertTo-Json -Depth 10) `
        -ContentType "application/json" -TimeoutSec 10
    
    if ($response.created) {
        Write-AitherLog -Level Information -Message "✓ Pain point '$Id' saved successfully" -Source 'Add-PainPoint'
        
        # Show the saved config
        $saved = Invoke-RestMethod -Uri "$PulseUrl/pain-points/$Id" -Method Get -TimeoutSec 10
        Write-AitherLog -Level Information -Message "  Name: $($saved.name)" -Source 'Add-PainPoint'
        Write-AitherLog -Level Information -Message "  Category: $($saved.category)" -Source 'Add-PainPoint'
        Write-AitherLog -Level Information -Message "  Weight: $($saved.weight)" -Source 'Add-PainPoint'
        Write-AitherLog -Level Information -Message "  Threshold: $($saved.threshold) ($($saved.threshold_type))" -Source 'Add-PainPoint'
        Write-AitherLog -Level Information -Message "  Auto-Interrupt: $($saved.auto_interrupt)" -Source 'Add-PainPoint'
        Write-AitherLog -Level Information -Message "  Enabled: $($saved.enabled)" -Source 'Add-PainPoint'
    }
    
    return $response
}
catch {
    if ($_.Exception.Message -like "*Unable to connect*") {
        Write-AitherLog -Level Warning -Message "AitherPulse is not running at $PulseUrl" -Source 'Add-PainPoint'
    } else {
        throw $_
    }
}
}
