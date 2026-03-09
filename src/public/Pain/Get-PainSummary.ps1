#Requires -Version 7.0

<#
.SYNOPSIS
    Gets a comprehensive summary of the pain system configuration.
.DESCRIPTION
    Shows pain system settings, active filters, pain point counts by
    category, and current pain status.
.PARAMETER PulseUrl
    URL of the AitherPulse server. Defaults to http://localhost:8081.
.PARAMETER ShowPainPoints
    Include list of all pain point IDs grouped by category.
.EXAMPLE
    Get-PainSummary
    
    Shows pain system overview.
.EXAMPLE
    Get-PainSummary -ShowPainPoints
    
    Shows overview with all pain points listed.
.NOTES
    Author: AitherZero
    Domain: Pain
#>

function Get-PainSummary {
[CmdletBinding()]
param(
    [Parameter()]
    [string]$PulseUrl = $env:AITHERPULSE_URL ?? 'http://localhost:8081',
    
    [Parameter()]
    [switch]$ShowPainPoints
)

$ErrorActionPreference = 'Stop'

try {
    $summary = Invoke-RestMethod -Uri "$PulseUrl/pain/summary" -Method Get -TimeoutSec 10
    $categories = Invoke-RestMethod -Uri "$PulseUrl/pain/categories" -Method Get -TimeoutSec 10
    
    Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Get-PainSummary'
    Write-AitherLog -Level Information -Message "                    PAIN SYSTEM SUMMARY                          " -Source 'Get-PainSummary'
    Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Get-PainSummary'
    
    # System Status
    Write-AitherLog -Level Information -Message "  System Status:" -Source 'Get-PainSummary'
    $enabledLevel = if ($summary.settings.enabled) { 'Information' } else { 'Warning' }
    Write-AitherLog -Level $enabledLevel -Message "    Enabled: $(if ($summary.settings.enabled) { 'Yes' } else { 'No' })" -Source 'Get-PainSummary'
    Write-AitherLog -Level Information -Message "    Config Path: $($summary.config_path)" -Source 'Get-PainSummary'
    
    # Pain Points Summary
    Write-AitherLog -Level Information -Message "  Pain Points Configuration:" -Source 'Get-PainSummary'
    Write-AitherLog -Level Information -Message "    Total Configured: $($summary.total_pain_points)" -Source 'Get-PainSummary'
    Write-AitherLog -Level Information -Message "    Default Weight: $($summary.settings.default_weight)" -Source 'Get-PainSummary'
    Write-AitherLog -Level Information -Message "    Default Cooldown: $($summary.settings.default_cooldown_seconds)s" -Source 'Get-PainSummary'
    
    # By Category
    Write-AitherLog -Level Information -Message "  Pain Points by Category:" -Source 'Get-PainSummary'
    $allCategories = @('resource', 'quality', 'cost', 'reliability', 'security', 'performance', 'loop', 'infrastructure', 'development', 'git')
    foreach ($cat in $allCategories) {
        $count = $summary.pain_points_by_category.$cat
        if ($null -eq $count) { $count = 0 }
        $excluded = $cat -in $categories.excluded_categories
        
        $catLevel = if ($excluded) { 'Warning' } elseif ($count -gt 0) { 'Information' } else { 'Information' }
        $status = if ($excluded) { " (excluded)" } else { "" }
        
        Write-AitherLog -Level $catLevel -Message "    $($cat): $count$status" -Source 'Get-PainSummary'
    }
    
    # Active Filters
    if ($categories.excluded_categories.Count -gt 0 -or $summary.filters.exclude_pain_points.Count -gt 0) {
        Write-AitherLog -Level Warning -Message "  Active Filters:" -Source 'Get-PainSummary'
        if ($categories.excluded_categories.Count -gt 0) {
            Write-AitherLog -Level Warning -Message "    Excluded Categories: $($categories.excluded_categories -join ', ')" -Source 'Get-PainSummary'
        }
        if ($summary.filters.exclude_pain_points.Count -gt 0) {
            Write-AitherLog -Level Warning -Message "    Excluded Pain Points: $($summary.filters.exclude_pain_points -join ', ')" -Source 'Get-PainSummary'
        }
        if ($summary.filters.min_severity -gt 0) {
            Write-AitherLog -Level Information -Message "    Min Severity: $($summary.filters.min_severity)" -Source 'Get-PainSummary'
        }
    }
    
    # Current Pain Status
    Write-AitherLog -Level Information -Message "  Current Pain Status:" -Source 'Get-PainSummary'
    $signalLevel = if ($summary.active_pain_signals -gt 5) { 'Error' } elseif ($summary.active_pain_signals -gt 0) { 'Warning' } else { 'Information' }
    Write-AitherLog -Level $signalLevel -Message "    Active Signals: $($summary.active_pain_signals)" -Source 'Get-PainSummary'
    
    $scoreLevel = if ($summary.total_pain_score -gt 5) { 'Error' } elseif ($summary.total_pain_score -gt 2) { 'Warning' } else { 'Information' }
    Write-AitherLog -Level $scoreLevel -Message "    Total Pain Score: $([math]::Round($summary.total_pain_score, 2))" -Source 'Get-PainSummary'
    
    if ($summary.active_pain_by_category.Count -gt 0) {
        Write-AitherLog -Level Information -Message "    Active by Category:" -Source 'Get-PainSummary'
        foreach ($cat in $summary.active_pain_by_category.PSObject.Properties) {
            Write-AitherLog -Level Warning -Message "      $($cat.Name): $($cat.Value)" -Source 'Get-PainSummary'
        }
    }
    
    # Show pain points if requested
    if ($ShowPainPoints) {
        Write-AitherLog -Level Information -Message "  All Pain Points:" -Source 'Get-PainSummary'
        $painPoints = Invoke-RestMethod -Uri "$PulseUrl/pain-points" -Method Get -TimeoutSec 10
        
        $grouped = $painPoints.pain_points | Group-Object -Property category
        foreach ($group in $grouped | Sort-Object Name) {
            Write-AitherLog -Level Information -Message "    [$($group.Name)]" -Source 'Get-PainSummary'
            foreach ($pp in $group.Group | Sort-Object id) {
                $status = if ($pp.enabled) { "✓" } else { "○" }
                $statusLevel = if ($pp.enabled) { 'Information' } else { 'Warning' }
                Write-AitherLog -Level $statusLevel -Message "      $status $($pp.id) (w:$($pp.weight))" -Source 'Get-PainSummary'
            }
        }
    }
    
    Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Get-PainSummary'
    
    return $summary
}
catch {
    if ($_.Exception.Message -like "*Unable to connect*") {
        Write-AitherLog -Level Warning -Message "AitherPulse is not running at $PulseUrl" -Source 'Get-PainSummary'
        Write-AitherLog -Level Information -Message "Start AitherPulse with: ./AitherZero/library/automation-scripts/0530_Start-AitherPulse.ps1" -Source 'Get-PainSummary'
    } else {
        throw $_
    }
}
}
