#Requires -Version 7.0

<#
.SYNOPSIS
    Configure Windows Defender exclusions for development performance

.DESCRIPTION
    Adds Windows Defender exclusions to improve development performance by preventing
    real-time scanning of source code, build artifacts, and development tools.
    
    This function configures three types of exclusions:
    - Path Exclusions: Folders excluded from real-time scanning
    - Process Exclusions: Executables excluded from behavior monitoring  
    - Extension Exclusions: File types excluded from scanning

    Configuration is read from config.windows.psd1 under Windows.DefenderExclusions
    or uses sensible defaults for common development scenarios.

.PARAMETER Force
    Apply exclusions even if AutoApply is disabled in config. Also skips confirmation.

.PARAMETER Remove
    Removes the configured exclusions instead of adding them.

.PARAMETER ShowOutput
    Display detailed output during execution.

.EXAMPLE
    Set-AitherDefenderExclusions
    
    Apply all configured Defender exclusions with confirmation.

.EXAMPLE
    Set-AitherDefenderExclusions -Force
    
    Apply exclusions without confirmation prompt.

.EXAMPLE
    Set-AitherDefenderExclusions -Remove
    
    Remove the configured exclusions.

.OUTPUTS
    PSCustomObject with summary of changes made

.NOTES
    Requires: Windows 10/11, Administrator privileges
    Impact: Reduces security coverage for excluded paths - use judiciously
    
    This significantly improves IDE responsiveness, build times, and general
    development performance when working with AitherZero projects.

.LINK
    Get-AitherDefenderExclusions
    Enable-AitherWindowsLongPath
