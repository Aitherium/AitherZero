#Requires -Version 7.0
<#
.SYNOPSIS
    Installs Docker or Podman container runtime.

.DESCRIPTION
    Installs and configures the container runtime:
    - Windows: Docker Desktop with WSL2 backend
    - Linux: Docker Engine or Podman
    - macOS: Docker Desktop
    
    Also configures:
    - Docker Compose plugin
    - GPU support (NVIDIA Container Toolkit on Linux)
    - User permissions

.PARAMETER Engine
    Container engine to install: "docker" or "podman". Default: "docker"

.PARAMETER EnableGPU
    Enable NVIDIA GPU support. Default: $false

.PARAMETER SkipCompose
    Skip Docker Compose installation. Default: $false

.EXAMPLE
    .\0003_Install-Docker.ps1 -Verbose
    
.EXAMPLE
    .\0003_Install-Docker.ps1 -Engine podman -EnableGPU

.NOTES
    Category: bootstrap
    Dependencies: 0001_Validate-Prerequisites.ps1
    Platform: Windows, Linux, macOS
    Exit Codes:
        0 - Success
        1 - Installation failed
        200 - Success, restart/logout required
#>

[CmdletBinding()]
param(
    [ValidateSet("docker", "podman")]
    [string]$Engine = "docker",
    
    [switch]$EnableGPU,
    [switch]$SkipCompose
)

$ErrorActionPreference = 'Stop'

# Import shared utilities if available
$initPath = Join-Path (Split-Path $PSScriptRoot -Parent) '_init.ps1'
if (Test-Path $initPath) {
    . $initPath
}

function Test-DockerInstalled {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) {
        try {
            $version = docker version --format '{{.Server.Version}}' 2>$null
            return @{ Installed = $true; Version = $version }
        } catch {
            return @{ Installed = $true; Version = "Unknown (daemon not running)" }
        }
    }
    return @{ Installed = $false; Version = $null }
}

function Test-PodmanInstalled {
    $podman = Get-Command podman -ErrorAction SilentlyContinue
    if ($podman) {
        try {
            $version = podman version --format '{{.Server.Version}}' 2>$null
            return @{ Installed = $true; Version = $version }
        } catch {
            $version = podman --version 2>$null
            return @{ Installed = $true; Version = $version }
        }
    }
    return @{ Installed = $false; Version = $null }
}

function Install-DockerWindows {
    Write-Host "Installing Docker Desktop on Windows..." -ForegroundColor Cyan
    
    # Check for WSL2
    $wslStatus = wsl --status 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Enabling WSL2..." -ForegroundColor Gray
        
        # Enable WSL feature
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
        
        # Set WSL2 as default
        wsl --set-default-version 2
    }
    
    # Download Docker Desktop installer
    $installerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    $installerPath = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
    
    Write-Host "Downloading Docker Desktop..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    
    # Install silently
    Write-Host "Installing Docker Desktop (this may take a few minutes)..." -ForegroundColor Gray
    
    $process = Start-Process -FilePath $installerPath -ArgumentList "install", "--quiet", "--accept-license" -Wait -PassThru
    
    # Cleanup
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    
    if ($process.ExitCode -eq 0) {
        Write-Host "Docker Desktop installed successfully!" -ForegroundColor Green
        
        # Add current user to docker-users group
        try {
            Add-LocalGroupMember -Group "docker-users" -Member $env:USERNAME -ErrorAction SilentlyContinue
        } catch { }
        
        return $true
    } else {
        Write-Error "Docker Desktop installation failed with exit code: $($process.ExitCode)"
        return $false
    }
}

function Install-DockerLinux {
    Write-Host "Installing Docker Engine on Linux..." -ForegroundColor Cyan
    
    # Detect distribution
    $distro = ""
    if (Test-Path /etc/os-release) {
        $osRelease = Get-Content /etc/os-release
        $distroLine = $osRelease | Where-Object { $_ -match '^ID=' }
        $distro = ($distroLine -split '=')[1] -replace '"', ''
    }
    
    switch -Wildcard ($distro) {
        { $_ -in "ubuntu", "debian" } {
            Write-Host "Detected $distro, using apt..." -ForegroundColor Gray
            
            # Remove old versions
            & sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>$null
            
            # Install prerequisites
            & sudo apt-get update
            & sudo apt-get install -y ca-certificates curl gnupg lsb-release
            
            # Add Docker's official GPG key
            & sudo install -m 0755 -d /etc/apt/keyrings
            & curl -fsSL "https://download.docker.com/linux/$distro/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            & sudo chmod a+r /etc/apt/keyrings/docker.gpg
            
            # Add repository
            $arch = dpkg --print-architecture
            $codename = lsb_release -cs
            $repoLine = "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro $codename stable"
            $repoLine | sudo tee /etc/apt/sources.list.d/docker.list > $null
            
            # Install Docker
            & sudo apt-get update
            & sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        }
        { $_ -in "rhel", "centos", "fedora" } {
            Write-Host "Detected $distro, using dnf/yum..." -ForegroundColor Gray
            
            # Remove old versions
            & sudo yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>$null
            
            # Install yum-utils and add repo
            & sudo yum install -y yum-utils
            & sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            
            # Install Docker
            & sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        }
        "arch" {
            Write-Host "Detected Arch Linux, using pacman..." -ForegroundColor Gray
            & sudo pacman -S --noconfirm docker docker-compose
        }
        default {
            Write-Host "Using convenience script for unknown distribution..." -ForegroundColor Yellow
            & curl -fsSL https://get.docker.com | sudo sh
        }
    }
    
    # Start and enable Docker
    & sudo systemctl start docker
    & sudo systemctl enable docker
    
    # Add user to docker group
    & sudo usermod -aG docker $env:USER
    
    # Verify installation
    if (docker --version 2>$null) {
        Write-Host "Docker Engine installed successfully!" -ForegroundColor Green
        return $true
    } else {
        Write-Error "Docker installation verification failed"
        return $false
    }
}

