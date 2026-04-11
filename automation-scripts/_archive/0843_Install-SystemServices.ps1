#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Installs AitherOS services as system services across Windows, Linux, and macOS.

.DESCRIPTION
    This script provides cross-platform service installation for AitherOS.
    It automatically detects the operating system and uses the appropriate
    service manager:
    
    - Windows: NSSM or Servy (Windows Services)
    - Linux: systemd
    - macOS: launchd
    
    Services are configured to:
    - Start automatically on system boot
    - Restart on failure
    - Respect dependency chains from services.yaml
    
.PARAMETER Action
    Action to perform: Install, Uninstall, Status, InstallGenesis
    
.PARAMETER Group
    Service group to install: minimal, core, full, gpu, etc.
    Default: core
    
.PARAMETER ServiceName
    Specific service name to manage (optional)
    
.PARAMETER UserMode
    For Linux/macOS: Install as user services instead of system services
    
.PARAMETER Enable
    Enable services to start on boot (default: true)
    
.PARAMETER Start
    Start services immediately after installation (default: false)
    
.PARAMETER ShowOutput
    Show detailed output
    
.EXAMPLE
    .\0843_Install-SystemServices.ps1 -Action Install -Group core
    Install core services on the current OS
    
.EXAMPLE
    .\0843_Install-SystemServices.ps1 -Action InstallGenesis -Start
    Install and start Genesis as a system service
    
.EXAMPLE
    .\0843_Install-SystemServices.ps1 -Action Status
    Show status of all installed services
    
.NOTES
    Order: 0843
    Category: AitherOS Operations
    Version: 1.0.0
    
    Cross-Platform Service Management:
    - Windows: Uses Servy (winget install servy) or NSSM
    - Linux: Uses systemd (requires systemctl)
    - macOS: Uses launchd (uses launchctl)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Install", "Uninstall", "Status", "InstallGenesis", "Start", "Stop", "Restart")]
    [string]$Action = "Status",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("minimal", "core", "full", "gpu", "mcp", "mesh", "agents", "brain", "cognition", "homeostasis", "dlp", "storage", "headless", "autonomy")]
    [string]$Group = "core",
    
    [Parameter(Mandatory = $false)]
    [string]$ServiceName,
    
    [Parameter(Mandatory = $false)]
    [switch]$UserMode,
    
    [Parameter(Mandatory = $false)]
    [switch]$Enable = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$Start,
    
    [Parameter(Mandatory = $false)]
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'

# Get project root
$ProjectRoot = $env:AITHERZERO_ROOT
if (-not $ProjectRoot) {
    $ProjectRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
}

$AitherOSDir = Join-Path $ProjectRoot "AitherOS"
$AitherNodeDir = Join-Path $AitherOSDir "AitherNode"
$GenesisDir = Join-Path $AitherOSDir "AitherGenesis"

# Check if Python venv exists
$VenvPython = if ($IsWindows) {
    Join-Path $AitherOSDir ".venv/Scripts/python.exe"
} else {
    Join-Path $AitherOSDir ".venv/bin/python"
}

if (-not (Test-Path $VenvPython)) {
    Write-Error "Python venv not found at $VenvPython. Run genesis-bootstrap playbook first."
    exit 1
}

function Write-ServiceLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'SUCCESS' { 'Green' }
        'WARNING' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'White' }
    }
    
    Write-Host "[$timestamp] $Message" -ForegroundColor $color
}

