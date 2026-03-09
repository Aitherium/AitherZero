#Requires -Version 7.0

<#
.SYNOPSIS
    Get current Windows Defender exclusions

.DESCRIPTION
    Retrieves and displays all currently configured Windows Defender exclusions
    including path, process, and extension exclusions.
    
    Useful for auditing what is currently excluded from real-time scanning
    and verifying that development performance optimizations are in place.

.PARAMETER Type
    Filter by exclusion type: Path, Process, Extension, or All (default)

.PARAMETER Raw
    Return raw arrays instead of formatted output

.EXAMPLE
    Get-AitherDefenderExclusions
    
    Display all current Defender exclusions in a formatted view.

.EXAMPLE
    Get-AitherDefenderExclusions -Type Path
    
    Show only path exclusions.

.EXAMPLE
    Get-AitherDefenderExclusions -Raw
    
    Return exclusions as a hashtable for programmatic use.

.OUTPUTS
    PSCustomObject with exclusion details, or formatted console output

.NOTES
    Requires: Windows 10/11
    Does not require administrator privileges to view exclusions.

.LINK
    Set-AitherDefenderExclusions
#>
function Get-AitherDefenderExclusions {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateSet('All', 'Path', 'Process', 'Extension')]
        [string]$Type = 'All',

        [Parameter()]
        [switch]$Raw
    )

    process {
        try {
            # During module validation, skip execution
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
                return $null
            }

            # Check platform
            if (-not ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT')) {
                Write-AitherLog -Message "Defender exclusions are only applicable to Windows" -Level Warning -Source 'Get-AitherDefenderExclusions'
                return $null
            }

            # Get current preferences
            try {
                $prefs = Get-MpPreference -ErrorAction Stop
            } catch {
                Write-AitherLog -Message "Unable to get Defender preferences: $_" -Level Warning -Source 'Get-AitherDefenderExclusions'
                return $null
            }

            $exclusions = @{
                Paths = @($prefs.ExclusionPath | Where-Object { $_ } | Sort-Object)
                Processes = @($prefs.ExclusionProcess | Where-Object { $_ } | Sort-Object)
                Extensions = @($prefs.ExclusionExtension | Where-Object { $_ } | Sort-Object)
            }

            if ($Raw) {
                switch ($Type) {
                    'Path' { return $exclusions.Paths }
                    'Process' { return $exclusions.Processes }
                    'Extension' { return $exclusions.Extensions }
                    default { return $exclusions }
                }
            }

            # Formatted output
            Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Get-AitherDefenderExclusions'
            Write-AitherLog -Level Information -Message "  WINDOWS DEFENDER EXCLUSIONS" -Source 'Get-AitherDefenderExclusions'
            Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Get-AitherDefenderExclusions'

            if ($Type -eq 'All' -or $Type -eq 'Path') {
                Write-AitherLog -Level Information -Message "📁 PATH EXCLUSIONS ($($exclusions.Paths.Count)):" -Source 'Get-AitherDefenderExclusions'
                if ($exclusions.Paths.Count -eq 0) {
                    Write-AitherLog -Level Information -Message "   (none configured)" -Source 'Get-AitherDefenderExclusions'
                } else {
                    $exclusions.Paths | ForEach-Object {
                        $exists = Test-Path $_ -ErrorAction SilentlyContinue
                        $icon = if ($exists) { "✓" } else { "✗" }
                        Write-AitherLog -Level Information -Message "   $icon $_" -Source 'Get-AitherDefenderExclusions'
                    }
                }
            }

            if ($Type -eq 'All' -or $Type -eq 'Process') {
                Write-AitherLog -Level Information -Message "⚙️  PROCESS EXCLUSIONS ($($exclusions.Processes.Count)):" -Source 'Get-AitherDefenderExclusions'
                if ($exclusions.Processes.Count -eq 0) {
                    Write-AitherLog -Level Information -Message "   (none configured)" -Source 'Get-AitherDefenderExclusions'
                } else {
                    $exclusions.Processes | ForEach-Object {
                        Write-AitherLog -Level Information -Message "   • $_" -Source 'Get-AitherDefenderExclusions'
                    }
                }
            }

            if ($Type -eq 'All' -or $Type -eq 'Extension') {
                Write-AitherLog -Level Information -Message "📄 EXTENSION EXCLUSIONS ($($exclusions.Extensions.Count)):" -Source 'Get-AitherDefenderExclusions'
                if ($exclusions.Extensions.Count -eq 0) {
                    Write-AitherLog -Level Information -Message "   (none configured)" -Source 'Get-AitherDefenderExclusions'
                } else {
                    $line = "   "
                    foreach ($ext in $exclusions.Extensions) {
                        if (($line + ".$ext").Length -gt 70) {
                            Write-AitherLog -Level Information -Message $line -Source 'Get-AitherDefenderExclusions'
                            $line = "   "
                        }
                        $line += ".$ext  "
                    }
                    if ($line.Trim()) { Write-AitherLog -Level Information -Message $line -Source 'Get-AitherDefenderExclusions' }
                }
            }

            Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Get-AitherDefenderExclusions'

            # Return object for pipeline
            return [PSCustomObject]@{
                PSTypeName = 'AitherZero.DefenderExclusions'
                PathCount = $exclusions.Paths.Count
                ProcessCount = $exclusions.Processes.Count
                ExtensionCount = $exclusions.Extensions.Count
                Paths = $exclusions.Paths
                Processes = $exclusions.Processes
                Extensions = $exclusions.Extensions
            }
        }
        catch {
            Write-AitherLog -Message "Failed to get Defender exclusions: $_" -Level Error -Source 'Get-AitherDefenderExclusions' -Exception $_
            throw
        }
    }
}

