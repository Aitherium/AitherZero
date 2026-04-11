#Requires -Version 7.0

<#
.SYNOPSIS
    Get and filter log entries from AitherZero logs

.DESCRIPTION
    Retrieves log entries from AitherZero log files with filtering, searching,
    and formatting options. Supports both structured JSON logs and text logs.

    This cmdlet is essential for troubleshooting and monitoring. It can filter logs
    by level, source, time range, and message content. Supports both human-readable
    and machine-readable output formats.

.PARAMETER Level
    Filter by log level(s). You can specify multiple levels. Only entries matching
    the specified levels will be returned.

    Valid values: Trace, Debug, Information, Warning, Error, Critical

    Examples:
    - "Error" - Only error entries
    - "Warning", "Error" - Warning and error entries
    - "Error", "Critical" - Error and critical entries

.PARAMETER Source
    Filter by log source. Uses pattern matching (wildcards supported).
    This helps find all log entries from a specific function, module, or component.

    Examples:
    - "Invoke-AitherScript" - All entries from Invoke-AitherScript
    - "*Script*" - All entries from sources containing "Script"
    - "Config" - All entries from Config-related sources

.PARAMETER Message
    Search for text in log messages. Uses regular expression matching.
    This is useful for finding specific events or error messages.

    Examples:
    - "failed" - Find all entries containing "failed"
    - "^Error" - Find entries starting with "Error"
    - "timeout|timed out" - Find entries containing "timeout" or "timed out"

.PARAMETER Since
    Get logs since this date/time. Only entries with timestamps after this time
    will be returned. Useful for filtering recent logs.

    Examples:
    - (Get-Date).AddHours(-1) - Last hour
    - (Get-Date).AddDays(-1) - Last 24 hours
    - "2025-01-15 10:00:00" - Since a specific date/time

.PARAMETER Until
    Get logs until this date/time. Only entries with timestamps before this time
    will be returned. Use together with Since to define a time range.

.PARAMETER Last
    Get the last N log entries. Returns the most recent entries matching other filters.
    Useful for quick checks of recent activity.

    Example: -Last 50 returns the 50 most recent matching entries.

.PARAMETER Tail
    Tail/follow log file (like tail -f). Continuously monitors the log file and
    displays new entries as they are written. Press Ctrl+C to stop.

    Useful for real-time monitoring of script execution or troubleshooting.

.PARAMETER LogFile
    Specific log file path. If not specified, defaults to today's log file.
    Can be a relative path (relative to logs directory) or absolute path.

    Examples:
    - "aitherzero-2025-01-15.log" - Specific date's log
    - "structured/structured-2025-01-15.jsonl" - Specific structured log
    - "C:\Logs\aitherzero.log" - Absolute path

.PARAMETER Format
    Output format for log entries. Default is Table for human-readable output.

    - Table: Formatted table (default, human-readable)
    - List: Detailed list format with all properties
    - Json: JSON format (machine-readable, preserves all data)
    - Raw: Raw log lines as they appear in the file

.PARAMETER Count
    Count matching entries instead of returning them. Returns only the number
    of entries matching the filters. Useful for quick statistics.

.PARAMETER LogType
    Type of logs to read. Default is Auto which detects available log types.

    - Text: Plain text logs only
    - Structured: JSON-structured logs only (JSONL format)
    - Both: Read from both text and structured logs
    - Auto: Automatically detect and use available log type (default)

.PARAMETER Structured
    Alias for LogType Structured. Shortcut to read only structured JSON logs.

.INPUTS
    System.String
    You can pipe log file paths to Get-AitherLog.

.OUTPUTS
    PSCustomObject
    Returns log entry objects with properties: Timestamp, Level, Source, Message, Data, Exception, etc.

    When -Count is used, returns System.Int32 (the count).

.EXAMPLE
    Get-AitherLog -Level Error -Last 50

    Gets the 50 most recent error log entries.

.EXAMPLE
    Get-AitherLog -Source 'Invoke-AitherScript' -Since (Get-Date).AddHours(-1)

    Gets all log entries from Invoke-AitherScript in the last hour.

.EXAMPLE
    Get-AitherLog -Message 'failed' -Level Warning,Error

    Searches for entries containing "failed" at Warning or Error level.

.EXAMPLE
    Get-AitherLog -Structured -Level Error

    Gets error entries from structured JSON logs only.

.EXAMPLE
    Get-AitherLog -LogType Both -Since (Get-Date).AddHours(-1)

    Gets all log entries from both text and structured logs in the last hour.

.EXAMPLE
    Get-AitherLog -Tail

    Monitors the log file in real-time, displaying new entries as they are written.

.EXAMPLE
    Get-AitherLog -Count

    Counts total log entries (or matching entries if filters are applied).

