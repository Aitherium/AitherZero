#Requires -Version 7.0

<#
.SYNOPSIS
    Internal logging function for AitherZero module
.DESCRIPTION
    Provides structured logging with multiple targets - internal use only.
    Public interface is Write-AitherLog.
#>

# Script-level variables for logging state
if (-not (Get-Variable -Name 'Script:AitherLogPath' -Scope Script -ErrorAction SilentlyContinue)) {
    # Use Get-AitherModuleRoot if available, otherwise calculate from PSScriptRoot
    # PSScriptRoot is .../AitherZero/Private, so we need to go up 2 levels to get project root
    $projectRoot = if (Get-Command Get-AitherModuleRoot -ErrorAction SilentlyContinue) {
        Get-AitherModuleRoot
    }
    elseif ($script:ProjectRoot) {
        $script:ProjectRoot
    }
    elseif ($env:AITHERZERO_ROOT) {
        $env:AITHERZERO_ROOT
    }
    else {
        # Fallback: calculate from PSScriptRoot (Private -> AitherZero -> Project)
        Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }

    $script:AitherLogPath = Join-Path $projectRoot "AitherZero/library/logs"
    $script:AitherLogLevel = "Information"
    $script:AitherLogTargets = @("File")
    $script:AitherLogBuffer = @()
    $script:AitherBufferSize = 100
}

function Write-CustomLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Source = "General",

        [hashtable]$Data = @{},

        [System.Exception]$Exception,

        [string[]]$Targets
    )

    # Log level hierarchy
    $logLevels = @{
        'Trace'       = 0
        'Debug'       = 1
        'Information' = 2
        'Warning'     = 3
        'Error'       = 4
        'Critical'    = 5
    }

    # Check if we should log this based on configured level
    $currentLevel = if ($script:AitherLogLevel -and $logLevels.ContainsKey($script:AitherLogLevel)) {
        $logLevels[$script:AitherLogLevel]
    }
    else {
        2 # Default to Information
    }

    $messageLevel = if ($Level -and $logLevels.ContainsKey($Level)) {
        $logLevels[$Level]
    }
    else {
        2 # Default to Information
    }

    if ($messageLevel -lt $currentLevel) {
        return
    }

    # Determine active targets
    $activeTargets = if ($Targets) { $Targets } else { $script:AitherLogTargets }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

    # Create structured log entry
    $logEntry = [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Source    = $Source
        Message   = $Message
        Data      = $Data
        Exception = if ($Exception) { $Exception.ToString() } else { $null }
        ProcessId = $PID
        ThreadId  = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        User      = if ($IsWindows) {
            try { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $env:USERNAME }
        }
        else { $env:USER }
        Computer  = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { $env:HOSTNAME }
    }

    # Write to console
    if ($activeTargets -contains 'Console') {
        $color = switch ($Level) {
            'Trace' { 'DarkGray' }
            'Debug' { 'Gray' }
            'Information' { 'White' }
            'Warning' { 'Yellow' }
            'Error' { 'Red' }
            'Critical' { 'Magenta' }
            default { 'White' }
        }

        $prefix = switch ($Level) {
            'Trace' { '[TRACE]' }
            'Debug' { '[DEBUG]' }
            'Information' { '[INFO]' }
            'Warning' { '[WARN]' }
            'Error' { '[ERROR]' }
            'Critical' { '[CRIT]' }
            default { '[INFO]' }
        }

        Write-Host "$prefix [$timestamp] $Source`: $Message" -ForegroundColor $color

        if ($Exception) {
            Write-Host "  Exception: $($Exception.ToString())" -ForegroundColor $color
        }
    }

    # Write to file
    if ($activeTargets -contains 'File') {
        try {
            if (-not (Test-Path $script:AitherLogPath)) {
                New-Item -Path $script:AitherLogPath -ItemType Directory -Force | Out-Null
            }

            $logFile = Join-Path $script:AitherLogPath "aitherzero-$(Get-Date -Format 'yyyy-MM-dd').log"
            $logLine = "[$timestamp] [$Level] [$Source] $Message"

            if ($Data.Count -gt 0) {
                $dataStr = ($Data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
                $logLine += " | Data: $dataStr"
            }

            if ($Exception) {
                $logLine += "`n  Exception: $($Exception.ToString())"
            }

            Add-Content -Path $logFile -Value $logLine -ErrorAction SilentlyContinue
        }
        catch {
            # Fail silently for logging errors
        }
    }

    # Add to buffer
    $script:AitherLogBuffer += $logEntry
    if ($script:AitherLogBuffer.Count -ge $script:AitherBufferSize) {
        # Clear buffer (simplified - just reset)
        $script:AitherLogBuffer = @()
    }
}

