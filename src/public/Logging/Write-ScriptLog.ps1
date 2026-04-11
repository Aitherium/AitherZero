function Write-ScriptLog {
    <#
    .SYNOPSIS
        Writes a log message with a timestamp and level.
    .DESCRIPTION
        Writes a formatted log message using the centralized Write-AitherLog function.
        Supports different log levels: Information, Warning, Error, Debug, Success.
        This is a convenience wrapper around Write-AitherLog for backward compatibility.
    .PARAMETER Message
        The message to log.
    .PARAMETER Level
        The log level. Default is 'Information'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('Information', 'Warning', 'Error', 'Debug', 'Success')]
        [string]$Level = 'Information'
    )

    # Map 'Success' to 'Information' level for Write-AitherLog
    $aitherLevel = if ($Level -eq 'Success') { 'Information' } else { $Level }
    
    # Use centralized logging
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Level $aitherLevel -Message $Message -Source 'Write-ScriptLog'
    }
    else {
        # Fallback if Write-AitherLog not available
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logMessage = "[$timestamp] [$Level] $Message"
        switch ($Level) {
            'Error' { Write-Error $logMessage }
            'Warning' { Write-Warning $logMessage }
            'Debug' { Write-Debug $logMessage }
            'Success' { Write-Host $logMessage -ForegroundColor Green }
            'Information' { Write-Host $logMessage }
            default { Write-Verbose $logMessage }
        }
    }
}
