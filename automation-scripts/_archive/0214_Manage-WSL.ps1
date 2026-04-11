<#
.SYNOPSIS
    Manages WSL (Windows Subsystem for Linux) installation, configuration, and distro management.

.DESCRIPTION
    This script provides comprehensive WSL management capabilities:
    - Install/configure WSL2 with custom disk location
    - Install distros to custom paths (D:\WSL by default)
    - Move existing distros from C:\ to custom path
    - Clean up unused distros and reclaim disk space
    - Configure Docker Desktop to use custom WSL path
    - Set WSL global configuration (.wslconfig)

.PARAMETER Action
    The action to perform:
    - Install      : Install WSL2 and configure for custom path
    - InstallDistro: Install a specific Linux distribution
    - MoveDistro   : Move a distro from C:\ to custom path
    - List         : List all installed distros with sizes
    - Remove       : Remove a specific distro
    - Cleanup      : Remove all distros and clean C:\ drive
    - Configure    : Set up .wslconfig with optimized settings
    - Status       : Show WSL status and disk usage

.PARAMETER Distro
    The distro name for InstallDistro, MoveDistro, or Remove actions.
    Available distros: Ubuntu, Debian, kali-linux, Ubuntu-22.04, Ubuntu-24.04, etc.

.PARAMETER Path
    Custom installation path for WSL distros.
    Default: Uses Get-AitherPath -Name WslDisk (D:\WSL from config)

.PARAMETER ShowOutput
    Shows detailed output during execution.

.EXAMPLE
    # Install WSL2 with custom path configuration
    .\0214_Manage-WSL.ps1 -Action Install -ShowOutput

.EXAMPLE
    # Install Ubuntu to D:\WSL
    .\0214_Manage-WSL.ps1 -Action InstallDistro -Distro Ubuntu -ShowOutput

.EXAMPLE
    # Move existing distro from C:\ to D:\WSL
    .\0214_Manage-WSL.ps1 -Action MoveDistro -Distro docker-desktop-data -ShowOutput

.EXAMPLE
    # Remove all distros and clean up C:\ drive
    .\0214_Manage-WSL.ps1 -Action Cleanup -ShowOutput

.EXAMPLE
    # Show current WSL status and disk usage
    .\0214_Manage-WSL.ps1 -Action Status -ShowOutput

.NOTES
    Script Number: 0214
    Category: Dev Tools / WSL Management
    Requires: Administrator privileges for Install action
    Author: AitherZero Automation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'InstallDistro', 'MoveDistro', 'List', 'Remove', 'Cleanup', 'Configure', 'Status')]
    [string]$Action,

    [Parameter()]
    [string]$Distro,

    [Parameter()]
    [string]$Path,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize AitherZero environment
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptRoot\_init.ps1"

#region Helper Functions

function Get-WslPath {
    <#
    .SYNOPSIS
        Gets the configured WSL installation path.
    #>
    if ($Path) { return $Path }
    
    # Try to get from AitherZero config
    try {
        $configPath = Get-AitherPath -Name WslDisk -ErrorAction SilentlyContinue
        if ($configPath) { return $configPath }
    } catch {}
    
    # Fallback to D:\WSL
    return 'D:\WSL'
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WslDistros {
    <#
    .SYNOPSIS
        Gets list of installed WSL distributions with details.
    #>
    $distros = @()
    
    $wslOutput = wsl -l -v 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $distros
    }
    
    $lines = $wslOutput -split "`n" | Where-Object { $_ -match '\S' }
    
    foreach ($line in $lines) {
        # Skip header line
        if ($line -match 'NAME\s+STATE\s+VERSION') { continue }
        
        # Parse distro line
        if ($line -match '^\*?\s*(\S+)\s+(Running|Stopped)\s+(\d+)') {
            $distros += [PSCustomObject]@{
                Name = $Matches[1]
                State = $Matches[2]
                Version = $Matches[3]
                IsDefault = $line.StartsWith('*')
            }
        }
    }
    
    return $distros
}