function Detect-ServiceManager {
    """Detect which service manager is available on this system."""
    
    if ($IsWindows) {
        # Check for Servy first (preferred)
        $servy = Get-Command servy -ErrorAction SilentlyContinue
        if ($servy) {
            return @{ Manager = "Servy"; Available = $true }
        }
        
        # Check for NSSM
        $nssm = Get-Command nssm -ErrorAction SilentlyContinue
        if ($nssm) {
            return @{ Manager = "NSSM"; Available = $true }
        }
        
        Write-ServiceLog "No service manager found. Install Servy: winget install servy" -Level WARNING
        return @{ Manager = "None"; Available = $false }
    }
    elseif ($IsLinux) {
        # Check for systemd
        $systemctl = Get-Command systemctl -ErrorAction SilentlyContinue
        if ($systemctl) {
            return @{ Manager = "systemd"; Available = $true }
        }
        
        Write-ServiceLog "systemd not found" -Level WARNING
        return @{ Manager = "None"; Available = $false }
    }
    elseif ($IsMacOS) {
        # Check for launchd
        $launchctl = Get-Command launchctl -ErrorAction SilentlyContinue
        if ($launchctl) {
            return @{ Manager = "launchd"; Available = $true }
        }
        
        Write-ServiceLog "launchd not found" -Level WARNING
        return @{ Manager = "None"; Available = $false }
    }
    
    return @{ Manager = "Unknown"; Available = $false }
}

function Invoke-PythonServiceManager {
    param(
        [string]$Action,
        [string]$ServiceName = "",
        [string]$Group = "core",
        [bool]$UserMode = $false,
        [bool]$Enable = $true,
        [bool]$Start = $false
    )
    
    # Build Python command to call the service manager
    $pythonScript = @"
import sys
import os
sys.path.insert(0, '$AitherOSDir')
sys.path.insert(0, '$AitherNodeDir')

from AitherGenesis.bootstrap import SystemdServiceManager, LaunchdServiceManager, WindowsServiceManager
from AitherGenesis.bootstrap import get_services_from_yaml
import logging

logging.basicConfig(level=logging.INFO)

def main():
    action = '$Action'.lower()
    service_name = '$ServiceName'
    group = '$Group'
    user_mode = $($UserMode.ToString().ToLower())
    enable = $($Enable.ToString().ToLower())
    start = $($Start.ToString().ToLower())
    
    # Detect platform and create appropriate manager
    import sys
    if sys.platform == 'win32':
        manager = WindowsServiceManager()
    elif sys.platform == 'darwin':
        manager = LaunchdServiceManager(user_mode=user_mode)
    elif sys.platform == 'linux':
        manager = SystemdServiceManager(user_mode=user_mode)
    else:
        print(f"Unsupported platform: {sys.platform}")
        return 1
    
    if not manager.is_available:
        print(f"Service manager not available on this platform")
        return 1
    
    # Handle actions
    if action == 'installgenesis':
        if sys.platform == 'win32':
            from AitherGenesis.bootstrap import ensure_genesis_installed_as_service
            success = ensure_genesis_installed_as_service(force_uac=False)
        else:
            success = manager.install_genesis_service(load=start, enable=enable)
        return 0 if success else 1
    
    if action == 'status':
        services = manager.list_installed_services()
        if not services:
            print("No AitherOS services installed")
            return 0
        
        print(f"\nInstalled AitherOS Services ({len(services)}):")
        print("-" * 60)
        for svc in services:
            status = manager.get_service_status(svc)
            print(f"  {svc:30} {status}")
        return 0
    
    # For other actions, need services list
    services_config = get_services_from_yaml(group=group)
    
    if service_name:
        # Filter to specific service
        services_config = {k: v for k, v in services_config.items() if k == service_name}
        if not services_config:
            print(f"Service '{service_name}' not found in group '{group}'")
            return 1
    
    if action == 'install':
        success_count = 0
        for name, svc_info in services_config.items():
            print(f"\nInstalling {name}...")
            
            if sys.platform == 'win32':
                success = manager.install_service(svc_info, enable=enable, start=start)
            elif sys.platform == 'darwin':
                success = manager.install_service(svc_info, load=start)
            else:  # Linux
                success = manager.install_service(svc_info, enable=enable, start=start)
            
            if success:
                success_count += 1
                print(f"  ✓ {name} installed")
            else:
                print(f"  ✗ {name} failed")
        
        print(f"\n{success_count}/{len(services_config)} services installed successfully")
        return 0 if success_count > 0 else 1
    
    elif action == 'uninstall':
        for name in services_config.keys():
            print(f"Uninstalling {name}...")
            manager.uninstall_service(name)
        return 0
    
    elif action == 'start':
        for name in services_config.keys():
            print(f"Starting {name}...")
            manager.start_service(name)
        return 0
    
    elif action == 'stop':
        for name in services_config.keys():
            print(f"Stopping {name}...")
            manager.stop_service(name)
        return 0
    
    elif action == 'restart':
        for name in services_config.keys():
            print(f"Restarting {name}...")
            manager.restart_service(name)
        return 0
    
    return 0

if __name__ == '__main__':
    sys.exit(main())
"@
    
    # Write to temp file and execute
    $tempScript = [System.IO.Path]::GetTempFileName() + ".py"
    $pythonScript | Out-File -FilePath $tempScript -Encoding UTF8
    
    try {
        $result = & $VenvPython $tempScript
        $exitCode = $LASTEXITCODE
        
        if ($ShowOutput -and $result) {
            Write-Output $result
        }
        
        return $exitCode -eq 0
    }
    finally {
        Remove-Item $tempScript -ErrorAction SilentlyContinue
    }
}

