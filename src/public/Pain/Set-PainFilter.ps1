#Requires -Version 7.0

<#
.SYNOPSIS
    Manages pain signal filters in AitherPulse.
.DESCRIPTION
    Add, remove, or view filters that control which pain signals are monitored.
    Filters can exclude entire categories or specific pain point IDs.
.PARAMETER PulseUrl
    URL of the AitherPulse server. Defaults to http://localhost:8081.
.PARAMETER Action
    The action to perform: List, ExcludeCategory, IncludeCategory, ExcludePainPoint, IncludePainPoint.
.PARAMETER Category
    Category to include/exclude.
.PARAMETER PainPointId
    Specific pain point ID to include/exclude.
.PARAMETER MinSeverity
    Minimum severity threshold (0.0 - 1.0) to trigger pain signals.
.EXAMPLE
    Set-PainFilter -Action List
    
    Shows current filter configuration.
.EXAMPLE
    Set-PainFilter -Action ExcludeCategory -Category resource
    
    Excludes all resource-related pain signals (CPU, memory, disk).
.EXAMPLE
    Set-PainFilter -Action ExcludePainPoint -PainPointId cpu_high
    
    Excludes a specific pain point.
.EXAMPLE
    Set-PainFilter -Action IncludeCategory -Category resource
    
    Re-includes a previously excluded category.
.NOTES
    Author: AitherZero
    Domain: Pain
#>

function Set-PainFilter {
[CmdletBinding()]
param(
    [Parameter()]
    [string]$PulseUrl = $env:AITHERPULSE_URL ?? 'http://localhost:8081',
    
    [Parameter(Mandatory)]
    [ValidateSet('List', 'ExcludeCategory', 'IncludeCategory', 'ExcludePainPoint', 'IncludePainPoint', 'SetMinSeverity')]
    [string]$Action,
    
    [Parameter()]
    [ValidateSet('resource', 'quality', 'cost', 'reliability', 'security', 'performance', 'loop', 'infrastructure', 'development', 'git')]
    [string]$Category,
    
    [Parameter()]
    [string]$PainPointId,
    
    [Parameter()]
    [ValidateRange(0.0, 1.0)]
    [float]$MinSeverity
)

$ErrorActionPreference = 'Stop'

try {
    switch ($Action) {
        'List' {
            $response = Invoke-RestMethod -Uri "$PulseUrl/pain/filters" -Method Get -TimeoutSec 10
            
            Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Set-PainFilter'
            Write-AitherLog -Level Information -Message "                    PAIN FILTER CONFIGURATION                    " -Source 'Set-PainFilter'
            Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Set-PainFilter'
            
            $includeMsg = if ($response.include_categories.Count -eq 0) { "(all)" } else { ($response.include_categories -join ', ') }
            $includeLevel = if ($response.include_categories.Count -eq 0) { 'Information' } else { 'Warning' }
            Write-AitherLog -Level $includeLevel -Message "  Include Categories: $includeMsg" -Source 'Set-PainFilter'
            
            $excludeMsg = if ($response.exclude_categories.Count -eq 0) { "(none)" } else { ($response.exclude_categories -join ', ') }
            $excludeLevel = if ($response.exclude_categories.Count -eq 0) { 'Information' } else { 'Warning' }
            Write-AitherLog -Level $excludeLevel -Message "  Exclude Categories: $excludeMsg" -Source 'Set-PainFilter'
            
            $excludePointsMsg = if ($response.exclude_pain_points.Count -eq 0) { "(none)" } else { ($response.exclude_pain_points -join ', ') }
            $excludePointsLevel = if ($response.exclude_pain_points.Count -eq 0) { 'Information' } else { 'Warning' }
            Write-AitherLog -Level $excludePointsLevel -Message "  Exclude Pain Points: $excludePointsMsg" -Source 'Set-PainFilter'
            
            Write-AitherLog -Level Information -Message "  Min Severity: $($response.min_severity)" -Source 'Set-PainFilter'
            Write-AitherLog -Level Information -Message "  Max Active Pain: $($response.max_active_pain)" -Source 'Set-PainFilter'
            
            return $response
        }
        
        'ExcludeCategory' {
            if (-not $Category) {
                throw "Category parameter required for ExcludeCategory action"
            }
            $response = Invoke-RestMethod -Uri "$PulseUrl/pain/filters/exclude-category?category=$Category" -Method Post -TimeoutSec 10
            Write-AitherLog -Level Warning -Message "✓ Excluded category '$Category'" -Source 'Set-PainFilter'
            Write-AitherLog -Level Information -Message "  Active pain points: $($response.active_pain_points)" -Source 'Set-PainFilter'
            return $response
        }
        
        'IncludeCategory' {
            if (-not $Category) {
                throw "Category parameter required for IncludeCategory action"
            }
            $response = Invoke-RestMethod -Uri "$PulseUrl/pain/filters/exclude-category?category=$Category" -Method Delete -TimeoutSec 10
            Write-AitherLog -Level Information -Message "✓ Re-included category '$Category'" -Source 'Set-PainFilter'
            Write-AitherLog -Level Information -Message "  Active pain points: $($response.active_pain_points)" -Source 'Set-PainFilter'
            return $response
        }
        
        'ExcludePainPoint' {
            if (-not $PainPointId) {
                throw "PainPointId parameter required for ExcludePainPoint action"
            }
            $response = Invoke-RestMethod -Uri "$PulseUrl/pain/filters/exclude-pain-point?pain_point_id=$PainPointId" -Method Post -TimeoutSec 10
            Write-AitherLog -Level Warning -Message "✓ Excluded pain point '$PainPointId'" -Source 'Set-PainFilter'
            Write-AitherLog -Level Information -Message "  Active pain points: $($response.active_pain_points)" -Source 'Set-PainFilter'
            return $response
        }
        
        'IncludePainPoint' {
            if (-not $PainPointId) {
                throw "PainPointId parameter required for IncludePainPoint action"
            }
            $response = Invoke-RestMethod -Uri "$PulseUrl/pain/filters/exclude-pain-point?pain_point_id=$PainPointId" -Method Delete -TimeoutSec 10
            Write-AitherLog -Level Information -Message "✓ Re-included pain point '$PainPointId'" -Source 'Set-PainFilter'
            Write-AitherLog -Level Information -Message "  Active pain points: $($response.active_pain_points)" -Source 'Set-PainFilter'
            return $response
        }
        
        'SetMinSeverity' {
            if ($null -eq $MinSeverity) {
                throw "MinSeverity parameter required for SetMinSeverity action"
            }
            # Get current filters, update min_severity, and save
            $current = Invoke-RestMethod -Uri "$PulseUrl/pain/filters" -Method Get -TimeoutSec 10
            $current.min_severity = $MinSeverity
            $response = Invoke-RestMethod -Uri "$PulseUrl/pain/filters" -Method Put -Body ($current | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 10
            Write-AitherLog -Level Information -Message "✓ Set minimum severity to $MinSeverity" -Source 'Set-PainFilter'
            return $response
        }
    }
}
catch {
    if ($_.Exception.Message -like "*Unable to connect*") {
        Write-AitherLog -Level Warning -Message "AitherPulse is not running at $PulseUrl" -Source 'Set-PainFilter'
    } else {
        throw $_
    }
}
}