function Get-WslDiskUsage {
    <#
    .SYNOPSIS
        Gets WSL disk usage from C:\ drive locations.
    #>
    $locations = @(
        "$env:LOCALAPPDATA\Docker\wsl",
        "$env:LOCALAPPDATA\wsl",
        "$env:LOCALAPPDATA\Packages\*wsl*",
        "$env:LOCALAPPDATA\Packages\*Linux*",
        "$env:LOCALAPPDATA\Packages\*Ubuntu*",
        "$env:LOCALAPPDATA\Packages\*Debian*"
    )
    
    $usage = @()
    
    foreach ($loc in $locations) {
        $items = Get-ChildItem -Path $loc -Recurse -Force -ErrorAction SilentlyContinue
        if ($items) {
            $size = ($items | Measure-Object Length -Sum).Sum
            $vhdx = $items | Where-Object { $_.Extension -eq '.vhdx' }
            
            foreach ($v in $vhdx) {
                $usage += [PSCustomObject]@{
                    Path = $v.FullName
                    SizeGB = [math]::Round($v.Length / 1GB, 2)
                    Type = 'VHDX'
                }
            }
        }
    }
    
    return $usage
}

function Install-WslFeature {
    <#
    .SYNOPSIS
        Installs WSL Windows feature.
    #>
    if (-not (Test-IsAdmin)) {
        Write-AitherError "Administrator privileges required to install WSL"
        return $false
    }
    
    Write-ScriptLog "Installing WSL Windows feature..."
    
    # Enable WSL feature
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    if ($wslFeature.State -ne 'Enabled') {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -ErrorAction Stop
        Write-ScriptLog "WSL feature enabled"
    }
    
    # Enable Virtual Machine Platform
    $vmFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
    if ($vmFeature.State -ne 'Enabled') {
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction Stop
        Write-ScriptLog "Virtual Machine Platform enabled"
    }
    
    # Set WSL2 as default
    wsl --set-default-version 2 2>&1 | Out-Null
    
    return $true
}

function Set-WslConfig {
    <#
    .SYNOPSIS
        Creates optimized .wslconfig file.
    #>
    param(
        [string]$WslPath
    )
    
    $wslConfigPath = "$env:USERPROFILE\.wslconfig"
    
    $config = @"
# WSL2 Configuration - Generated by AitherZero
# See: https://learn.microsoft.com/en-us/windows/wsl/wsl-config

[wsl2]
# Memory limit (adjust based on your RAM)
memory=16GB

# Processor count
processors=8

# Swap file size
swap=8GB

# Swap file location on custom drive
swapfile=$WslPath\swap.vhdx

# Disable page reporting for better performance
pageReporting=false

# Enable localhost forwarding
localhostForwarding=true

# Nested virtualization for Docker
nestedVirtualization=true

# Debug console (disable in production)
debugConsole=false

[experimental]
# Auto memory reclaim
autoMemoryReclaim=gradual

# Sparse VHD - saves disk space
sparseVhd=true

# Auto proxy (for corporate networks)
autoProxy=true
"@

    $config | Out-File -FilePath $wslConfigPath -Encoding utf8 -Force
    Write-ScriptLog "Created .wslconfig at $wslConfigPath"
    
    return $wslConfigPath
}

function Install-WslDistro {
    <#
    .SYNOPSIS
        Installs a WSL distribution to custom path.
    #>
    param(
        [string]$DistroName,
        [string]$InstallPath
    )
    
    $distroPath = Join-Path $InstallPath $DistroName
    
    # Create directory
    if (-not (Test-Path $distroPath)) {
        New-Item -Path $distroPath -ItemType Directory -Force | Out-Null
    }
    
    Write-ScriptLog "Installing $DistroName to $distroPath..."
    
    # Download and install the distro
    # Method 1: Use wsl --install with --location (Windows 11+)
    $result = wsl --install -d $DistroName --location $distroPath 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        # Method 2: Install to default, then move
        Write-ScriptLog "Direct install failed, trying install-then-move method..."
        
        wsl --install -d $DistroName --no-launch 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            # Wait for install
            Start-Sleep -Seconds 5
            
            # Now move it
            Move-WslDistro -DistroName $DistroName -TargetPath $InstallPath
        } else {
            Write-AitherError "Failed to install $DistroName : $result"
            return $false
        }
    }
    
    Write-ScriptLog "Successfully installed $DistroName"
    return $true
}

