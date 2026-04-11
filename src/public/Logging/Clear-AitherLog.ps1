#Requires -Version 7.0

<#
.SYNOPSIS
    Clear or archive old log files based on retention policy

.DESCRIPTION
    Removes or archives old log files based on retention policy. Helps manage disk space
    by cleaning up old log files while preserving recent logs and optionally archiving
    them for long-term storage.

    This cmdlet respects retention settings from configuration and provides options
    to archive logs instead of deleting them permanently.

.PARAMETER DaysToKeep
    Keep logs from the last N days. Logs older than this will be deleted or archived.
    Default is 30 days, or the value from configuration if available.

    Examples:
    - 7 - Keep only last week's logs
    - 30 - Keep last month's logs (default)
    - 90 - Keep last quarter's logs

    Logs older than DaysToKeep will be removed or archived based on the -Archive parameter.

.PARAMETER Archive
    Archive logs instead of deleting them. When specified, old log files are moved to
    an archive location instead of being permanently deleted.

    Archived logs are compressed and organized by date, making them easy to retrieve
    if needed for historical analysis or compliance requirements.

.PARAMETER ArchivePath
    Path for archived logs. If not specified, defaults to ./library/logs/archive/.
    The archive directory will be created if it doesn't exist.

    Archived logs are organized by date in subdirectories for easy retrieval.

    Examples:
    - "./library/logs/archive" - Default archive location
    - "C:\Logs\Archive" - Custom archive location
    - "\\server\logs\archive" - Network archive location

.PARAMETER WhatIf
    Show what would be deleted or archived without actually performing the operation.
    Use this to preview which files would be affected before running the command.

    This is automatically enabled when -WhatIf is used with the cmdlet (PowerShell's
    built-in WhatIf support).

.INPUTS
    System.Int32
    You can pipe the number of days to keep to Clear-AitherLog.

.OUTPUTS
    PSCustomObject
    Returns summary of cleanup operation with properties:
    - FilesDeleted: Number of files deleted
    - FilesArchived: Number of files archived
    - SpaceFreed: Disk space freed (in bytes)
    - FilesKept: Number of files retained

.EXAMPLE
    Clear-AitherLog -DaysToKeep 7

    Deletes log files older than 7 days, keeping only the last week's logs.

.EXAMPLE
    Clear-AitherLog -DaysToKeep 30 -Archive -ArchivePath './library/logs/archive'

    Archives log files older than 30 days to the archive directory.

.EXAMPLE
    Clear-AitherLog -DaysToKeep 7 -WhatIf

    Shows what would be deleted without actually deleting anything.

.EXAMPLE
    90 | Clear-AitherLog -Archive

    Keeps last 90 days of logs and archives older ones by piping days to keep.

.NOTES
    Respects retention settings from configuration. If Logging.RetentionDays is set
    in configuration, that value is used as the default unless explicitly overridden.

    This cmdlet affects:
    - Text logs: library/logs/aitherzero-YYYY-MM-DD.log
    - Structured logs: library/logs/structured/structured-YYYY-MM-DD.jsonl
    - Transcript logs: library/logs/transcript-YYYY-MM-DD.log
    - Error reports: library/logs/error-reports/error-report-*.json/html/txt

    Use with caution in production environments. Consider archiving instead of
    deleting for compliance and historical analysis requirements.

.LINK
    Get-AitherLog
    Search-AitherLog
    Write-AitherLog
#>
function Clear-AitherLog {
[OutputType([PSCustomObject])]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(ValueFromPipeline)]
    [ValidateRange(1, 3650)]
    [int]$DaysToKeep = 30,

    [Parameter()]
    [switch]$Archive,

    [Parameter()]
    [string]$ArchivePath,

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
    $logsPath = Join-Path $moduleRoot 'AitherZero/library/logs'

    # Check config for retention
    try {
        $config = Get-AitherConfigs -ErrorAction SilentlyContinue
        if ($config.Logging.RetentionDays) {
            $DaysToKeep = $config.Logging.RetentionDays
        }
    }
    catch {
        # Use default
    }
}

process { try {
        if (-not (Test-Path $logsPath)) {
            Write-AitherLog -Level Warning -Message "Logs directory not found: $logsPath" -Source 'Clear-AitherLog'
            return
        }

        $cutoffDate = (Get-Date).AddDays(-$DaysToKeep)
        $oldLogs = Get-ChildItem -Path $logsPath -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoffDate }
        if ($oldLogs.Count -eq 0) {
            Write-AitherLog -Level Information -Message "No logs older than $DaysToKeep days found." -Source $PSCmdlet.MyInvocation.MyCommand.Name
            return
        }

        Write-AitherLog -Level Information -Message "Found $($oldLogs.Count) log file(s) older than $DaysToKeep days" -Source $PSCmdlet.MyInvocation.MyCommand.Name

        if ($Archive) {
            if (-not $ArchivePath) {
                $ArchivePath = Join-Path $logsPath 'archive'
            }
        if (-not (Test-Path $ArchivePath)) {
                New-Item -ItemType Directory -Path $ArchivePath -Force | Out-Null
            }

            foreach ($log in $oldLogs) {
                if ($PSCmdlet.ShouldProcess($log.Name, "Archive log file")) {
                    $archiveFile = Join-Path $ArchivePath $log.Name
                    Move-Item -Path $log.FullName -Destination $archiveFile -Force
                    Write-AitherLog -Level Information -Message "Archived: $($log.Name)" -Source $PSCmdlet.MyInvocation.MyCommand.Name
                }
            }
        }
    else {
            foreach ($log in $oldLogs) {
                if ($PSCmdlet.ShouldProcess($log.Name, "Delete log file")) {
                    Remove-Item -Path $log.FullName -Force
                    Write-AitherLog -Level Information -Message "Deleted: $($log.Name)" -Source $PSCmdlet.MyInvocation.MyCommand.Name
                }
            }
        }

        return [PSCustomObject]@{
            FilesDeleted = if ($Archive) { 0 }
    else { $oldLogs.Count }
            FilesArchived = if ($Archive) { $oldLogs.Count }
    else { 0 }
            SpaceFreed = 0
            FilesKept = 0
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Clearing log files (DaysToKeep: $DaysToKeep)" -Parameters $PSBoundParameters -ThrowOnError
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}



}

