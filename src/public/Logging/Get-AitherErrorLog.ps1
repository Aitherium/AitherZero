#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieve error logs for debugging and troubleshooting

.DESCRIPTION
    Retrieves error logs from the AitherZero logging system. Filters errors by various
    criteria and provides detailed error information including stack traces, parameters,
    and context for debugging.

    This cmdlet is essential for troubleshooting issues and understanding what went wrong
    during script execution or module operations.

.PARAMETER Since
    Only return errors that occurred after this date/time. Useful for filtering recent errors.

    Examples:
    - (Get-Date).AddHours(-1) - Last hour
    - (Get-Date).AddDays(-1) - Last 24 hours
    - "2025-01-15" - Since a specific date

.PARAMETER Until
    Only return errors that occurred before this date/time.

.PARAMETER Cmdlet
    Filter errors by cmdlet name. Returns only errors from the specified cmdlet(s).

    Examples:
    - "Invoke-AitherScript"
    - "Get-AitherConfigs", "Set-AitherConfig"

.PARAMETER ErrorId
    Filter by specific error ID. Use this to find a specific error that was reported.

.PARAMETER ComputerName
    Filter errors by computer name. Useful in multi-machine environments.

.PARAMETER Level
    Filter by error level. Default is 'Error', but you can also get 'Warning' or 'Critical' level entries.

.PARAMETER Count
    Maximum number of errors to return. Default is 100. Use -1 for all errors.

.PARAMETER Format
    Output format: Object (default), Table, List, or JSON.

.INPUTS
    System.String
    You can pipe error IDs or cmdlet names to Get-AitherErrorLog.

.OUTPUTS
    PSCustomObject
    Returns error log entries with properties:
    - ErrorId: Unique error identifier
    - Timestamp: When the error occurred
    - Cmdlet: Cmdlet that generated the error
    - Level: Error level (Error, Warning, Critical)
    - Message: Error message
    - Exception: Exception details
    - StackTrace: Stack trace for debugging
    - Parameters: Parameters that were passed
    - ComputerName: Computer where error occurred

.EXAMPLE
    Get-AitherErrorLog

    Gets the most recent 100 errors.

.EXAMPLE
    Get-AitherErrorLog -Since (Get-Date).AddHours(-1)

    Gets errors from the last hour.

.EXAMPLE
    Get-AitherErrorLog -Cmdlet "Invoke-AitherScript" -Count 50

    Gets the 50 most recent errors from Invoke-AitherScript.

.EXAMPLE
    Get-AitherErrorLog -ErrorId "12345678-1234-1234-1234-123456789abc"

    Gets a specific error by its ID.

.EXAMPLE
    Get-AitherErrorLog -Since (Get-Date).AddDays(-1) -Format JSON | Out-File errors.json

    Exports yesterday's errors to a JSON file.

.EXAMPLE
    "Invoke-AitherScript", "Get-AitherConfigs" | Get-AitherErrorLog

    Gets errors from multiple cmdlets by piping cmdlet names.

.NOTES
    Error logs are stored in:
    - Structured JSON: library/logs/structured/structured-YYYY-MM-DD.jsonl
    - Text logs: library/logs/aitherzero-YYYY-MM-DD.log

    This cmdlet searches both sources to provide comprehensive error information.

.LINK
    Export-AitherErrorReport
    Write-AitherLog
#>
function Get-AitherErrorLog {
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    [Parameter()]
    [DateTime]$Since,

    [Parameter()]
    [DateTime]$Until,

    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]]$Cmdlet,

    [Parameter(ValueFromPipelineByPropertyName)]
    [string[]]$ErrorId,

    [Parameter()]
    [string]$ComputerName,

    [Parameter()]
    [ValidateSet('Error', 'Warning', 'Critical')]
    [string]$Level = 'Error',

    [Parameter()]
    [int]$Count = 100,

    [Parameter()]
    [ValidateSet('Object', 'Table', 'List', 'JSON')]
    [string]$Format = 'Object',

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
    $structuredPath = Join-Path $logsPath 'structured'
    $allErrors = @()
}

