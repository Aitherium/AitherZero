#Requires -Version 7.0
#Requires -RunAsAdministrator

# Stage: Infrastructure
# Dependencies: None
# Description: Configure Windows Defender exclusions for development performance

<#
.SYNOPSIS
    Configures Windows Defender exclusions for a development environment.

.DESCRIPTION
    This script adds exclusions to Windows Defender to improve development performance.
    Real-time scanning of source code, build artifacts, and development tools can
    significantly impact IDE responsiveness, build times, and overall system performance.

    The script configures three types of exclusions:
    - Path Exclusions: Folders excluded from real-time scanning
    - Process Exclusions: Executables excluded from behavior monitoring
    - Extension Exclusions: File types excluded from scanning

    Configuration is read from config.windows.psd1 under Windows.DefenderExclusions.

.PARAMETER WorkspaceRoot
    Root directory of your project/workspace. Defaults to two levels above this script.

.PARAMETER Configuration
    Optional hashtable containing the configuration. If not provided, loads from config files.

.PARAMETER Force
    Apply exclusions even if AutoApply is disabled in config.

.PARAMETER WhatIf
    Shows what exclusions would be applied without making changes.

.PARAMETER Remove
    Removes the configured exclusions instead of adding them.

.PARAMETER ShowCurrent
    Displays currently configured Defender exclusions and exits.

.EXAMPLE
    .\0101_Configure-DefenderExclusions.ps1
    Applies all configured exclusions.

.EXAMPLE
    .\0101_Configure-DefenderExclusions.ps1 -WorkspaceRoot "D:\Projects\MyRepo"
    Applies exclusions for a specific workspace.

.EXAMPLE
    .\0101_Configure-DefenderExclusions.ps1 -WhatIf
    Shows what would be changed without applying.

.EXAMPLE
    .\0101_Configure-DefenderExclusions.ps1 -ShowCurrent
    Lists all current Defender exclusions.

.EXAMPLE
    .\0101_Configure-DefenderExclusions.ps1 -Remove
    Removes the configured exclusions.

.NOTES
    Requires: Windows 10/11, Administrator privileges
    Impact: Reduces security coverage for excluded paths - use judiciously
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$WorkspaceRoot,

    [Parameter()]
    [hashtable]$Configuration,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$Remove,

    [Parameter()]
    [switch]$ShowCurrent
)

. "$PSScriptRoot/_init.ps1"
Write-ScriptLog "Starting Windows Defender exclusion configuration"

# ============================================================================
# Helper Functions
# ============================================================================

function Expand-ConfigPath {
    <#
    .SYNOPSIS
        Expands environment variables in a path string.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    # Expand environment variables
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)

    # Handle PowerShell-style $env: variables
    if ($expanded -match '\$env:') {
        $expanded = $ExecutionContext.InvokeCommand.ExpandString($Path)
    }

    return $expanded
}

function Get-CurrentExclusions {
    <#
    .SYNOPSIS
        Retrieves current Windows Defender exclusions.
    #>
    try {
        $prefs = Get-MpPreference -ErrorAction Stop
        return @{
            Paths = @($prefs.ExclusionPath | Where-Object { $_ })
            Processes = @($prefs.ExclusionProcess | Where-Object { $_ })
            Extensions = @($prefs.ExclusionExtension | Where-Object { $_ })
        }
    } catch {
        Write-ScriptLog "Failed to get current exclusions: $_" -Level 'Error'
        return @{
            Paths = @()
            Processes = @()
            Extensions = @()
        }
    }
}

function Show-CurrentExclusions {
    <#
    .SYNOPSIS
        Displays current Windows Defender exclusions in a formatted view.
    #>
    $current = Get-CurrentExclusions
    
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  WINDOWS DEFENDER EXCLUSIONS - CURRENT STATE" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
    
    Write-Host "📁 PATH EXCLUSIONS ($($current.Paths.Count)):" -ForegroundColor Yellow
    if ($current.Paths.Count -eq 0) {
        Write-Host "   (none configured)" -ForegroundColor DarkGray
    } else {
        $current.Paths | Sort-Object | ForEach-Object {
            $exists = Test-Path $_
            $icon = if ($exists) { "✓" } else { "✗" }
            $color = if ($exists) { "Green" } else { "DarkGray" }
            Write-Host "   $icon $_" -ForegroundColor $color
        }
    }
    
    Write-Host "`n⚙️  PROCESS EXCLUSIONS ($($current.Processes.Count)):" -ForegroundColor Yellow
    if ($current.Processes.Count -eq 0) {
        Write-Host "   (none configured)" -ForegroundColor DarkGray
    } else {
        $current.Processes | Sort-Object | ForEach-Object {
            Write-Host "   • $_" -ForegroundColor White
        }
    }
    
    Write-Host "`n📄 EXTENSION EXCLUSIONS ($($current.Extensions.Count)):" -ForegroundColor Yellow
    if ($current.Extensions.Count -eq 0) {
        Write-Host "   (none configured)" -ForegroundColor DarkGray
    } else {
        $extensions = $current.Extensions | Sort-Object
        $line = "   "
        foreach ($ext in $extensions) {
            if (($line + $ext).Length -gt 70) {
                Write-Host $line -ForegroundColor White
                $line = "   "
            }
            $line += "$ext  "
        }
        if ($line.Trim()) { Write-Host $line -ForegroundColor White }
    }
    
    Write-Host "`n═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
}

