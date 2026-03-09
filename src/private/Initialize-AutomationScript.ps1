#Requires -Version 7.0

<#
.SYNOPSIS
    Initialize automation script with logging and transcript

.DESCRIPTION
    Private helper function to initialize automation scripts with:
    - Centralized logging integration
    - Transcript logging (enabled by default)
    - Configuration access

.PARAMETER ScriptPath
    Path to the automation script

.PARAMETER Transcript
    Enable transcript logging (default: true)

.PARAMETER TranscriptPath
    Custom transcript path

.NOTES
    This function is called by automation scripts to set up logging.
#>
function Initialize-AutomationScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter()]
        [bool]$Transcript = $true,

        [Parameter()]
        [string]$TranscriptPath
    )

    $script:AutomationScriptInitialized = $true
    $script:AutomationScriptPath = $ScriptPath
    $script:AutomationScriptName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)

    # Get module root
    $moduleRoot = if ($env:AITHERZERO_ROOT) {
        $env:AITHERZERO_ROOT
    } else {
        Split-Path (Split-Path $PSScriptRoot -Parent -Parent) -Parent
    }

    # Write-CustomLog is loaded from AitherZero/Private/ during module initialization
    # No need to import aithercore modules

    # Start transcript if enabled
    if ($Transcript) {
        try {
            if (-not $TranscriptPath) {
                $logsDir = Join-Path $moduleRoot 'logs'
                if (-not (Test-Path $logsDir)) {
                    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
                }
                $TranscriptPath = Join-Path $logsDir "transcript-${script:AutomationScriptName}-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"
            }

            Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
            Start-Transcript -Path $TranscriptPath -Append -IncludeInvocationHeader | Out-Null
            $script:AutomationTranscriptPath = $TranscriptPath
            
            if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                Write-AitherLog -Message "Transcript logging started: $TranscriptPath" -Level 'Information' -Source 'AutomationScript'
            }
        }
        catch {
            Write-Warning "Failed to start transcript: $_"
        }
    }

    # Return configuration access helper
    return @{
        GetConfig = {
            if (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue) {
                Get-AitherConfigs @args
            } else {
                Write-Warning "Get-AitherConfigs function not available"
                $null
            }
        }
        StopTranscript = {
            if ($script:AutomationTranscriptPath) {
                try {
                    Stop-Transcript | Out-Null
                    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
                        Write-AitherLog -Message "Transcript logging stopped" -Level 'Information' -Source 'AutomationScript'
                    }
                }
                catch {
                    # Ignore errors stopping transcript
                }
            }
        }
    }
}


