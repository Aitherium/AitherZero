#Requires -Version 7.0

<#
.SYNOPSIS
    Get scheduled playbooks and scripts

.DESCRIPTION
    Lists all scheduled tasks and their status.

.PARAMETER Name
    Name of specific schedule to retrieve

.PARAMETER List
    List all schedules

.EXAMPLE
    Get-AitherSchedule -List

.EXAMPLE
    Get-AitherSchedule -Name 'DailyValidation'

.NOTES
    Shows both saved schedule definitions and active platform schedules.
#>
function Get-AitherSchedule {
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'Get')]
    [string]$Name,

    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [switch]$ShowOutput
)

begin {
    # Save original log targets
    $originalLogTargets = $script:AitherLogTargets

    # Set log targets based on ShowOutput parameter
    if ($ShowOutput) {
        # Ensure Console is in the log targets
        if ($script:AitherLogTargets -notcontains 'Console') {
            $script:AitherLogTargets += 'Console'
        }
    }
    else {
        # Remove Console from log targets if present (default behavior)
        if ($script:AitherLogTargets -contains 'Console') {
            $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
        }
    }

    $moduleRoot = Get-AitherModuleRoot
    $schedulesPath = Join-Path $moduleRoot 'library' 'schedules'
}

process {
    try {
        try {
        if (-not (Test-Path $schedulesPath)) {
            return @()
        }

        $schedules = Get-ChildItem -Path $schedulesPath -Filter '*.psd1' -ErrorAction SilentlyContinue

        if ($Name) {
            $scheduleFile = $schedules | Where-Object { $_.BaseName -eq $Name } | Select-Object -First 1
            if (-not $scheduleFile) {
                Write-AitherLog -Level Warning -Message "Schedule not found: $Name" -Source 'Get-AitherSchedule'
                return $null
            }

            $schedule = Get-Content $scheduleFile.FullName | ConvertFrom-Json

            # Check platform schedule status
            $status = 'Unknown'
            if ($IsWindows) {
                $task = Get-ScheduledTask -TaskName "AitherZero_$Name" -ErrorAction SilentlyContinue
                $status = if ($task) {
                    if ($task.State -eq 'Ready') { 'Enabled' } else { 'Disabled' }
                } else { 'NotRegistered' }

                return [PSCustomObject]@{
                    Name = $schedule.Name
                    Command = $schedule.Command
                    Schedule = $schedule.Schedule
                    Time = $schedule.Time
                    Enabled = $schedule.Enabled
                    Status = $status
                    Created = $schedule.Created
                    Path = $scheduleFile.FullName
                }
            }
        }

        # List all
        return $schedules | ForEach-Object {
            try {
                $schedule = Get-Content $_.FullName | ConvertFrom-Json
                $status = 'Unknown'

                if ($IsWindows) {
                    $task = Get-ScheduledTask -TaskName "AitherZero_$($schedule.Name)" -ErrorAction SilentlyContinue
                    $status = if ($task) {
                        if ($task.State -eq 'Ready') { 'Enabled' } else { 'Disabled' }
                    } else { 'NotRegistered' }
                }

                [PSCustomObject]@{
                    Name = $schedule.Name
                    Schedule = $schedule.Schedule
                    Status = $status
                    Enabled = $schedule.Enabled
                }
            }
            catch {
                [PSCustomObject]@{
                    Name = $_.BaseName
                    Schedule = 'Error'
                    Status = 'Invalid'
                    Enabled = $false
                }
            }
        }
    }
    catch {
        Write-AitherLog -Level Error -Message "Failed to get schedule: $_" -Source 'Get-AitherSchedule' -Exception $_
        throw
    }
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