function Add-DefenderExclusion {
    <#
    .SYNOPSIS
        Adds a Windows Defender exclusion.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Path', 'Process', 'Extension')]
        [string]$Type,
        
        [Parameter(Mandatory)]
        [string]$Value,
        
        [string[]]$CurrentExclusions
    )
    
    # Check if already excluded
    if ($CurrentExclusions -contains $Value) {
        Write-ScriptLog "  Already excluded: $Value" -Level 'Debug'
        return $false
    }
    
    try {
        switch ($Type) {
            'Path' {
                Add-MpPreference -ExclusionPath $Value -ErrorAction Stop
                Write-ScriptLog "  ✓ Added path exclusion: $Value" -Level 'Info'
            }
            'Process' {
                Add-MpPreference -ExclusionProcess $Value -ErrorAction Stop
                Write-ScriptLog "  ✓ Added process exclusion: $Value" -Level 'Info'
            }
            'Extension' {
                Add-MpPreference -ExclusionExtension $Value -ErrorAction Stop
                Write-ScriptLog "  ✓ Added extension exclusion: $Value" -Level 'Info'
            }
        }
        return $true
    } catch {
        Write-ScriptLog "  ✗ Failed to add $Type exclusion '$Value': $_" -Level 'Warning'
        return $false
    }
}

function Remove-DefenderExclusion {
    <#
    .SYNOPSIS
        Removes a Windows Defender exclusion.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Path', 'Process', 'Extension')]
        [string]$Type,
        
        [Parameter(Mandatory)]
        [string]$Value,
        
        [string[]]$CurrentExclusions
    )
    
    # Check if exists
    if ($CurrentExclusions -notcontains $Value) {
        Write-ScriptLog "  Not currently excluded: $Value" -Level 'Debug'
        return $false
    }
    
    try {
        switch ($Type) {
            'Path' {
                Remove-MpPreference -ExclusionPath $Value -ErrorAction Stop
                Write-ScriptLog "  ✓ Removed path exclusion: $Value" -Level 'Info'
            }
            'Process' {
                Remove-MpPreference -ExclusionProcess $Value -ErrorAction Stop
                Write-ScriptLog "  ✓ Removed process exclusion: $Value" -Level 'Info'
            }
            'Extension' {
                Remove-MpPreference -ExclusionExtension $Value -ErrorAction Stop
                Write-ScriptLog "  ✓ Removed extension exclusion: $Value" -Level 'Info'
            }
        }
        return $true
    } catch {
        Write-ScriptLog "  ✗ Failed to remove $Type exclusion '$Value': $_" -Level 'Warning'
        return $false
    }
}

# ============================================================================
# Main Script
# ============================================================================