function Install-DockerMacOS {
    Write-Host "Installing Docker Desktop on macOS..." -ForegroundColor Cyan
    
    # Check for Homebrew
    if (-not (Get-Command brew -ErrorAction SilentlyContinue)) {
        Write-Error "Homebrew is required. Install it first: /bin/bash -c `"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)`""
        return $false
    }
    
    # Install Docker Desktop via Homebrew
    & brew install --cask docker
    
    Write-Host "Docker Desktop installed. Please start it from Applications." -ForegroundColor Yellow
    return $true
}

function Install-PodmanLinux {
    Write-Host "Installing Podman on Linux..." -ForegroundColor Cyan
    
    # Detect distribution
    $distro = ""
    if (Test-Path /etc/os-release) {
        $osRelease = Get-Content /etc/os-release
        $distroLine = $osRelease | Where-Object { $_ -match '^ID=' }
        $distro = ($distroLine -split '=')[1] -replace '"', ''
    }
    
    switch -Wildcard ($distro) {
        { $_ -in "ubuntu", "debian" } {
            & sudo apt-get update
            & sudo apt-get install -y podman podman-compose
        }
        { $_ -in "rhel", "centos", "fedora" } {
            & sudo dnf install -y podman podman-compose
        }
        "arch" {
            & sudo pacman -S --noconfirm podman podman-compose
        }
        default {
            Write-Error "Podman installation not supported for this distribution"
            return $false
        }
    }
    
    if (podman --version 2>$null) {
        Write-Host "Podman installed successfully!" -ForegroundColor Green
        return $true
    } else {
        Write-Error "Podman installation verification failed"
        return $false
    }
}

function Install-NVIDIAContainerToolkit {
    Write-Host "Installing NVIDIA Container Toolkit..." -ForegroundColor Cyan
    
    if (-not $IsLinux) {
        Write-Host "NVIDIA Container Toolkit is configured automatically on Windows/macOS with Docker Desktop" -ForegroundColor Yellow
        return $true
    }
    
    # Check for NVIDIA driver
    if (-not (Test-Path /usr/bin/nvidia-smi)) {
        Write-Warning "NVIDIA driver not found. Please install it first."
        return $false
    }
    
    # Install NVIDIA Container Toolkit
    $distro = ""
    if (Test-Path /etc/os-release) {
        $osRelease = Get-Content /etc/os-release
        $distroLine = $osRelease | Where-Object { $_ -match '^ID=' }
        $distro = ($distroLine -split '=')[1] -replace '"', ''
    }
    
    # Add NVIDIA repository
    & curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    $distribution = & sh -c '. /etc/os-release; echo $ID$VERSION_ID'
    & curl -s -L "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" | `
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | `
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    & sudo apt-get update
    & sudo apt-get install -y nvidia-container-toolkit
    
    # Configure Docker to use NVIDIA runtime
    & sudo nvidia-ctk runtime configure --runtime=docker
    & sudo systemctl restart docker
    
    Write-Host "NVIDIA Container Toolkit installed!" -ForegroundColor Green
    return $true
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Container Runtime Installation ($Engine)" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Check existing installation
$existing = if ($Engine -eq "docker") { Test-DockerInstalled } else { Test-PodmanInstalled }

if ($existing.Installed) {
    Write-Host "$Engine is already installed: $($existing.Version)" -ForegroundColor Green
    
    # Still install GPU support if requested
    if ($EnableGPU -and $Engine -eq "docker") {
        Install-NVIDIAContainerToolkit
    }
    
    exit 0
}

# Install based on platform and engine
$success = $false
$needsRestart = $false

if ($Engine -eq "docker") {
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $success = Install-DockerWindows
        $needsRestart = $true
    }
    elseif ($IsLinux) {
        $success = Install-DockerLinux
        $needsRestart = $true  # Need to logout for group membership
    }
    elseif ($IsMacOS) {
        $success = Install-DockerMacOS
    }
}
else {
    # Podman
    if ($IsLinux) {
        $success = Install-PodmanLinux
    }
    else {
        Write-Error "Podman is primarily supported on Linux. Use Docker Desktop on Windows/macOS."
        exit 1
    }
}

# Install GPU support if requested
if ($success -and $EnableGPU -and $Engine -eq "docker") {
    Install-NVIDIAContainerToolkit
}

if ($success) {
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  $Engine installed successfully!" -ForegroundColor Green
    
    if ($needsRestart) {
        Write-Host ""
        Write-Host "  Please logout and login again (or restart)" -ForegroundColor Yellow
        Write-Host "  to apply group membership changes." -ForegroundColor Yellow
        exit 200
    }
    
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    exit 0
} else {
    Write-Error "$Engine installation failed"
    exit 1
}
