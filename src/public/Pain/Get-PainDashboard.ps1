#Requires -Version 7.0

<#
.SYNOPSIS
    Gets the current pain dashboard from AitherPulse.
.DESCRIPTION
    Retrieves comprehensive pain status including active pain signals,
    category scores, recommendations, and token usage metrics.
.PARAMETER PulseUrl
    URL of the AitherPulse server. Defaults to http://localhost:8081.
.PARAMETER AsObject
    Return as PSCustomObject instead of formatted display.
.EXAMPLE
    Get-PainDashboard
    
    Shows current pain status with formatted display.
.EXAMPLE
    Get-PainDashboard -AsObject | Select-Object total_pain_score, pain_level
    
    Get specific properties from the pain dashboard.
.NOTES
    Author: AitherZero
    Domain: Pain
#>

function Get-PainDashboard {
[CmdletBinding()]
param(
    [Parameter()]
    [string]$PulseUrl = $env:AITHERPULSE_URL ?? 'http://localhost:8081',
    
    [Parameter()]
    [switch]$AsObject
)

$ErrorActionPreference = 'Stop'

try {
    $response = Invoke-RestMethod -Uri "$PulseUrl/pain/dashboard" -Method Get -TimeoutSec 10
    
    if ($AsObject) {
        return $response
    }
    
    # Format output
    $painLevel = $response.pain_level
    $color = switch ($painLevel) {
        'none' { 'Green' }
        'low' { 'Cyan' }
        'medium' { 'Yellow' }
        'high' { 'Red' }
        'critical' { 'Magenta' }
        default { 'White' }
    }
    
    Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Get-PainDashboard'
    Write-AitherLog -Level Information -Message "                    AITHERPULSE PAIN DASHBOARD                   " -Source 'Get-PainDashboard'
    Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Get-PainDashboard'
    
    # Pain Level
    $painLevelMsg = "  Pain Level: $($painLevel.ToUpper()) (Score: $([math]::Round($response.total_pain_score, 2)))"
    $painLevelLevel = switch ($painLevel) {
        'none' { 'Information' }
        'low' { 'Information' }
        'medium' { 'Warning' }
        'high' { 'Error' }
        'critical' { 'Error' }
        default { 'Information' }
    }
    Write-AitherLog -Level $painLevelLevel -Message $painLevelMsg -Source 'Get-PainDashboard'
    
    $signalLevel = if ($response.active_pain_signals -gt 0) { 'Warning' } else { 'Information' }
    Write-AitherLog -Level $signalLevel -Message "  Active Signals: $($response.active_pain_signals)" -Source 'Get-PainDashboard'
    
    # Recommendations
    if ($response.should_halt) {
        Write-AitherLog -Level Error -Message "  ⛔ HALT RECOMMENDED: $($response.interrupt_message)" -Source 'Get-PainDashboard'
    } elseif ($response.should_interrupt) {
        Write-AitherLog -Level Warning -Message "  ⚠️ ATTENTION: $($response.interrupt_message)" -Source 'Get-PainDashboard'
    }
    
    # Token Stats
    if ($response.session_tokens_used -gt 0) {
        Write-AitherLog -Level Information -Message "  Token Usage:" -Source 'Get-PainDashboard'
        Write-AitherLog -Level Information -Message "    Session Tokens: $($response.session_tokens_used)" -Source 'Get-PainDashboard'
        Write-AitherLog -Level Information -Message "    Session Cost: `$$([math]::Round($response.session_cost_usd, 4))" -Source 'Get-PainDashboard'
        Write-AitherLog -Level Information -Message "    Burn Rate: $([math]::Round($response.token_burn_rate, 0))/min" -Source 'Get-PainDashboard'
    }
    
    # Category Scores
    if ($response.category_scores -and $response.category_scores.Count -gt 0) {
        Write-AitherLog -Level Information -Message "  Pain by Category:" -Source 'Get-PainDashboard'
        foreach ($cat in $response.category_scores.PSObject.Properties) {
            $score = [math]::Round($cat.Value, 2)
            $catLevel = if ($score -gt 0.7) { 'Error' } elseif ($score -gt 0.4) { 'Warning' } else { 'Information' }
            Write-AitherLog -Level $catLevel -Message "    $($cat.Name): $score" -Source 'Get-PainDashboard'
        }
    }
    
    # Top Pain Points
    if ($response.top_pain_points -and $response.top_pain_points.Count -gt 0) {
        Write-AitherLog -Level Information -Message "  Top Pain Points:" -Source 'Get-PainDashboard'
        foreach ($pain in $response.top_pain_points) {
            $severity = [math]::Round($pain.severity, 2)
            $painLevel = if ($severity -gt 0.7) { 'Error' } elseif ($severity -gt 0.4) { 'Warning' } else { 'Information' }
            Write-AitherLog -Level $painLevel -Message "    [$($pain.category)] $($pain.id): $($pain.message)" -Source 'Get-PainDashboard'
        }
    }
    
    Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Get-PainDashboard'
    
    return $response
}
catch {
    if ($_.Exception.Message -like "*Unable to connect*") {
        Write-AitherLog -Level Warning -Message "AitherPulse is not running at $PulseUrl" -Source 'Get-PainDashboard'
        Write-AitherLog -Level Information -Message "Start AitherPulse with: ./AitherZero/library/automation-scripts/0530_Start-AitherPulse.ps1" -Source 'Get-PainDashboard'
    } else {
        throw $_
    }
}
}