try {
    # Check if Windows
    if (-not $IsWindows) {
        Write-ScriptLog "This script is Windows-only. Skipping on $($PSVersionTable.OS)" -Level 'Warning'
        exit 0
    }
    
    # Check if Defender is available
    try {
        $defenderStatus = Get-MpComputerStatus -ErrorAction Stop
        Write-ScriptLog "Windows Defender status: $($defenderStatus.AntivirusEnabled)"
        
        if (-not $defenderStatus.AntivirusEnabled) {
            Write-ScriptLog "Windows Defender is not enabled. Skipping exclusion configuration." -Level 'Warning'
            exit 0
        }
    } catch {
        Write-ScriptLog "Windows Defender not available or accessible: $_" -Level 'Warning'
        exit 0
    }
    
    # Handle ShowCurrent flag
    if ($ShowCurrent) {
        Show-CurrentExclusions
        exit 0
    }
    
    # Check administrator privileges
    $currentPrincipal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-ScriptLog "Administrator privileges required to configure Defender exclusions" -Level 'Error'
        Write-Host "`nPlease run this script as Administrator:" -ForegroundColor Yellow
        Write-Host "  Start-Process pwsh -Verb RunAs -ArgumentList '-File', '$PSCommandPath'" -ForegroundColor Cyan
        exit 1
    }
    
    # Get configuration
    $config = if ($Configuration) { $Configuration } else { @{} }
    
    # Try to load Windows config if not provided
    if (-not $config.Windows -or -not $config.Windows.DefenderExclusions) {
        $configPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\config.windows.psd1'
        if (Test-Path $configPath) {
            try {
                $windowsConfig = Import-PowerShellDataFile -Path $configPath -ErrorAction Stop
                if ($windowsConfig.Windows -and $windowsConfig.Windows.DefenderExclusions) {
                    $config = $windowsConfig
                    Write-ScriptLog "Loaded configuration from: $configPath" -Level 'Debug'
                }
            } catch {
                Write-ScriptLog "Failed to load Windows config: $_" -Level 'Warning'
            }
        }
    }
    
    $defenderConfig = $config.Windows.DefenderExclusions
    
    if (-not $defenderConfig) {
        Write-ScriptLog "No Defender exclusion configuration found. Using defaults." -Level 'Warning'
        
        # Default configuration if nothing is found
        $defenderConfig = @{
            AutoApply = $true
            PathExclusions = @(
                '$env:LOCALAPPDATA\pip'
                '$env:APPDATA\npm-cache'
                '$env:USERPROFILE\.cargo'
            )
            ProcessExclusions = @(
                'python.exe'
                'node.exe'
                'git.exe'
                'pwsh.exe'
                'code.exe'
                'cursor.exe'
            )
            ExtensionExclusions = @('.pyc', '.pyo', '.obj', '.lock')
            ProjectRelativeExclusions = @('.venv', 'node_modules', '.git', '__pycache__', 'build', 'dist')
        }
    }
    
    # Check AutoApply unless Force
    if (-not $Force -and $defenderConfig.AutoApply -eq $false) {
        Write-ScriptLog "Defender exclusions AutoApply is disabled. Use -Force to override." -Level 'Warning'
        exit 0
    }
    
    # Get current exclusions
    $current = Get-CurrentExclusions
    
    # Determine workspace root
    $workspaceRoot = if ($WorkspaceRoot) { $WorkspaceRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    Write-ScriptLog "Workspace root: $workspaceRoot"
    
    # Track statistics
    $stats = @{
        PathsAdded = 0
        PathsSkipped = 0
        ProcessesAdded = 0
        ProcessesSkipped = 0
        ExtensionsAdded = 0
        ExtensionsSkipped = 0
    }
    
    $action = if ($Remove) { "Removing" } else { "Configuring" }
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $action WINDOWS DEFENDER EXCLUSIONS" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
    
    # ========================================================================
    # Process Path Exclusions
    # ========================================================================
    Write-Host "📁 Path Exclusions:" -ForegroundColor Yellow
    
    # Standard path exclusions from config
    $pathsToProcess = @()
    
    if ($defenderConfig.PathExclusions) {
        foreach ($path in $defenderConfig.PathExclusions) {
            $expanded = Expand-ConfigPath $path
            if ($expanded -and (Test-Path $expanded -ErrorAction SilentlyContinue)) {
                $pathsToProcess += $expanded
            } elseif ($expanded) {
                Write-ScriptLog "  Path does not exist (skipping): $expanded" -Level 'Debug'
            }
        }
    }
    
    # Project-relative exclusions
    if ($defenderConfig.ProjectRelativeExclusions -and $workspaceRoot) {
        foreach ($relative in $defenderConfig.ProjectRelativeExclusions) {
            $fullPath = Join-Path $workspaceRoot $relative
            if (Test-Path $fullPath -ErrorAction SilentlyContinue) {
                $pathsToProcess += $fullPath
            }
            
            # Also check common subdirectories (e.g., AitherOS/venv, AitherZero/build)
            $subdirs = Get-ChildItem -Path $workspaceRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike '.*' }
            
            foreach ($subdir in $subdirs) {
                $subPath = Join-Path $subdir.FullName $relative
                if (Test-Path $subPath -ErrorAction SilentlyContinue) {
                    $pathsToProcess += $subPath
                }
            }
        }
    }
    
    # Always add the workspace root itself
    if ($workspaceRoot -and (Test-Path $workspaceRoot)) {
        $pathsToProcess = @($workspaceRoot) + $pathsToProcess
    }
    
    # Remove duplicates and process
    $pathsToProcess = $pathsToProcess | Select-Object -Unique
    
    foreach ($path in $pathsToProcess) {
        if ($WhatIfPreference) {
            Write-Host "  [WhatIf] Would $($action.ToLower()): $path" -ForegroundColor DarkGray
        } else {
            if ($Remove) {
                if (Remove-DefenderExclusion -Type 'Path' -Value $path -CurrentExclusions $current.Paths) {
                    $stats.PathsAdded++
                } else {
                    $stats.PathsSkipped++
                }
            } else {
                if (Add-DefenderExclusion -Type 'Path' -Value $path -CurrentExclusions $current.Paths) {
                    $stats.PathsAdded++
                } else {
                    $stats.PathsSkipped++
                }
            }
        }
    }
    
    # ========================================================================
    # Process Process Exclusions
    # ========================================================================
    Write-Host "`n⚙️  Process Exclusions:" -ForegroundColor Yellow
    
    if ($defenderConfig.ProcessExclusions) {
        foreach ($process in $defenderConfig.ProcessExclusions) {
            if ($WhatIfPreference) {
                Write-Host "  [WhatIf] Would $($action.ToLower()): $process" -ForegroundColor DarkGray
            } else {
                if ($Remove) {
                    if (Remove-DefenderExclusion -Type 'Process' -Value $process -CurrentExclusions $current.Processes) {
                        $stats.ProcessesAdded++
                    } else {
                        $stats.ProcessesSkipped++
                    }
                } else {
                    if (Add-DefenderExclusion -Type 'Process' -Value $process -CurrentExclusions $current.Processes) {
                        $stats.ProcessesAdded++
                    } else {
                        $stats.ProcessesSkipped++
                    }
                }
            }
        }
    }
    
    # ========================================================================
    # Process Extension Exclusions
    # ========================================================================
    Write-Host "`n📄 Extension Exclusions:" -ForegroundColor Yellow
    
    if ($defenderConfig.ExtensionExclusions) {
        foreach ($ext in $defenderConfig.ExtensionExclusions) {
            # Normalize extension (remove leading dot for Defender)
            $normalizedExt = $ext.TrimStart('.')
            
            if ($WhatIfPreference) {
                Write-Host "  [WhatIf] Would $($action.ToLower()): .$normalizedExt" -ForegroundColor DarkGray
            } else {
                if ($Remove) {
                    if (Remove-DefenderExclusion -Type 'Extension' -Value $normalizedExt -CurrentExclusions $current.Extensions) {
                        $stats.ExtensionsAdded++
                    } else {
                        $stats.ExtensionsSkipped++
                    }
                } else {
                    if (Add-DefenderExclusion -Type 'Extension' -Value $normalizedExt -CurrentExclusions $current.Extensions) {
                        $stats.ExtensionsAdded++
                    } else {
                        $stats.ExtensionsSkipped++
                    }
                }
            }
        }
    }
    
    # ========================================================================
    # Summary
    # ========================================================================
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $verb = if ($Remove) { "Removed" } else { "Added" }
    Write-Host "  Paths:      $($stats.PathsAdded) $verb, $($stats.PathsSkipped) skipped" -ForegroundColor White
    Write-Host "  Processes:  $($stats.ProcessesAdded) $verb, $($stats.ProcessesSkipped) skipped" -ForegroundColor White
    Write-Host "  Extensions: $($stats.ExtensionsAdded) $verb, $($stats.ExtensionsSkipped) skipped" -ForegroundColor White
    
    $totalChanges = $stats.PathsAdded + $stats.ProcessesAdded + $stats.ExtensionsAdded
    if ($totalChanges -gt 0) {
        Write-Host "`n  ✓ $totalChanges exclusion(s) $($verb.ToLower()) successfully" -ForegroundColor Green
        
        if (-not $Remove) {
            Write-Host "`n  ⚠️  Note: Excluding paths from AV scanning reduces security coverage." -ForegroundColor Yellow
            Write-Host "     Only exclude paths you trust (your own development files)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "`n  ℹ️  No changes needed - all exclusions already configured" -ForegroundColor Cyan
    }
    
    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
    
    Write-ScriptLog "Windows Defender exclusion configuration completed successfully"
    exit 0
    
} catch {
    Write-ScriptLog "Failed to configure Defender exclusions: $_" -Level 'Error'
    Write-ScriptLog $_.ScriptStackTrace -Level 'Debug'
    exit 1
}