process { try {
        # Search structured JSON logs
        if (Test-Path $structuredPath) {
            $jsonlFiles = Get-ChildItem -Path $structuredPath -Filter "structured-*.jsonl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

            foreach ($file in $jsonlFiles) {
                # Check date range if specified
                if ($Since -and $file.LastWriteTime -lt $Since) {
                    continue
                }
                if ($Until -and $file.CreationTime -gt $Until) {
                    continue
                }

                $lines = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
                foreach ($line in $lines) {
                    try {
                        $entry = $line | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue

                        if ($entry -and $entry.Level -eq $Level) {
                            # Apply filters
                            if ($Cmdlet -and $entry.Source -notin $Cmdlet) {
                                continue
                            }
                            if ($ErrorId -and $entry.ErrorId -notin $ErrorId) {
                                continue
                            }
                            if ($ComputerName -and $entry.Computer -ne $ComputerName) {
                                continue
                            }
                            if ($Since -and [DateTime]$entry.Timestamp -lt $Since) {
                                continue
                            }
                            if ($Until -and [DateTime]$entry.Timestamp -gt $Until) {
                                continue
                            }

                            $allErrors += $entry
                        }
                    }
                    catch {
                        # Skip invalid JSON lines
                        continue
                    }
                }
            }
        }

        # Also search text logs if structured logs don't have enough
        if ($allErrors.Count -lt $Count -or $Count -eq -1) {
            $textLogFiles = Get-ChildItem -Path $logsPath -Filter "aitherzero-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

            foreach ($file in $textLogFiles) {
                if ($Since -and $file.LastWriteTime -lt $Since) {
                    continue
                }
                if ($Until -and $file.CreationTime -gt $Until) {
                    continue
                }

                $lines = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
                foreach ($line in $lines) {
                    if ($line -match '\[ERROR\]|\[CRITICAL\]') {
                        # Parse log line format: [timestamp] [LEVEL] [Source] Message
                        if ($line -match '\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\]\s+\[(\w+)\]\s+\[([^\]]+)\]\s+(.+)') {
                            $logTimestamp = [DateTime]::Parse($matches[1])
                            $logLevel = $matches[2]
                            $logSource = $matches[3]
                            $logMessage = $matches[4]

                            # Apply filters
                            if ($Level -ne $logLevel -and $logLevel -ne 'CRITICAL') {
                                continue
                            }
        if ($Cmdlet -and $logSource -notin $Cmdlet) {
                                continue
                            }
        if ($Since -and $logTimestamp -lt $Since) {
                                continue
                            }
        if ($Until -and $logTimestamp -gt $Until) {
                                continue
                            }

                            $allErrors += [PSCustomObject]@{
                                Timestamp = $logTimestamp
                                Level = $logLevel
                                Source = $logSource
                                Message = $logMessage
                                ErrorId = [System.Guid]::NewGuid().ToString()
                            }
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-AitherLog -Level Warning -Message "Error reading error logs: $($_.Exception.Message)" -Source $PSCmdlet.MyInvocation.MyCommand.Name
    }
}

end {
    try {
        try {
        # Sort by timestamp (newest first) and limit count
        $sortedErrors = $allErrors | Sort-Object Timestamp -Descending

        if ($Count -gt 0) {
            $sortedErrors = $sortedErrors | Select-Object -First $Count
        }

        # Format output
        switch ($Format) {
            'Table' {
                return $sortedErrors | Format-Table -AutoSize
            }
            'List' {
                return $sortedErrors | Format-List
            }
            'JSON' {
                return $sortedErrors | ConvertTo-Json -Depth 10
            }
            default {
                return $sortedErrors
            }
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Retrieving error logs" -Parameters $PSBoundParameters -ThrowOnError
    }
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}


}

