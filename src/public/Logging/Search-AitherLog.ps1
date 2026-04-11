#Requires -Version 7.0

<#
.SYNOPSIS
    Search logs with advanced filtering and pattern matching

.DESCRIPTION
    Advanced log search with regex support, multiple file search, and context lines.
    More powerful than Get-AitherLog for complex searches across multiple files and
    advanced pattern matching with regular expressions.

    This cmdlet searches through log files using regular expressions, supports context
    lines (showing surrounding log entries), and can search across multiple log files
    or date ranges.

.PARAMETER Pattern
    Search pattern using regular expressions. This parameter is REQUIRED.
    Supports full .NET regular expression syntax.

    Examples:
    - 'error|failed' - Find entries containing "error" or "failed"
    - '^\[' - Find entries starting with "["
    - 'timeout|timed out' - Find entries with timeout-related text
    - '\d{4}-\d{2}-\d{2}' - Find entries with date patterns
    - 'ERROR.*Invoke-AitherScript' - Find ERROR entries from Invoke-AitherScript

    Regular expression reference:
    - . matches any character
    - * matches zero or more
    - + matches one or more
    - | means OR
    - ^ means start of line
    - $ means end of line
    - \d matches digits
    - \w matches word characters

.PARAMETER Path
    Log file or directory to search. If not specified, defaults to today's log file
    or the logs directory if -AllLogs is specified.

    Can be:
    - Single file: "aitherzero-2025-01-15.log"
    - Directory: "./library/logs" (searches all .log files in directory)
    - Absolute path: "C:\Logs\aitherzero.log"

.PARAMETER Context
    Show N lines of context before and after matches. Default is 0 (no context).
    Useful for understanding the circumstances around log entries.

    Examples:
    - Context 3 - Shows 3 lines before and after each match
    - Context 5 - Shows 5 lines before and after each match

    Context lines help understand what happened before and after an error or event.

.PARAMETER CaseSensitive
    Perform case-sensitive search. By default, searches are case-insensitive.
    Use this when case matters for your search pattern.

.PARAMETER AllLogs
    Search all log files in the logs directory, not just today's log.
    When combined with -Days, searches logs from the specified number of days.

    Useful for:
    - Finding events across multiple days
    - Historical analysis
    - Comprehensive troubleshooting

.PARAMETER Days
    Search logs from the last N days. Default is 1 (today only).
    Only applies when -AllLogs is specified or when searching a directory.

    Examples:
    - Days 7 - Search last week's logs
    - Days 30 - Search last month's logs

.PARAMETER Export
    Export search results to a file. Results are exported as JSON format.
    Useful for:
    - Saving search results for later analysis
    - Sharing results with team members
    - Creating reports

    Example: -Export "./search-results.json"

.INPUTS
    System.String
    You can pipe log file paths or search patterns to Search-AitherLog.

.OUTPUTS
    PSCustomObject
    Returns search result objects with properties:
    - File: Log file name
    - LineNumber: Line number in the file
    - Line: Matching line content
    - ContextBefore: Lines before the match (if Context > 0)
    - ContextAfter: Lines after the match (if Context > 0)

.EXAMPLE
    Search-AitherLog -Pattern 'error|failed' -Context 3

    Searches for entries containing "error" or "failed" with 3 lines of context.

.EXAMPLE
    Search-AitherLog -Pattern 'Invoke-AitherScript' -AllLogs -Days 7

    Searches for all entries mentioning Invoke-AitherScript in the last 7 days.

.EXAMPLE
    Search-AitherLog -Pattern '^\[' -CaseSensitive -Export './search-results.txt'

    Searches for lines starting with "[" (case-sensitive) and exports results.

.EXAMPLE
    Search-AitherLog -Pattern '\d{4}-\d{2}-\d{2}.*ERROR' -AllLogs

    Searches for ERROR entries with date patterns across all logs.

.EXAMPLE
    "error", "failed", "timeout" | Search-AitherLog -Context 2

    Searches for multiple patterns by piping them.

.NOTES
    More powerful than Get-AitherLog for complex searches across multiple files.
    Uses .NET regular expressions for pattern matching, providing full regex capabilities.

    Performance tips:
    - Use specific patterns to reduce search time
    - Limit -Days when searching large log archives
    - Use -Context sparingly as it increases processing time
    - Export results for large result sets instead of displaying

.LINK
    Get-AitherLog
    Write-AitherLog
    Clear-AitherLog
#>
function Search-AitherLog {
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position = 0, ValueFromPipeline)]
    [ValidateNotNullOrEmpty()]
    [string]$Pattern,

    [Parameter(ValueFromPipelineByPropertyName)]
    [string]$Path,

    [Parameter()]
    [ValidateRange(0, 100)]
    [int]$Context = 0,

    [Parameter()]
    [switch]$CaseSensitive,

    [Parameter()]
    [switch]$AllLogs,

    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$Days = 1,

    [Parameter()]
    [string]$Export
)

begin {
    $moduleRoot = Get-AitherModuleRoot
    $logsPath = Join-Path $moduleRoot 'AitherZero/library/logs'

    if (-not $Path) {
        if ($AllLogs) {
            $Path = $logsPath
        }
    else {
            $Path = Join-Path $logsPath "aitherzero-$(Get-Date -Format 'yyyy-MM-dd').log"
        }
    }
}

process { try {
        $files = @()

        if (Test-Path $Path -PathType Container) {
            # Directory - get log files
            $cutoffDate = (Get-Date).AddDays(-$Days)
            $files = Get-ChildItem -Path $Path -Filter '*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $cutoffDate }
        }
        elseif (Test-Path $Path) {
            # Single file
            $files = @(Get-Item $Path)
        }
        else {
            # Only show warning if user explicitly specified a path (not using default)
            if ($PSBoundParameters.ContainsKey('Path')) {
                Write-AitherLog -Level Warning -Message "Path not found: $Path" -Source 'Search-AitherLog'
            } else {
                # Silent when default path doesn't exist (normal when no logs yet)
                Write-Verbose "Log file not found (no logs written yet): $Path"
            }
            return @()
        }

        $results = @()
        $regexOptions = if ($CaseSensitive) { [System.Text.RegularExpressions.RegexOptions]::None } else { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }

        foreach ($file in $files) {
            $lines = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
            $lineNumber = 0

            foreach ($line in $lines) {
                $lineNumber++

                if ([regex]::IsMatch($line, $Pattern, $regexOptions)) {
                    $result = [PSCustomObject]@{
                        File = $file.Name
                        LineNumber = $lineNumber
                        Line = $line
                        ContextBefore = @()
                        ContextAfter = @()
                    }

                    # Add context
                    if ($Context -gt 0) {
                        $start = [Math]::Max(0, $lineNumber - $Context - 1)
                        $end = [Math]::Min($lines.Count - 1, $lineNumber + $Context - 1)

                        for ($i = $start; $i -le $end; $i++) {
                            if ($i -lt $lineNumber - 1) {
                                $result.ContextBefore += $lines[$i]
                            }
                            elseif ($i -gt $lineNumber - 1) {
                                $result.ContextAfter += $lines[$i]
                            }
                        }
                    }

                    $results += $result
                }
            }
        }

        # Export if requested
        if ($Export) {
            $results | ConvertTo-Json -Depth 10 | Set-Content -Path $Export
            Write-AitherLog -Level Information -Message "Results exported to: $Export" -Source 'Search-AitherLog'
        }

        return $results
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Searching logs with pattern: $Pattern" -Parameters $PSBoundParameters -ThrowOnError
    }
}

}