.EXAMPLE
    "aitherzero-2025-01-15.log", "aitherzero-2025-01-16.log" | Get-AitherLog -Level Error

    Gets error entries from multiple log files by piping file paths.

.NOTES
    Supports both JSON-structured logs (JSONL format) and plain text logs.

    Log file locations:
    - Structured logs: library/logs/structured/structured-YYYY-MM-DD.jsonl
    - Text logs: library/logs/aitherzero-YYYY-MM-DD.log

    Structured logs contain more detailed information including:
    - Full exception details
    - Structured data objects
    - Correlation IDs
    - Operation IDs
    - Performance metrics

    Text logs are simpler but still contain all essential information.

.LINK
    Write-AitherLog
    Search-AitherLog
    Clear-AitherLog
    Get-AitherErrorLog
#>
function Get-AitherLog {
[OutputType([PSCustomObject], [System.Int32])]
[CmdletBinding(DefaultParameterSetName = 'Filter')]
param(
    [Parameter()]
    [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
    [string[]]$Level,

    [Parameter()]
    [string]$Source,

    [Parameter()]
    [string]$Message,

    [Parameter()]
    [datetime]$Since,

    [Parameter()]
    [datetime]$Until,

    [Parameter(ParameterSetName = 'Last')]
    [int]$Last,

    [Parameter(ParameterSetName = 'Tail')]
    [switch]$Tail,

    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string]$LogFile,

    [Parameter()]
    [ValidateSet('Table', 'List', 'Json', 'Raw')]
    [string]$Format = 'Table',

    [Parameter()]
    [switch]$Count,

    [Parameter()]
    [ValidateSet('Text', 'Structured', 'Both', 'Auto')]
    [string]$LogType = 'Auto',

    [Parameter()]
    [Alias('Structured')]
    [switch]$StructuredOnly,

    [switch]$ShowOutput
)

begin {
    $moduleRoot = Get-AitherModuleRoot
    $logsPath = Join-Path $moduleRoot 'AitherZero/library/logs'

    # Determine log type
    if ($StructuredOnly) {
        $LogType = 'Structured'
    }

    if ($LogType -eq 'Auto' -and -not $LogFile) {
        # Auto-detect: prefer structured if available, fallback to text
        $structuredPath = Join-Path $logsPath 'structured' "structured-$(Get-Date -Format 'yyyy-MM-dd').jsonl"
        $textPath = Join-Path $logsPath "aitherzero-$(Get-Date -Format 'yyyy-MM-dd').log"

        if (Test-Path $structuredPath) {
            $LogType = 'Structured'
        }
        elseif (Test-Path $textPath) {
            $LogType = 'Text'
        }
        else {
            $LogType = 'Text'  # Default to text
        }
    }

    if (-not $LogFile) {
        if ($LogType -eq 'Structured') {
            $LogFile = Join-Path $logsPath 'structured' "structured-$(Get-Date -Format 'yyyy-MM-dd').jsonl"
        }
        else {
            $LogFile = Join-Path $logsPath "aitherzero-$(Get-Date -Format 'yyyy-MM-dd').log"
        }
    }
    elseif (-not [System.IO.Path]::IsPathRooted($LogFile)) {
        $LogFile = Join-Path $logsPath $LogFile
    }

    function Parse-LogEntry {
        param([string]$Line)

        # Try to parse structured log format: [timestamp] [LEVEL] [Source] message
        if ($Line -match '^\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)\]\s+\[(\w+)\]\s+\[([^\]]+)\]\s+(.+)$') {
            return [PSCustomObject]@{
                Timestamp = [datetime]::Parse($matches[1])
                Level = $matches[2]
                Source = $matches[3]
                Message = $matches[4]
                Raw = $Line
            }
        }

        # Fallback: return raw line
        return [PSCustomObject]@{
            Timestamp = Get-Date
            Level = 'Information'
            Source = 'Unknown'
            Message = $Line
            Raw = $Line
        }
    }

    function Parse-StructuredLogEntry {
        param([string]$JsonLine)

        try {
            $entry = $JsonLine | ConvertFrom-Json

            # Handle different structured log formats
            if ($entry.'@timestamp') {
                # Structured log format from Write-StructuredLog
                return [PSCustomObject]@{
                    Timestamp = [datetime]::Parse($entry.'@timestamp')
                    Level = $entry.level
                    Source = $entry.source
                    Message = $entry.message
                    Data = $entry.properties
                    Tags = $entry.tags
                    CorrelationId = $entry.correlation_id
                    OperationId = $entry.operation_id
                    Metrics = $entry.metrics
                    Environment = $entry.environment
                    Raw = $JsonLine
                }
            }
            elseif ($entry.Timestamp) {
                # Standard log entry format
                return [PSCustomObject]@{
                    Timestamp = if ($entry.Timestamp -is [string]) { [datetime]::Parse($entry.Timestamp) } else { $entry.Timestamp }
                    Level = $entry.Level
                    Source = $entry.Source
                    Message = $entry.Message
                    Data = $entry.Data
                    Exception = $entry.Exception
                    ProcessId = $entry.ProcessId
                    ThreadId = $entry.ThreadId
                    User = $entry.User
                    Computer = $entry.Computer
                    Raw = $JsonLine
                }
            }
        }
        catch {
            Write-AitherLog -Level Warning -Message "Failed to parse structured log entry: $_" -Source 'Get-AitherLog' -Exception $_
            return $null
        }
    }

    function Get-LogEntriesFromFile {
        param(
            [string]$FilePath,
            [string]$Type
        )

        if (-not (Test-Path $FilePath)) {
            return @()
        }

        if ($Type -eq 'Structured') {
            # Read JSONL file (one JSON object per line)
            $entries = Get-Content -Path $FilePath -ErrorAction SilentlyContinue |
                Where-Object { $_ -and $_.Trim() } |
                ForEach-Object {
                    $entry = Parse-StructuredLogEntry -JsonLine $_
                    if ($entry) { $entry }
                }
            return $entries
        }
        else {
            # Read text log file
            $entries = Get-Content -Path $FilePath -ErrorAction Stop | ForEach-Object {
                Parse-LogEntry -Line $_
            }
            return $entries
        }
    }
}

process {
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

    try {
        $allEntries = @()

        # Determine which log files to read
        if ($LogType -eq 'Both' -and -not $LogFile) {
            # Read from both text and structured logs (auto-detect today's files)
            $textLogFile = Join-Path $logsPath "aitherzero-$(Get-Date -Format 'yyyy-MM-dd').log"
            $structuredLogFile = Join-Path $logsPath 'structured' "structured-$(Get-Date -Format 'yyyy-MM-dd').jsonl"

            if (Test-Path $textLogFile) {
                $allEntries += Get-LogEntriesFromFile -FilePath $textLogFile -Type 'Text'
            }
        if (Test-Path $structuredLogFile) {
                $allEntries += Get-LogEntriesFromFile -FilePath $structuredLogFile -Type 'Structured'
            }
        }
    else {
            # Read from single log file
            if (-not (Test-Path $LogFile)) {
                Write-AitherLog -Level Warning -Message "Log file not found: $LogFile" -Source 'Get-AitherLog'
                return @()
            }

            # Determine log type from file extension if not specified
            $detectedType = $LogType
            if ($LogType -eq 'Auto' -or $LogType -eq 'Both') {
                if ($LogFile -match '\.jsonl?$') {
                    $detectedType = 'Structured'
                }
    else {
                    $detectedType = 'Text'
                }
            }

            # Tail mode
            if ($Tail) {
                if ($detectedType -eq 'Structured') {
                    Get-Content -Path $LogFile -Wait -Tail 0 | ForEach-Object {
                        if ($_ -and $_.Trim()) {
                            $entry = Parse-StructuredLogEntry -JsonLine $_
                            if ($entry) { Write-Output $entry }
                        }
                    }
                }
    else {
                    Get-Content -Path $LogFile -Wait -Tail 0 | ForEach-Object {
                        $entry = Parse-LogEntry -Line $_
                        Write-Output $entry
                    }
                }
                return
            }

            # Read log file
            $allEntries = Get-LogEntriesFromFile -FilePath $LogFile -Type $detectedType
        }

        # Apply filters
        if ($Level) {
            $allEntries = $allEntries | Where-Object { $_.Level -in $Level }
        }
        if ($Source) {
            $allEntries = $allEntries | Where-Object { $_.Source -like "*$Source*" }
        }
        if ($Message) {
            $allEntries = $allEntries | Where-Object { $_.Message -match $Message }
        }
        if ($Since) {
            $allEntries = $allEntries | Where-Object { $_.Timestamp -ge $Since }
        }
        if ($Until) {
            $allEntries = $allEntries | Where-Object { $_.Timestamp -le $Until }
        }

        # Sort by timestamp (newest first)
        $allEntries = $allEntries | Sort-Object Timestamp -Descending

        # Apply Last filter
        if ($Last -gt 0) {
            $allEntries = $allEntries | Select-Object -First $Last
        }

        # Count mode
        if ($Count) {
            return $allEntries.Count
        }

        # Format output
        switch ($Format) {
            'Table' {
                $allEntries | Select-Object Timestamp, Level, Source, Message | Format-Table -AutoSize
            }
            'List' {
                $allEntries | Format-List
            }
            'Json' {
                $allEntries | ConvertTo-Json -Depth 10
            }
            'Raw' {
                $allEntries | ForEach-Object { $_.Raw }
            }
            default {
                $allEntries
            }
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Getting log entries" -Parameters $PSBoundParameters -ThrowOnError
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