function Move-WslDistro {
    <#
    .SYNOPSIS
        Moves a WSL distro from C:\ to custom path.
    #>
    param(
        [string]$DistroName,
        [string]$TargetPath
    )
    
    $distroPath = Join-Path $TargetPath $DistroName
    $tarPath = Join-Path $TargetPath "$DistroName.tar"
    
    # Create target directory
    if (-not (Test-Path $TargetPath)) {
        New-Item -Path $TargetPath -ItemType Directory -Force | Out-Null
    }
    
    # Shutdown WSL
    Write-ScriptLog "Shutting down WSL..."
    wsl --shutdown
    Start-Sleep -Seconds 3
    
    # Export distro
    Write-ScriptLog "Exporting $DistroName (this may take several minutes for large distros)..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    
    wsl --export $DistroName $tarPath
    
    if ($LASTEXITCODE -ne 0) {
        Write-AitherError "Failed to export $DistroName"
        return $false
    }
    
    $sw.Stop()
    Write-ScriptLog "Export completed in $([math]::Round($sw.Elapsed.TotalMinutes, 1)) minutes"
    
    # Unregister old distro
    Write-ScriptLog "Unregistering old distro location..."
    wsl --unregister $DistroName
    
    if ($LASTEXITCODE -ne 0) {
        Write-AitherError "Failed to unregister $DistroName"
        return $false
    }
    
    # Import to new location
    Write-ScriptLog "Importing $DistroName to $distroPath..."
    
    if (-not (Test-Path $distroPath)) {
        New-Item -Path $distroPath -ItemType Directory -Force | Out-Null
    }
    
    wsl --import $DistroName $distroPath $tarPath
    
    if ($LASTEXITCODE -ne 0) {
        Write-AitherError "Failed to import $DistroName to new location"
        return $false
    }
    
    # Clean up tar file
    Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
    
    Write-ScriptLog "Successfully moved $DistroName to $distroPath"
    return $true
}

function Remove-WslDistro {
    <#
    .SYNOPSIS
        Removes a WSL distro.
    #>
    param(
        [string]$DistroName,
        [switch]$Force
    )
    
    if (-not $Force) {
        $confirm = Read-Host "Are you sure you want to remove '$DistroName'? This cannot be undone. (y/N)"
        if ($confirm -ne 'y') {
            Write-ScriptLog "Cancelled"
            return $false
        }
    }
    
    Write-ScriptLog "Removing $DistroName..."
    wsl --unregister $DistroName
    
    if ($LASTEXITCODE -eq 0) {
        Write-ScriptLog "Successfully removed $DistroName"
        return $true
    } else {
        Write-AitherError "Failed to remove $DistroName"
        return $false
    }
}

