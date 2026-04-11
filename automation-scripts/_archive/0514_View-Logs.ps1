#Requires -Version 7.0
# Stage: Reporting
# Dependencies: AitherZero
# Description: View and manage AitherZero logs (Modernized wrapper for Get-AitherLog)

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [hashtable]$Configuration,

    [Parameter()]
    [ValidateSet('Dashboard', 'Latest', 'Errors', 'Transcript', 'Search', 'Status')]
    [string]$Mode = 'Dashboard',

    [Parameter()]
    [int]$Tail = 30,

    [Parameter()]
    [switch]$Follow,

    [Parameter()]
    [string]$SearchPattern,

    [Parameter()]
    [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
    [string]$Level
)

. "$PSScriptRoot/_init.ps1"
$ErrorActionPreference = 'Stop'

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0514_View-Logs'
    } else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting log viewer in mode: $Mode"

try {
    switch ($Mode) {
        'Dashboard' {
            Write-Host "`n📊 Log Dashboard" -ForegroundColor Cyan
            Write-Host "─────────────────────────────────────────────────" -ForegroundColor DarkGray
            
            # Get logs for today
            $logs = Get-AitherLog -Last 1000 -ErrorAction SilentlyContinue
            
            if (-not $logs) {
                Write-Host "No logs found for today." -ForegroundColor Yellow
            } else {
                $total = $logs.Count
                $errors = ($logs | Where-Object Level -eq 'Error').Count
                $warnings = ($logs | Where-Object Level -eq 'Warning').Count
                $info = ($logs | Where-Object Level -eq 'Information').Count
                
                Write-Host "`nStatistics (Last 1000 entries):" -ForegroundColor White
                Write-Host "  Total: $total" -ForegroundColor Gray
                Write-Host "  Errors: $errors" -ForegroundColor Red
                Write-Host "  Warnings: $warnings" -ForegroundColor Yellow
                Write-Host "  Info: $info" -ForegroundColor Cyan
                
                Write-Host "`nLatest 5 Entries:" -ForegroundColor White
                $logs | Select-Object -First 5 | Format-Table Timestamp, Level, Message -AutoSize
            }
        }

        'Latest' {
            Write-Host "`n📋 Showing Latest Log Entries..." -ForegroundColor Cyan
            $params = @{ Last = $Tail }
            if ($Level) { $params.Level = $Level }
            if ($Follow) { $params.Tail = $true; $params.Remove('Last') } # Switch to Tail mode
            
            Get-AitherLog @params | Format-Table Timestamp, Level, Message -AutoSize
        }

        'Errors' {
            Write-Host "`n❌ Showing Error Log Entries..." -ForegroundColor Red
            Get-AitherLog -Level Error,Critical -Last 100 | Format-Table Timestamp, Level, Source, Message -AutoSize
        }
        
        'Search' {
            if (-not $SearchPattern) {
                throw "SearchPattern is required for Search mode."
            }
            Write-Host "`n🔍 Searching for: '$SearchPattern'" -ForegroundColor Cyan
            Get-AitherLog -Message $SearchPattern -Last 100 | Format-Table Timestamp, Level, Message -AutoSize
        }

        'Status' {
            Get-AitherStatus
        }
    }
} catch {
    Write-ScriptLog "Error in log viewer: $_" -Level Error
    exit 1
}
