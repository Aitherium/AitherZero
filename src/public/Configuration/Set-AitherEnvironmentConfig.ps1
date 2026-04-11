#Requires -Version 7.0

<#
.SYNOPSIS
    Apply environment configuration from config file

.DESCRIPTION
    Applies environment configuration settings including:
    - Windows long path support
    - Developer mode
    - Environment variables
    - PATH modifications
    - Shell integration (Unix)

    Settings are read from config.psd1 EnvironmentConfiguration section.

.PARAMETER ConfigFile
    Path to configuration file (defaults to config.psd1 in module root)

.PARAMETER Category
    Specific category to apply: All, Windows, Unix, EnvironmentVariables, or Path

.PARAMETER DryRun
    Preview changes without applying them

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    Set-AitherEnvironmentConfig

    Apply all environment configuration from config.psd1

.EXAMPLE
    Set-AitherEnvironmentConfig -Category Windows -DryRun

    Preview Windows configuration changes without applying

.EXAMPLE
    Set-AitherEnvironmentConfig -Force

    Apply configuration without confirmation prompts

.OUTPUTS
    Hashtable - Result object with Success, AppliedChanges, and DryRun properties

.NOTES
    Requires administrator privileges for some Windows features and Machine-scope environment variables.
    Use -DryRun to preview changes before applying.

.LINK
    Get-AitherEnvironmentConfig
    Enable-AitherWindowsLongPath
    Enable-AitherWindowsDeveloperMode
#>
function Set-AitherEnvironmentConfig {
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigFile,

    [ValidateSet('All', 'Windows', 'Unix', 'EnvironmentVariables', 'Path')]
    [string]$Category = 'All',

    [switch]$DryRun,

    [switch]$Force,

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
    else {
        # Ensure Console is NOT in targets if ShowOutput is not specified
        $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
    }

    # Get module root
    $moduleRoot = Get-AitherModuleRoot

    if (-not $ConfigFile) {
        $ConfigFile = Join-Path $moduleRoot 'config.psd1'
    }
    elseif (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
        $ConfigFile = Join-Path $moduleRoot $ConfigFile
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return @{}
        }

        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Applying environment configuration (Category: $Category, DryRun: $DryRun)" -Level Information -Source 'Set-AitherEnvironmentConfig'
        }

        # Load configuration
        if (-not (Test-Path $ConfigFile)) {
            throw "Configuration file not found: $ConfigFile"
        }

        if (-not (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Get-AitherConfigs is not available. Cannot apply environment configuration." -Source 'Set-AitherEnvironmentConfig'
            return @{}
        }

        $config = Get-AitherConfigs -ConfigFile $ConfigFile

        if (-not $config.EnvironmentConfiguration) {
            throw "No EnvironmentConfiguration section found in config"
        }

        $envConfig = $config.EnvironmentConfiguration
        $appliedChanges = @()

        # Apply Windows configuration
        if ($Category -in @('All', 'Windows') -and ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT')) {
            if ($envConfig.Windows.LongPathSupport.Enabled -and $envConfig.Windows.LongPathSupport.AutoApply) {
                if (Get-Command Enable-AitherWindowsLongPath -ErrorAction SilentlyContinue) {
                    $result = Enable-AitherWindowsLongPath -DryRun:$DryRun -Force:$Force
                    if ($result) {
                        $appliedChanges += 'Windows Long Path Support'
                    }
                }
            }
            if ($envConfig.Windows.DeveloperMode.Enabled -and $envConfig.Windows.DeveloperMode.AutoApply) {
                if (Get-Command Enable-AitherWindowsDeveloperMode -ErrorAction SilentlyContinue) {
                    $result = Enable-AitherWindowsDeveloperMode -DryRun:$DryRun -Force:$Force
                    if ($result) {
                        $appliedChanges += 'Windows Developer Mode'
                    }
                }
            }
        }

        # Apply environment variables
        if ($Category -in @('All', 'EnvironmentVariables')) {
            # User variables
            if ($envConfig.EnvironmentVariables.User) {
                foreach ($key in $envConfig.EnvironmentVariables.User.Keys) {
                    $value = $envConfig.EnvironmentVariables.User[$key]
                    if ($value) {
                        if (-not $DryRun) {
                            [Environment]::SetEnvironmentVariable($key, $value, 'User')
                            if ($hasWriteAitherLog) {
                                Write-AitherLog -Message "Set user environment variable: $key" -Level Information -Source 'Set-AitherEnvironmentConfig'
                            }
                        }
                        else {
                            if ($hasWriteAitherLog) {
                                Write-AitherLog -Message "[DRY RUN] Would set user environment variable: $key = $value" -Level Information -Source 'Set-AitherEnvironmentConfig'
                            }
                        }
                        $appliedChanges += "User variable: $key"
                    }
                }
            }

            # Process variables
            if ($envConfig.EnvironmentVariables.Process) {
                foreach ($key in $envConfig.EnvironmentVariables.Process.Keys) {
                    $value = $envConfig.EnvironmentVariables.Process[$key]
                    if ($value) {
                        if (-not $DryRun) {
                            [Environment]::SetEnvironmentVariable($key, $value, 'Process')
                            if ($hasWriteAitherLog) {
                                Write-AitherLog -Message "Set process environment variable: $key" -Level Information -Source 'Set-AitherEnvironmentConfig'
                            }
                        }
                        else {
                            if ($hasWriteAitherLog) {
                                Write-AitherLog -Message "[DRY RUN] Would set process environment variable: $key = $value" -Level Information -Source 'Set-AitherEnvironmentConfig'
                            }
                        }
                        $appliedChanges += "Process variable: $key"
                    }
                }
            }
        }

        # Apply PATH configuration
        if ($Category -in @('All', 'Path') -and $envConfig.PathConfiguration.AddToPath) {
            if ($envConfig.PathConfiguration.Paths.User.Count -gt 0) {
                if (Get-Command Add-AitherPathEntries -ErrorAction SilentlyContinue) {
                    $result = Add-AitherPathEntries -Paths $envConfig.PathConfiguration.Paths.User -Scope 'User' -DryRun:$DryRun
                    if ($result) {
                        $appliedChanges += 'User PATH entries'
                    }
                }
            }
        }

        # Unix configuration
        if ($Category -in @('All', 'Unix') -and ($IsLinux -or $IsMacOS)) {
            if ($envConfig.Unix.ShellIntegration.Enabled -and $envConfig.Unix.ShellIntegration.AddToProfile) {
                if (Get-Command Add-AitherShellIntegration -ErrorAction SilentlyContinue) {
                    $result = Add-AitherShellIntegration -DryRun:$DryRun -Force:$Force
                    if ($result) {
                        $appliedChanges += 'Shell integration'
                    }
                }
            }
        }

        # Summary
        if ($appliedChanges.Count -gt 0) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "Applied $($appliedChanges.Count) configuration changes:" -Level Information -Source 'Set-AitherEnvironmentConfig'
                foreach ($change in $appliedChanges) {
                    Write-AitherLog -Message "  - $change" -Level Information -Source 'Set-AitherEnvironmentConfig'
                }
            }
        }
        else {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "No configuration changes needed" -Level Information -Source 'Set-AitherEnvironmentConfig'
            }
        }

        return @{
            Success = $true
            AppliedChanges = $appliedChanges
            DryRun = $DryRun.IsPresent
        }
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error applying environment configuration: $($_.Exception.Message)" -Level Error -Source 'Set-AitherEnvironmentConfig' -Exception $_
        } else {
            Write-Error "Error applying environment configuration: $($_.Exception.Message)"
        }
        throw
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