#>
function Set-AitherDefenderExclusions {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$Remove,

        [Parameter(HelpMessage = "Show command output in console.")]
        [switch]$ShowOutput
    )

    begin {
        # Manage logging targets for this execution
        $originalLogTargets = $script:AitherLogTargets
        if ($ShowOutput) {
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
    }

    process {
        try {
            # During module validation, skip execution
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
                return $null
            }

            # Check platform
            if (-not ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT')) {
                Write-AitherLog -Message "Defender exclusions are only applicable to Windows" -Level Warning -Source 'Set-AitherDefenderExclusions'
                return $null
            }

            # Check for admin rights
            $isAdmin = if (Get-Command Test-AitherAdmin -ErrorAction SilentlyContinue) {
                Test-AitherAdmin
            } else {
                $currentPrincipal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
                $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            }

            if (-not $isAdmin) {
                Write-AitherLog -Message "Administrator privileges required to configure Defender exclusions" -Level Error -Source 'Set-AitherDefenderExclusions'
                Write-AitherLog -Message "To run as Administrator: Start-Process pwsh -Verb RunAs -ArgumentList '-Command', 'Set-AitherDefenderExclusions'" -Level Information -Source 'Set-AitherDefenderExclusions'
                return $null
            }

            # Check if Defender is available
            try {
                $defenderStatus = Get-MpComputerStatus -ErrorAction Stop
                if (-not $defenderStatus.AntivirusEnabled) {
                    Write-AitherLog -Message "Windows Defender is not enabled" -Level Warning -Source 'Set-AitherDefenderExclusions'
                    return $null
                }
            } catch {
                Write-AitherLog -Message "Windows Defender not available: $_" -Level Warning -Source 'Set-AitherDefenderExclusions'
                return $null
            }

            # Find and run the automation script
            $scriptPath = $null
            $moduleRoot = if (Get-Command Get-AitherModuleRoot -ErrorAction SilentlyContinue) {
                Get-AitherModuleRoot
            } else {
                $PSScriptRoot
            }

            # Look for the script
            $possiblePaths = @(
                (Join-Path $moduleRoot 'library\automation-scripts\0101_Configure-DefenderExclusions.ps1')
                (Join-Path (Split-Path -Parent $moduleRoot) 'library\automation-scripts\0101_Configure-DefenderExclusions.ps1')
            )

            foreach ($path in $possiblePaths) {
                if (Test-Path $path) {
                    $scriptPath = $path
                    break
                }
            }

            if ($scriptPath -and (Test-Path $scriptPath)) {
                # Use the automation script
                $params = @{}
                if ($Force) { $params['Force'] = $true }
                if ($Remove) { $params['Remove'] = $true }
                
                & $scriptPath @params
            } else {
                # Inline implementation for when script is not found
                Write-AitherLog -Message "Running inline Defender exclusion configuration" -Level Debug -Source 'Set-AitherDefenderExclusions'
                
                $workspaceRoot = $env:AITHERZERO_ROOT
                if (-not $workspaceRoot) {
                    $workspaceRoot = if (Get-Command Get-AitherProjectRoot -ErrorAction SilentlyContinue) {
                        Get-AitherProjectRoot
                    } else {
                        Split-Path -Parent $moduleRoot
                    }
                }

                # Get current exclusions
                $prefs = Get-MpPreference
                $currentPaths = @($prefs.ExclusionPath | Where-Object { $_ })
                $currentProcesses = @($prefs.ExclusionProcess | Where-Object { $_ })
                $currentExtensions = @($prefs.ExclusionExtension | Where-Object { $_ })

                # Default exclusions
                $pathsToAdd = @($workspaceRoot)
                $processesToAdd = @(
                    'python.exe', 'pythonw.exe', 'node.exe', 'git.exe',
                    'pwsh.exe', 'code.exe', 'cursor.exe', 'docker.exe',
                    'cargo.exe', 'go.exe', 'ollama.exe'
                )
                $extensionsToAdd = @('pyc', 'pyo', 'obj', 'o', 'lock', 'lockb')

                # Add project-relative paths
                $relativeExclusions = @('.venv', 'venv', 'node_modules', '.git', '__pycache__', 'build', 'dist')
                foreach ($rel in $relativeExclusions) {
                    $fullPath = Join-Path $workspaceRoot $rel
                    if (Test-Path $fullPath) {
                        $pathsToAdd += $fullPath
                    }
                }

                $stats = @{
                    PathsAdded = 0
                    ProcessesAdded = 0
                    ExtensionsAdded = 0
                }

                $action = if ($Remove) { "Remove" } else { "Add" }

                if (-not $Force -and -not $Remove) {
                    Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Set-AitherDefenderExclusions'
                    Write-AitherLog -Level Information -Message "  WINDOWS DEFENDER EXCLUSIONS" -Source 'Set-AitherDefenderExclusions'
                    Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Set-AitherDefenderExclusions'
                    Write-AitherLog -Level Information -Message "  This will add exclusions to improve development performance." -Source 'Set-AitherDefenderExclusions'
                    Write-AitherLog -Level Information -Message "  Paths to exclude:" -Source 'Set-AitherDefenderExclusions'
                    $pathsToAdd | ForEach-Object { Write-AitherLog -Level Information -Message "    • $_" -Source 'Set-AitherDefenderExclusions' }
                    
                    $confirm = Read-Host "Apply these exclusions? (y/N)"
                    if ($confirm -ne 'y') {
                        Write-AitherLog -Level Information -Message "Operation cancelled." -Source 'Set-AitherDefenderExclusions'
                        return $null
                    }
                }

                # Apply exclusions
                foreach ($path in $pathsToAdd) {
                    if ($currentPaths -notcontains $path) {
                        try {
                            if ($Remove) {
                                Remove-MpPreference -ExclusionPath $path -ErrorAction Stop
                            } else {
                                Add-MpPreference -ExclusionPath $path -ErrorAction Stop
                            }
                            $stats.PathsAdded++
                            Write-AitherLog -Level Information -Message "  ✓ ${action}ed path: $path" -Source 'Set-AitherDefenderExclusions'
                        } catch {
                            Write-AitherLog -Level Error -Message "  ✗ Failed to $action path: $path - $_" -Source 'Set-AitherDefenderExclusions' -Exception $_
                        }
                    }
                }

                foreach ($proc in $processesToAdd) {
                    if ($currentProcesses -notcontains $proc) {
                        try {
                            if ($Remove) {
                                Remove-MpPreference -ExclusionProcess $proc -ErrorAction Stop
                            } else {
                                Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop
                            }
                            $stats.ProcessesAdded++
                        } catch {
                            # Silently continue for processes
                        }
                    }
                }

                foreach ($ext in $extensionsToAdd) {
                    if ($currentExtensions -notcontains $ext) {
                        try {
                            if ($Remove) {
                                Remove-MpPreference -ExclusionExtension $ext -ErrorAction Stop
                            } else {
                                Add-MpPreference -ExclusionExtension $ext -ErrorAction Stop
                            }
                            $stats.ExtensionsAdded++
                        } catch {
                            # Silently continue for extensions
                        }
                    }
                }

                Write-AitherLog -Level Information -Message "  Summary: $($stats.PathsAdded) paths, $($stats.ProcessesAdded) processes, $($stats.ExtensionsAdded) extensions ${action}ed" -Source 'Set-AitherDefenderExclusions'
                Write-AitherLog -Level Information -Message "═══════════════════════════════════════════════════════════════" -Source 'Set-AitherDefenderExclusions'

                return [PSCustomObject]@{
                    PSTypeName = 'AitherZero.DefenderExclusionResult'
                    Success = $true
                    PathsChanged = $stats.PathsAdded
                    ProcessesChanged = $stats.ProcessesAdded
                    ExtensionsChanged = $stats.ExtensionsAdded
                    Action = $action
                }
            }
        }
        catch {
            Write-AitherLog -Message "Failed to configure Defender exclusions: $_" -Level Error -Source 'Set-AitherDefenderExclusions' -Exception $_
            throw
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }
}