# Main execution
Write-ServiceLog "🔧 Cross-Platform Service Manager" -Level INFO
Write-ServiceLog "   Platform: $($PSVersionTable.Platform)" -Level INFO

$serviceManager = Detect-ServiceManager

if (-not $serviceManager.Available) {
    Write-ServiceLog "No service manager available on this platform" -Level ERROR
    
    if ($IsWindows) {
        Write-ServiceLog "Install Servy: winget install servy" -Level INFO
        Write-ServiceLog "Or install NSSM: winget install nssm" -Level INFO
    }
    
    exit 1
}

Write-ServiceLog "   Service Manager: $($serviceManager.Manager)" -Level SUCCESS

# Execute action
try {
    $success = Invoke-PythonServiceManager `
        -Action $Action `
        -ServiceName $ServiceName `
        -Group $Group `
        -UserMode $UserMode.IsPresent `
        -Enable $Enable.IsPresent `
        -Start $Start.IsPresent
    
    if ($success) {
        Write-ServiceLog "✅ Operation completed successfully" -Level SUCCESS
        
        if ($Action -eq "InstallGenesis") {
            Write-ServiceLog "" -Level INFO
            Write-ServiceLog "Genesis installed as system service!" -Level SUCCESS
            
            if ($IsWindows) {
                Write-ServiceLog "   Status: Get-Service AitherGenesis" -Level INFO
                Write-ServiceLog "   Start: Start-Service AitherGenesis" -Level INFO
                Write-ServiceLog "   Stop: Stop-Service AitherGenesis" -Level INFO
            }
            elseif ($IsLinux) {
                Write-ServiceLog "   Status: systemctl $(if ($UserMode) { '--user ' })status aither-genesis" -Level INFO
                Write-ServiceLog "   Start: systemctl $(if ($UserMode) { '--user ' })start aither-genesis" -Level INFO
                Write-ServiceLog "   Stop: systemctl $(if ($UserMode) { '--user ' })stop aither-genesis" -Level INFO
                Write-ServiceLog "   Logs: journalctl $(if ($UserMode) { '--user ' })-u aither-genesis -f" -Level INFO
            }
            elseif ($IsMacOS) {
                Write-ServiceLog "   Status: launchctl list com.aither.genesis" -Level INFO
                Write-ServiceLog "   Start: launchctl start com.aither.genesis" -Level INFO
                Write-ServiceLog "   Stop: launchctl stop com.aither.genesis" -Level INFO
            }
        }
        
        exit 0
    }
    else {
        Write-ServiceLog "⚠️ Operation completed with errors" -Level WARNING
        exit 1
    }
}
catch {
    Write-ServiceLog "❌ Operation failed: $_" -Level ERROR
    Write-ServiceLog $_.ScriptStackTrace -Level ERROR
    exit 1
}
