#Requires -Version 7.0

<#
.SYNOPSIS
    Write log entries to AitherZero centralized logging system

.DESCRIPTION
    Writes structured log entries to the AitherZero logging system with support for
    multiple targets (console, file, JSON, EventLog). This is the primary logging
    function for AitherZero modules and automation scripts.

    This cmdlet is essential for all logging operations in AitherZero. It automatically
    formats log entries, applies log level filtering, and writes to all configured
    targets. Log entries include timestamps, source information, and optional structured data.

.PARAMETER Level
    Log level for the entry. This parameter is REQUIRED and determines the severity
    and visibility of the log entry.

    Valid values:
    - Trace: Very detailed diagnostic information (lowest level)
    - Debug: Diagnostic information for debugging
    - Information: General informational messages (default level)
    - Warning: Warning messages indicating potential issues
    - Error: Error messages indicating failures
    - Critical: Critical errors requiring immediate attention (highest level)

    Log level filtering is controlled by configuration - entries below the configured
    level will not be written.

.PARAMETER Message
    Log message text. This parameter is REQUIRED and contains the actual log message.
    Keep messages clear and descriptive for easier troubleshooting.

    Examples:
    - "Script execution started"
    - "Configuration file loaded successfully"
    - "Failed to connect to remote server"

.PARAMETER Source
    Source identifier for the log entry. Defaults to "General" if not specified.
    This helps identify where the log entry originated from.

    Common sources:
    - Function or cmdlet name (e.g., "Invoke-AitherScript")
    - Module name (e.g., "AitherZero")
    - Script name or component identifier

    Use consistent source names for easier filtering and searching.

.PARAMETER Data
    Additional structured data to include with the log entry. This is a hashtable
    containing key-value pairs of additional context.

    Examples:
    - @{ ScriptName = "0501"; ExitCode = 0 }
    - @{ ConfigFile = "config.local.psd1"; OverrideCount = 3 }
    - @{ Server = "server01"; Port = 5985 }

    Structured data is included in JSON logs and can be searched/filtered.

.PARAMETER Exception
    Exception object to log. When provided, includes the full exception details
    including stack trace. Use this when logging errors from try/catch blocks.

    Example:
    try {
        # Operation
    }
    catch {
        Write-AitherLog -Level Error -Message "Operation failed" -Exception $_
    }

.INPUTS
    System.String
    You can pipe log messages to Write-AitherLog. The Message parameter will be set
    from the pipeline input.

.OUTPUTS
    None
    Write-AitherLog does not return output. It writes to configured log targets.

.EXAMPLE
    Write-AitherLog -Level Information -Message "Script execution started" -Source "Invoke-AitherScript"

    Writes an informational log entry indicating script execution started.

.EXAMPLE
    Write-AitherLog -Level Error -Message "Failed to load configuration" -Source "Get-AitherConfigs" -Exception $_

    Writes an error log entry with exception details from a catch block.

.EXAMPLE
    Write-AitherLog -Level Warning -Message "Configuration override detected" -Source "Config" -Data @{ OverrideFile = "config.local.psd1" }

    Writes a warning log entry with structured data about a configuration override.

.EXAMPLE
    "Processing item 1", "Processing item 2", "Processing item 3" | Write-AitherLog -Level Debug -Source "ProcessItems"

    Writes multiple log entries by piping messages.

.EXAMPLE
    Write-AitherLog -Level Critical -Message "System resource exhausted" -Source "ResourceMonitor" -Data @{ CPU = 95; Memory = 98 }

    Writes a critical log entry with resource usage data.

.NOTES
    This function provides the primary logging interface for AitherZero modules and automation scripts.

    Log entries are written to:
    - Console (if enabled in configuration) - colored output based on log level
    - File: library/logs/aitherzero-YYYY-MM-DD.log - plain text format
    - Structured JSON: library/logs/structured/structured-YYYY-MM-DD.jsonl (if enabled) - machine-readable format

    Log level filtering is controlled by configuration. Entries below the configured minimum
    level will not be written to any target.

    All log entries include:
    - Timestamp (with millisecond precision)
    - Log level
    - Source identifier
    - Message text
    - Optional structured data
    - Optional exception details
    - Process and thread IDs
    - User and computer information

.LINK
    Get-AitherLog
    Search-AitherLog
    Clear-AitherLog
    Get-AitherErrorLog
#>
function Write-AitherLog {
[OutputType()]
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false, Position = 0)]
    [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
    [string]$Level,

    [Parameter(Mandatory=$false, Position = 1, ValueFromPipeline)]
    [ValidateNotNullOrEmpty()]
    [string]$Message,

    [Parameter()]
    [string]$Source = "General",

    [Parameter()]
    [hashtable]$Data = @{},

    [Parameter()]
    [System.Exception]$Exception,

    [Parameter()]
    [string[]]$Targets
)

begin {
    # Write-CustomLog is loaded from AitherZero/Private during module initialization
    # No need to import aithercore modules - we use the internal version
}

process {
    try {
        # Use Write-CustomLog directly (loaded from Private/)
        if (Get-Command Write-CustomLog -ErrorAction SilentlyContinue) {
            Write-CustomLog -Level $Level -Message $Message -Source $Source -Data $Data -Exception $Exception -Targets $Targets
        } else {
            # Fallback to simple console output
            $prefix = "[$Level]"
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Host "$prefix [$timestamp] $Source`: $Message" -ForegroundColor $(
                switch ($Level) {
                    'Error' { 'Red' }
                    'Warning' { 'Yellow' }
                    'Critical' { 'Magenta' }
                    default { 'White' }
                }
            )
        }
    }
    catch {
        # Silent fallback
        Write-Verbose "Logging failed: $_"
    }
}

}