function Invoke-WslCleanup {
    <#
    .SYNOPSIS
        Removes all WSL distros and cleans up C:\ drive.
    #>
    param(
        [switch]$Force
    )
    
    if (-not $Force) {
        $confirm = Read-Host "This will remove ALL WSL distros and clean up disk space. Continue? (y/N)"
        if ($confirm -ne 'y') {
            Write-ScriptLog "Cancelled"
            return $false
        }
    }
    
    # Shutdown WSL first
    Write-ScriptLog "Shutting down WSL..."
    wsl --shutdown 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    
    # Get all distros
    $distros = Get-WslDistros
    
    foreach ($distro in $distros) {
        Write-ScriptLog "Removing $($distro.Name)..."
        wsl --unregister $distro.Name 2>&1 | Out-Null
    }
    
    # Clean up leftover files
    $cleanupPaths = @(
        "$env:LOCALAPPDATA\Docker\wsl",
        "$env:LOCALAPPDATA\wsl"
    )
    
    $freedSpace = 0
    
    foreach ($path in $cleanupPaths) {
        if (Test-Path $path) {
            $size = (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $freedSpace += $size
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-ScriptLog "Cleaned up $path"
        }
    }
    
    $freedGB = [math]::Round($freedSpace / 1GB, 2)
    Write-ScriptLog "Cleanup complete. Freed approximately $freedGB GB"
    
    return $true
}

function Show-WslStatus {
    <#
    .SYNOPSIS
        Shows comprehensive WSL status.
    #>
    
    Write-Host "`n=== WSL Status ===" -ForegroundColor Cyan
    
    # Check if WSL is installed
    $wslVersion = wsl --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nWSL Version Info:" -ForegroundColor Yellow
        Write-Host $wslVersion
    } else {
        Write-Host "WSL is not installed or not working properly" -ForegroundColor Red
        return
    }
    
    # List distros
    Write-Host "`nInstalled Distributions:" -ForegroundColor Yellow
    $distros = Get-WslDistros
    
    if ($distros.Count -eq 0) {
        Write-Host "  No distributions installed" -ForegroundColor Gray
    } else {
        foreach ($d in $distros) {
            $default = if ($d.IsDefault) { " (default)" } else { "" }
            $stateColor = if ($d.State -eq 'Running') { 'Green' } else { 'Gray' }
            Write-Host "  - $($d.Name)$default [$($d.State)]" -ForegroundColor $stateColor
        }
    }
    
    # Disk usage on C:\
    Write-Host "`nDisk Usage (C:\ drive):" -ForegroundColor Yellow
    $usage = Get-WslDiskUsage
    
    if ($usage.Count -eq 0) {
        Write-Host "  No WSL disk files found on C:\" -ForegroundColor Green
    } else {
        $totalSize = 0
        foreach ($u in $usage) {
            Write-Host "  - $($u.Path): $($u.SizeGB) GB" -ForegroundColor $(if ($u.SizeGB -gt 10) { 'Red' } else { 'Gray' })
            $totalSize += $u.SizeGB
        }
        Write-Host "  Total: $totalSize GB" -ForegroundColor $(if ($totalSize -gt 20) { 'Red' } else { 'Yellow' })
    }
    
    # Custom WSL path
    $wslPath = Get-WslPath
    Write-Host "`nConfigured WSL Path:" -ForegroundColor Yellow
    Write-Host "  $wslPath" -ForegroundColor Cyan
    
    if (Test-Path $wslPath) {
        $customSize = (Get-ChildItem $wslPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB
        Write-Host "  Size: $([math]::Round($customSize, 2)) GB" -ForegroundColor Gray
    } else {
        Write-Host "  (Directory does not exist yet)" -ForegroundColor Gray
    }
    
    # .wslconfig status
    $wslConfigPath = "$env:USERPROFILE\.wslconfig"
    Write-Host "`n.wslconfig:" -ForegroundColor Yellow
    if (Test-Path $wslConfigPath) {
        Write-Host "  $wslConfigPath (exists)" -ForegroundColor Green
    } else {
        Write-Host "  Not configured (run -Action Configure to create)" -ForegroundColor Gray
    }
    
    Write-Host ""
}

#endregion

#region Main Execution

try {
    $wslPath = Get-WslPath
    
    switch ($Action) {
        'Install' {
            Write-ScriptLog "Installing WSL2..."
            
            # Check admin
            if (-not (Test-IsAdmin)) {
                Write-AitherWarning "Some operations require administrator privileges"
            }
            
            # Create WSL directory
            if (-not (Test-Path $wslPath)) {
                New-Item -Path $wslPath -ItemType Directory -Force | Out-Null
                Write-ScriptLog "Created WSL directory: $wslPath"
            }
            
            # Install WSL feature
            Install-WslFeature
            
            # Configure .wslconfig
            Set-WslConfig -WslPath $wslPath
            
            Write-AitherSuccess "WSL2 installation complete. You may need to restart your computer."
            Write-ScriptLog "Use -Action InstallDistro -Distro Ubuntu to install a Linux distribution"
        }
        
        'InstallDistro' {
            if (-not $Distro) {
                Write-Host "`nAvailable distributions:" -ForegroundColor Yellow
                wsl --list --online
                Write-Host "`nUsage: -Action InstallDistro -Distro <name>" -ForegroundColor Cyan
                return
            }
            
            Install-WslDistro -DistroName $Distro -InstallPath $wslPath
        }
        
        'MoveDistro' {
            if (-not $Distro) {
                $distros = Get-WslDistros
                Write-Host "`nInstalled distributions:" -ForegroundColor Yellow
                $distros | Format-Table Name, State, Version
                Write-Host "Usage: -Action MoveDistro -Distro <name>" -ForegroundColor Cyan
                return
            }
            
            Move-WslDistro -DistroName $Distro -TargetPath $wslPath
        }
        
        'List' {
            $distros = Get-WslDistros
            if ($distros.Count -eq 0) {
                Write-Host "No WSL distributions installed" -ForegroundColor Yellow
            } else {
                $distros | Format-Table Name, State, Version, @{N='Default';E={if($_.IsDefault){'*'}else{' '}}}
            }
        }
        
        'Remove' {
            if (-not $Distro) {
                $distros = Get-WslDistros
                Write-Host "`nInstalled distributions:" -ForegroundColor Yellow
                $distros | Format-Table Name, State
                Write-Host "Usage: -Action Remove -Distro <name> [-Force]" -ForegroundColor Cyan
                return
            }
            
            Remove-WslDistro -DistroName $Distro -Force:$Force
        }
        
        'Cleanup' {
            Invoke-WslCleanup -Force:$Force
        }
        
        'Configure' {
            Set-WslConfig -WslPath $wslPath
            Write-AitherSuccess ".wslconfig created with optimized settings"
            Write-ScriptLog "Restart WSL for changes to take effect: wsl --shutdown"
        }
        
        'Status' {
            Show-WslStatus
        }
    }
    
} catch {
    Write-AitherError "WSL management failed: $_"
    exit 1
}

#endregion

