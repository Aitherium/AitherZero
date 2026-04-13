#Requires -Version 5.1
<#
.SYNOPSIS
    Installs or updates PowerShell 7+ on the system.

.DESCRIPTION
    Downloads and installs the latest PowerShell 7 release for the current platform.
    Supports Windows, Linux (Debian/Ubuntu, RHEL/CentOS, Arch), and macOS.
    
    On Windows, uses the MSI installer with silent installation.
    On Linux, uses the appropriate package manager.
    On macOS, uses Homebrew.

.PARAMETER Version
    Specific version to install. Default: "latest"

.PARAMETER Force
    Force reinstallation even if already installed.

.EXAMPLE
    .\0002_Install-PowerShell7.ps1 -Verbose
    
.EXAMPLE
    .\0002_Install-PowerShell7.ps1 -Version "7.4.1" -Force

.NOTES
    Category: bootstrap
    Dependencies: None (can run on PowerShell 5.1)
    Platform: Windows, Linux, macOS
    Exit Codes:
        0 - Success
        1 - Installation failed
        200 - Success, restart terminal required
#>

[CmdletBinding()]
param(
    [string]$Version = "latest",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-LatestPowerShellVersion {
    try {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -UseBasicParsing
        return $releases.tag_name -replace '^v', ''
    } catch {
        Write-Warning "Could not fetch latest version, using fallback"
        return "7.4.1"
    }
}

function Get-CurrentPowerShellVersion {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return $PSVersionTable.PSVersion.ToString()
    }
    
    # Check if pwsh is installed but we're running in Windows PowerShell
    $pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshPath) {
        try {
            $version = & pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
            return $version
        } catch { }
    }
    
    return $null
}

