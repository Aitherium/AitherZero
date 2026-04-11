#Requires -Version 7.0

<#
.SYNOPSIS
    Format a TimeSpan into a human-readable string

.DESCRIPTION
    Converts a TimeSpan object to a friendly string like "2h 30m 15s" or "45s".

.PARAMETER TimeSpan
    The TimeSpan to format

.EXAMPLE
    $duration = Measure-Command { Start-Sleep -Seconds 5 }
    Format-AitherDuration $duration
    
    Format a measured duration

.EXAMPLE
    Format-AitherDuration (New-TimeSpan -Hours 2 -Minutes 30)
    
    Format a TimeSpan: "2h 30m 0s"

.OUTPUTS
    System.String - Formatted duration string

.NOTES
    Formats durations as hours/minutes/seconds or minutes/seconds or seconds/milliseconds
    depending on the duration length.

.LINK
    Get-AitherExecutionHistory
#>
function Format-AitherDuration {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [TimeSpan]$TimeSpan
)

process { try {
        if ($TimeSpan.TotalHours -ge 1) {
            return "{0:0}h {1:0}m {2:0}s" -f $TimeSpan.Hours, $TimeSpan.Minutes, $TimeSpan.Seconds
        }
    elseif ($TimeSpan.TotalMinutes -ge 1) {
            return "{0:0}m {1:0}s" -f $TimeSpan.Minutes, $TimeSpan.Seconds
        }
    elseif ($TimeSpan.TotalSeconds -ge 1) {
            return "{0:0.0}s" -f $TimeSpan.TotalSeconds
        }
    else {
            return "{0:0}ms" -f $TimeSpan.TotalMilliseconds
        }
    }
    catch {
        return $TimeSpan.ToString()
    }
}

}

