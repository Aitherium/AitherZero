<#
.SYNOPSIS
    Installs Servy for Windows service management.

.DESCRIPTION
    Servy lets you run any app as a native Windows service with full control over
    working directory, startup type, process priority, logging, health checks,
    environment variables, dependencies, pre-launch and post-launch hooks.
    
    It's a full-featured alternative to NSSM, WinSW, and FireDaemon Pro.
    
    AitherOS uses Servy to install Python services as proper Windows services
    via Genesis bootloader.

.PARAMETER Force
    Reinstall even if already present.

.PARAMETER ShowOutput
    Show verbose output during installation.

.EXAMPLE
    .\0226_Install-Servy.ps1
    # Installs Servy via winget

.EXAMPLE
    .\0226_Install-Servy.ps1 -Force
    # Force reinstall Servy

.NOTES
    Stage: Development
    Order: 0226
    Dependencies: 0200
    Tags: servy, services, windows, infrastructure
    AllowParallel: false
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Force,
    
    [Parameter(Mandatory = $false)]
    [switch]$ShowOutput
)

# Initialize script environment
. "$PSScriptRoot\_init.ps1"

$ErrorActionPreference = 'Stop'

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $ShowOutput -and $Level -eq 'INFO') { return }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARNING' { 'Yellow' }
        'SUCCESS' { 'Green' }
        default { 'White' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-ServyInstalled {
    <#
    .SYNOPSIS
        Check if Servy is installed and accessible.
    #>
    # Check if servy-cli is in PATH
    $servyCli = Get-Command servy-cli -ErrorAction SilentlyContinue
    if ($servyCli) {
        return $servyCli.Source
    }
    
    # Check common installation location
    $defaultPath = "C:\Program Files\Servy\servy-cli.exe"
    if (Test-Path $defaultPath) {
        return $defaultPath
    }
    
    return $null
}

function Get-ServyVersion {
    param([string]$ServyPath)
    try {
        $output = & $ServyPath version 2>&1
        # Extract version from output like "Servy.CLI 4.2.0+..."
        if ($output -match 'Servy\.CLI\s+(\d+\.\d+\.\d+)') {
            return $Matches[1]
        }
        return $output
    }
    catch {
        return "Unknown"
    }
}

function Install-Servy {
    <#
    .SYNOPSIS
        Install Servy using winget, chocolatey, or scoop.
    #>
    Write-ScriptLog "Installing Servy (Windows Service Manager)..." -Level SUCCESS
    
    # Try winget first (preferred)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-ScriptLog "Installing via winget..."
        try {
            $result = & winget install servy --accept-package-agreements --accept-source-agreements 2>&1
            if ($LASTEXITCODE -eq 0 -or $result -match "successfully installed|already installed") {
                Write-ScriptLog "Servy installed via winget" -Level SUCCESS
                
                # Refresh PATH - Servy adds itself to PATH on install
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                
                # Give Windows a moment to update PATH
                Start-Sleep -Seconds 2
                
                return Test-ServyInstalled
            }
        }
        catch {
            Write-ScriptLog "Winget installation failed: $_" -Level WARNING
        }
    }
    
    # Try Chocolatey
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-ScriptLog "Installing via Chocolatey..."
        try {
            $result = & choco install -y servy 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-ScriptLog "Servy installed via Chocolatey" -Level SUCCESS
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                Start-Sleep -Seconds 2
                return Test-ServyInstalled
            }
        }
        catch {
            Write-ScriptLog "Chocolatey installation failed: $_" -Level WARNING
        }
    }
    
    # Try Scoop
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-ScriptLog "Installing via Scoop..."
        try {
            & scoop bucket add extras 2>$null
            $result = & scoop install servy 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-ScriptLog "Servy installed via Scoop" -Level SUCCESS
                return Test-ServyInstalled
            }
        }
        catch {
            Write-ScriptLog "Scoop installation failed: $_" -Level WARNING
        }
    }
    
    # No package manager available
    Write-ScriptLog "No package manager available (winget, choco, scoop)." -Level ERROR
    Write-ScriptLog "Please install Servy manually from: https://github.com/aelassas/servy/releases" -Level ERROR
    return $null
}

# ============================================================================
# MAIN
# ============================================================================

if ($ShowOutput) {
    Write-ScriptLog "=== Servy Installation Script ===" -Level SUCCESS
    Write-ScriptLog "Servy is used by AitherOS Genesis to manage Windows services."
}

# Check if already installed
$existingPath = Test-ServyInstalled

if ($existingPath -and -not $Force) {
    $version = Get-ServyVersion -ServyPath $existingPath
    if ($ShowOutput) {
        Write-ScriptLog "Servy is already installed at: $existingPath" -Level SUCCESS
        Write-ScriptLog "Version: $version"
    }
    
    return @{
        Success = $true
        Path = $existingPath
        Version = $version
        AlreadyInstalled = $true
    }
}

# Check for admin rights (needed for service installation)
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-ScriptLog "Administrator privileges required for Servy installation." -Level WARNING
    Write-ScriptLog "Please run as Administrator." -Level WARNING
}

# Install Servy
try {
    $servyPath = Install-Servy
    
    if ($servyPath) {
        $version = Get-ServyVersion -ServyPath $servyPath
        if ($ShowOutput) {
            Write-ScriptLog "=== Installation Complete ===" -Level SUCCESS
            Write-ScriptLog "Servy Path: $servyPath"
            Write-ScriptLog "Version: $version"
            Write-ScriptLog ""
            Write-ScriptLog "Usage examples:"
            Write-ScriptLog "  servy-cli install --name=MyService --path=C:\app.exe"
            Write-ScriptLog "  servy-cli start --name=MyService"
            Write-ScriptLog "  servy-cli stop --name=MyService"
            Write-ScriptLog "  servy-cli uninstall --name=MyService"
        }
        
        return @{
            Success = $true
            Path = $servyPath
            Version = $version
            AlreadyInstalled = $false
        }
    }
    else {
        throw "Servy installation completed but executable not found"
    }
}
catch {
    Write-ScriptLog "Failed to install Servy: $_" -Level ERROR
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
