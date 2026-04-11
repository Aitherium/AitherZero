#Requires -Version 7.0
# Stage: Development
# Dependencies: AitherZero
# Description: Install Docker Desktop or Docker Engine using Install-AitherPackage (where possible).
# Tags: development, docker, containers, virtualization

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [hashtable]$Configuration
)

. "$PSScriptRoot/_init.ps1"

if (-not $Configuration) {
    $Configuration = Get-AitherConfigs -ErrorAction SilentlyContinue
}

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0208_Install-Docker'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting Docker installation..."

try {
    # 1. Check Configuration
    Ensure-FeatureEnabled -Section "Features" -Key "Development.Docker" -Name "Docker"

    # Reload config
    $Configuration = Get-AitherConfigs
    $dockerConfig = @{ EnableWSL2 = $false; AddUserToGroup = $false }

    if ($Configuration.Features.Development.Docker) {
        $cfg = $Configuration.Features.Development.Docker
        # Merge defaults
        if ($cfg.EnableWSL2) { $dockerConfig.EnableWSL2 = $cfg.EnableWSL2 }
        if ($cfg.AddUserToGroup) { $dockerConfig.AddUserToGroup = $cfg.AddUserToGroup }
    }

    # 2. Install Docker
    if ($PSCmdlet.ShouldProcess("System", "Install Docker")) {
        if ($IsLinux) {
            # Linux: Docker requires complex repo setup which Install-AitherPackage doesn't handle yet.
            # We keep the robust logic here.
            Write-ScriptLog "Installing Docker Engine for Linux..."

            if (Get-Command apt-get -ErrorAction SilentlyContinue) {
                # Debian/Ubuntu
                sudo apt-get update
                sudo apt-get install -y ca-certificates curl gnupg lsb-release

                sudo mkdir -p /etc/apt/keyrings
                # Removing old key if exists to avoid conflict/prompt
                if (Test-Path /etc/apt/keyrings/docker.gpg) { sudo rm /etc/apt/keyrings/docker.gpg }
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

                $distrib = lsb_release -cs
                $arch = dpkg --print-architecture
                $repo = "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $distrib stable"
                # Write to temp file then move to avoid permission issues with redirection
                $repo | sudo tee /etc/apt/sources.list.d/docker.list > $null

                sudo apt-get update
                sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

                sudo systemctl start docker
                sudo systemctl enable docker
            }
            elseif (Get-Command yum -ErrorAction SilentlyContinue) {
                # RHEL/CentOS
                sudo yum install -y yum-utils
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                sudo systemctl start docker
                sudo systemctl enable docker
            }
            else {
                throw "Unsupported Linux package manager for Docker."
            }

            # Post-install configuration
            if ($dockerConfig.AddUserToGroup) {
                $currentUser = $env:USER
                sudo usermod -aG docker $currentUser
                Write-ScriptLog "Added user $currentUser to 'docker' group."
            }

        }
        else {
            # Windows (Winget/Choco) and MacOS (Brew)
            # Use Install-AitherPackage
            Install-AitherPackage -Name "docker" -WingetId "Docker.DockerDesktop" -ChocoId "docker-desktop" -BrewName "docker"
        }
    }

    # 3. Verify Installation
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $v = docker --version
        Write-ScriptLog "Docker verified: $v" -Level Success

        if ($IsWindows -or $IsMacOS) {
            Write-ScriptLog "Note: Docker Desktop must be started manually to run the daemon." -Level Warning
        }
    }
    else {
        # On Windows/Mac, might not be in PATH immediately until restart/app start
        if ($IsLinux) {
            throw "Docker command not found after installation."
        }
        else {
            Write-ScriptLog "Docker installed but 'docker' command not yet in PATH. Please restart shell or start Docker Desktop." -Level Warning
        }
    }

}
catch {
    Write-ScriptLog "Docker installation failed: $_" -Level Error
    exit 1
}