function Install-PowerShellWindows {
    param([string]$TargetVersion)
    
    Write-Host "Installing PowerShell $TargetVersion on Windows..." -ForegroundColor Cyan
    
    # Determine architecture
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    
    # Download MSI
    $msiUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$TargetVersion/PowerShell-$TargetVersion-win-$arch.msi"
    $msiPath = Join-Path $env:TEMP "PowerShell-$TargetVersion-win-$arch.msi"
    
    Write-Host "Downloading from: $msiUrl" -ForegroundColor Gray
    
    try {
        # Use BITS for download if available, otherwise use Invoke-WebRequest
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $msiUrl -Destination $msiPath -Description "Downloading PowerShell $TargetVersion"
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
        }
    } catch {
        Write-Error "Failed to download PowerShell installer: $_"
        return $false
    }
    
    # Install silently
    Write-Host "Installing..." -ForegroundColor Gray
    
    $msiArgs = @(
        "/i"
        "`"$msiPath`""
        "/quiet"
        "/norestart"
        "ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1"
        "ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1"
        "ENABLE_PSREMOTING=0"
        "REGISTER_MANIFEST=1"
        "USE_MU=1"
        "ENABLE_MU=1"
    )
    
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    
    # Cleanup
    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
    
    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Host "PowerShell $TargetVersion installed successfully!" -ForegroundColor Green
        return $true
    } else {
        Write-Error "MSI installation failed with exit code: $($process.ExitCode)"
        return $false
    }
}

function Install-PowerShellLinux {
    param([string]$TargetVersion)
    
    Write-Host "Installing PowerShell $TargetVersion on Linux..." -ForegroundColor Cyan
    
    # Detect distribution
    $distro = ""
    if (Test-Path /etc/os-release) {
        $osRelease = Get-Content /etc/os-release | ConvertFrom-StringData
        $distro = $osRelease.ID -replace '"', ''
    }
    
    switch -Wildcard ($distro) {
        "ubuntu*" {
            Write-Host "Detected Ubuntu, using apt..." -ForegroundColor Gray
            
            # Add Microsoft repository
            & sudo apt-get update
            & sudo apt-get install -y wget apt-transport-https software-properties-common
            
            $ubuntuVersion = $osRelease.VERSION_ID -replace '"', ''
            & wget -q "https://packages.microsoft.com/config/ubuntu/$ubuntuVersion/packages-microsoft-prod.deb"
            & sudo dpkg -i packages-microsoft-prod.deb
            Remove-Item packages-microsoft-prod.deb -Force -ErrorAction SilentlyContinue
            
            & sudo apt-get update
            & sudo apt-get install -y powershell
        }
        "debian*" {
            Write-Host "Detected Debian, using apt..." -ForegroundColor Gray
            
            & sudo apt-get update
            & sudo apt-get install -y wget
            
            $debianVersion = $osRelease.VERSION_ID -replace '"', ''
            & wget -q "https://packages.microsoft.com/config/debian/$debianVersion/packages-microsoft-prod.deb"
            & sudo dpkg -i packages-microsoft-prod.deb
            Remove-Item packages-microsoft-prod.deb -Force -ErrorAction SilentlyContinue
            
            & sudo apt-get update
            & sudo apt-get install -y powershell
        }
        { $_ -in "rhel*", "centos*", "fedora*" } {
            Write-Host "Detected RHEL/CentOS/Fedora, using dnf/yum..." -ForegroundColor Gray
            
            & sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
            & curl https://packages.microsoft.com/config/rhel/7/prod.repo | sudo tee /etc/yum.repos.d/microsoft.repo
            
            if (Get-Command dnf -ErrorAction SilentlyContinue) {
                & sudo dnf install -y powershell
            } else {
                & sudo yum install -y powershell
            }
        }
        "arch*" {
            Write-Host "Detected Arch Linux, using pacman..." -ForegroundColor Gray
            & sudo pacman -S --noconfirm powershell-bin
        }
        default {
            Write-Host "Unknown distribution, attempting manual installation..." -ForegroundColor Yellow
            
            # Download tar.gz and install manually
            $arch = if ((uname -m) -eq "x86_64") { "x64" } elseif ((uname -m) -match "arm") { "arm64" } else { "x64" }
            $tarUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$TargetVersion/powershell-$TargetVersion-linux-$arch.tar.gz"
            
            $installDir = "/opt/microsoft/powershell/7"
            & sudo mkdir -p $installDir
            & curl -L $tarUrl | sudo tar -xzC $installDir
            & sudo chmod +x "$installDir/pwsh"
            & sudo ln -sf "$installDir/pwsh" /usr/bin/pwsh
        }
    }
    
    # Verify installation
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        Write-Host "PowerShell $TargetVersion installed successfully!" -ForegroundColor Green
        return $true
    } else {
        Write-Error "PowerShell installation verification failed"
        return $false
    }
}

function Install-PowerShellMacOS {
    param([string]$TargetVersion)
    
    Write-Host "Installing PowerShell $TargetVersion on macOS..." -ForegroundColor Cyan
    
    # Check for Homebrew
    if (-not (Get-Command brew -ErrorAction SilentlyContinue)) {
        Write-Host "Installing Homebrew first..." -ForegroundColor Gray
        & /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    }
    
    # Install PowerShell via Homebrew
    & brew install --cask powershell
    
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        Write-Host "PowerShell $TargetVersion installed successfully!" -ForegroundColor Green
        return $true
    } else {
        Write-Error "PowerShell installation verification failed"
        return $false
    }
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  PowerShell 7 Installation" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Determine target version
$targetVersion = if ($Version -eq "latest") { Get-LatestPowerShellVersion } else { $Version }
Write-Host "Target version: $targetVersion" -ForegroundColor Gray

# Check current installation
$currentVersion = Get-CurrentPowerShellVersion
if ($currentVersion) {
    Write-Host "Current version: $currentVersion" -ForegroundColor Gray
    
    if (-not $Force -and [version]$currentVersion -ge [version]$targetVersion) {
        Write-Host "`nPowerShell $currentVersion is already installed and up to date." -ForegroundColor Green
        exit 0
    }
}

# Install based on platform
$success = $false

if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $success = Install-PowerShellWindows -TargetVersion $targetVersion
}
elseif ($IsLinux) {
    $success = Install-PowerShellLinux -TargetVersion $targetVersion
}
elseif ($IsMacOS) {
    $success = Install-PowerShellMacOS -TargetVersion $targetVersion
}
else {
    Write-Error "Unsupported operating system"
    exit 1
}

if ($success) {
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Installation complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Please restart your terminal and run:" -ForegroundColor Yellow
    Write-Host "    pwsh" -ForegroundColor White
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    exit 200  # Signal restart needed
} else {
    Write-Error "PowerShell installation failed"
    exit 1
}
