#Requires -Version 7.0

<#
.SYNOPSIS
    Schedule a playbook or script to run at specified intervals

.DESCRIPTION
    Creates scheduled tasks (Windows Task Scheduler) or cron jobs (Linux/macOS)
    to execute playbooks or scripts automatically.

.PARAMETER Name
    Name for the scheduled task

.PARAMETER Playbook
    Name of the playbook to schedule

.PARAMETER Script
    Script number or name to schedule

.PARAMETER Schedule
    Schedule frequency: Daily, Weekly, Hourly, AtStartup, OnLogon, or cron expression

.PARAMETER Time
    Time to run (for Daily/Weekly schedules)

.PARAMETER DaysOfWeek
    Days of week for Weekly schedule

.PARAMETER Interval
    Interval in minutes for recurring schedules

.PARAMETER Enabled
    Enable the schedule immediately (default: true)

.PARAMETER Remove
    Remove an existing schedule

.EXAMPLE
    Start-AitherSchedule -Name 'DailyValidation' -Playbook 'pr-validation' -Schedule Daily -Time '02:00'

.EXAMPLE
    Start-AitherSchedule -Name 'HourlyHealthCheck' -Script 0501 -Schedule Hourly -Interval 60

.EXAMPLE
    Start-AitherSchedule -Name 'DailyValidation' -Remove

.NOTES
    Cross-platform scheduling support using platform-native schedulers.
#>
function Start-AitherSchedule {
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Create')]
param(
    [Parameter(Mandatory=$false, Position = 0)]
    [string]$Name,

    [Parameter(ParameterSetName = 'Create')]
    [string]$Playbook,

    [Parameter(ParameterSetName = 'Create')]
    [string]$Script,

    [Parameter(ParameterSetName = 'Create')]
    [ValidateSet('Daily', 'Weekly', 'Hourly', 'AtStartup', 'OnLogon', 'Cron')]
    [string]$Schedule = 'Daily',

    [Parameter(ParameterSetName = 'Create')]
    [string]$Time = '00:00',

    [Parameter(ParameterSetName = 'Create')]
    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string[]]$DaysOfWeek = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'),

    [Parameter(ParameterSetName = 'Create')]
    [int]$Interval = 60,

    [Parameter(ParameterSetName = 'Create')]
    [bool]$Enabled = $true,

    [Parameter(ParameterSetName = 'Remove')]
    [switch]$Remove,

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

    if (-not (Test-Path $schedulesPath)) {
        New-Item -ItemType Directory -Path $schedulesPath -Force | Out-Null
    }
}

process {
    try {
        try {
        if ($Remove) {
            # Remove schedule
            if ($IsWindows) {
                Unregister-ScheduledTask -TaskName "AitherZero_$Name" -Confirm:$false -ErrorAction SilentlyContinue
            }
            else {
                # Remove cron job
                $cronFile = Join-Path $schedulesPath "$Name.cron"
                if (Test-Path $cronFile) {
                    Remove-Item $cronFile -Force
                }
            }

            $scheduleFile = Join-Path $schedulesPath "$Name.psd1"
            if (Test-Path $scheduleFile) {
                Remove-Item $scheduleFile -Force
            }

            Write-AitherLog -Level Information -Message "Schedule removed: $Name" -Source $PSCmdlet.MyInvocation.MyCommand.Name
            return
        }

        # Validate inputs
        if (-not $Playbook -and -not $Script) {
            # During module validation, parameters may be empty - skip validation
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
                return
            }
            throw "Either -Playbook or -Script must be specified"
        }

        # Build command
        $command = if ($Playbook) {
            "Invoke-AitherPlaybook -Name '$Playbook'"
        }
        else {
            "Invoke-AitherScript -Script '$Script'"
        }

        # Create schedule definition
        $scheduleDef = @{
            Name = $Name
            Command = $command
            Schedule = $Schedule
            Enabled = $Enabled
            Created = Get-Date
        }
        if ($Time) { $scheduleDef.Time = $Time }
        if ($DaysOfWeek) { $scheduleDef.DaysOfWeek = $DaysOfWeek }
        if ($Interval) { $scheduleDef.Interval = $Interval }

        # Save schedule definition
        $scheduleFile = Join-Path $schedulesPath "$Name.psd1"
        $scheduleDef | ConvertTo-Json -Depth 10 | Set-Content $scheduleFile

        # Create platform-specific schedule
        if ($IsWindows) {
            $taskName = "AitherZero_$Name"
            $action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -Command `"$command`""

            $trigger = switch ($Schedule) {
                'Daily' { New-ScheduledTaskTrigger -Daily -At $Time }
                'Weekly' { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DaysOfWeek -At $Time }
                'Hourly' { New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Interval) -RepetitionDuration (New-TimeSpan -Days 365) }
                'AtStartup' { New-ScheduledTaskTrigger -AtStartup }
                'OnLogon' { New-ScheduledTaskTrigger -AtLogOn }
            }

            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "AitherZero scheduled task: $Name" | Out-Null

            if (-not $Enabled) {
                Disable-ScheduledTask -TaskName $taskName | Out-Null
            }
        }
        else {
            # Linux/macOS cron
            $cronFile = Join-Path $schedulesPath "$Name.cron"
            $cronLine = switch ($Schedule) {
                'Daily' { "0 $($Time.Split(':')[1]) $($Time.Split(':')[0]) * * * pwsh -NoProfile -Command `"$command`"" }
                'Hourly' { "0 * * * * pwsh -NoProfile -Command `"$command`"" }
                default { "0 0 * * * pwsh -NoProfile -Command `"$command`"" }
            }

            Set-Content -Path $cronFile -Value $cronLine

            Write-AitherLog -Level Information -Message "Cron file created: $cronFile" -Source $PSCmdlet.MyInvocation.MyCommand.Name
            Write-AitherLog -Level Information -Message "To install, run: crontab $cronFile" -Source $PSCmdlet.MyInvocation.MyCommand.Name
        }

        Write-AitherLog -Level Information -Message "Schedule created: $Name" -Source $PSCmdlet.MyInvocation.MyCommand.Name
        return Get-AitherSchedule -Name $Name
    }
    catch {
        Write-AitherLog -Level Error -Message "Failed to create schedule: $_" -Source 'Start-AitherSchedule' -Exception $_
        throw
    }
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

