#Requires -Version 7.0
<#
.SYNOPSIS
    Installs Kubernetes CLI tools and local cluster options.

.DESCRIPTION
    Installs Kubernetes command-line tools:
    - kubectl: Kubernetes CLI
    - helm: Package manager for Kubernetes
    - kind/minikube/k3d: Local cluster options
    
    Optionally creates a local development cluster.

.PARAMETER LocalCluster
    Type of local cluster to install: "kind", "minikube", "k3d", or "none". Default: "kind"

.PARAMETER CreateCluster
    Create a local cluster after installation. Default: $false

.PARAMETER ClusterName
    Name for the local cluster. Default: "aitheros-dev"

.EXAMPLE
    .\0004_Install-Kubernetes.ps1 -Verbose
    
.EXAMPLE
    .\0004_Install-Kubernetes.ps1 -LocalCluster kind -CreateCluster -ClusterName "aither-dev"

.NOTES
    Category: bootstrap
    Dependencies: 0003_Install-Docker.ps1
    Platform: Windows, Linux, macOS
    Exit Codes:
        0 - Success
        1 - Installation failed
#>

[CmdletBinding()]
param(
    [ValidateSet("kind", "minikube", "k3d", "none")]
    [string]$LocalCluster = "kind",
    
    [switch]$CreateCluster,
    
    [string]$ClusterName = "aitheros-dev"
)

$ErrorActionPreference = 'Stop'

# Import shared utilities if available
$initPath = Join-Path (Split-Path $PSScriptRoot -Parent) '_init.ps1'
if (Test-Path $initPath) {
    . $initPath
}

function Test-KubectlInstalled {
    $kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
    if ($kubectl) {
        try {
            $version = kubectl version --client --short 2>$null
            if (-not $version) {
                $version = kubectl version --client -o json 2>$null | ConvertFrom-Json
                $version = $version.clientVersion.gitVersion
            }
            return @{ Installed = $true; Version = $version }
        } catch {
            return @{ Installed = $true; Version = "Unknown" }
        }
    }
    return @{ Installed = $false; Version = $null }
}

function Test-HelmInstalled {
    $helm = Get-Command helm -ErrorAction SilentlyContinue
    if ($helm) {
        try {
            $version = helm version --short 2>$null
            return @{ Installed = $true; Version = $version }
        } catch {
            return @{ Installed = $true; Version = "Unknown" }
        }
    }
    return @{ Installed = $false; Version = $null }
}

function Install-KubectlWindows {
    Write-Host "Installing kubectl on Windows..." -ForegroundColor Gray
    
    # Get latest stable version
    $latestVersion = (Invoke-WebRequest -Uri "https://dl.k8s.io/release/stable.txt" -UseBasicParsing).Content.Trim()
    
    # Download kubectl
    $downloadUrl = "https://dl.k8s.io/release/$latestVersion/bin/windows/amd64/kubectl.exe"
    $kubectlPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\kubectl.exe"
    
    # Alternative: use chocolatey if available
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "Using Chocolatey to install kubectl..." -ForegroundColor Gray
        choco install kubernetes-cli -y
        return $true
    }
    
    # Alternative: use winget if available
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Using winget to install kubectl..." -ForegroundColor Gray
        winget install -e --id Kubernetes.kubectl --accept-source-agreements --accept-package-agreements
        return $true
    }
    
    # Manual download
    Write-Host "Downloading kubectl $latestVersion..." -ForegroundColor Gray
    $installDir = Join-Path $env:LOCALAPPDATA "kubectl"
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    
    $kubectlExe = Join-Path $installDir "kubectl.exe"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $kubectlExe
    
    # Add to PATH
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$currentPath;$installDir", "User")
        $env:Path = "$env:Path;$installDir"
    }
    
    return $true
}

function Install-KubectlLinux {
    Write-Host "Installing kubectl on Linux..." -ForegroundColor Gray
    
    # Get latest stable version
    $latestVersion = (curl -L -s https://dl.k8s.io/release/stable.txt)
    
    # Download kubectl
    & curl -LO "https://dl.k8s.io/release/$latestVersion/bin/linux/amd64/kubectl"
    & chmod +x kubectl
    & sudo mv kubectl /usr/local/bin/
    
    return $true
}

function Install-KubectlMacOS {
    Write-Host "Installing kubectl on macOS..." -ForegroundColor Gray
    
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        & brew install kubectl
    } else {
        # Manual install
        $latestVersion = (curl -L -s https://dl.k8s.io/release/stable.txt)
        $arch = if ((uname -m) -eq "arm64") { "arm64" } else { "amd64" }
        & curl -LO "https://dl.k8s.io/release/$latestVersion/bin/darwin/$arch/kubectl"
        & chmod +x kubectl
        & sudo mv kubectl /usr/local/bin/
    }
    
    return $true
}

function Install-HelmWindows {
    Write-Host "Installing Helm on Windows..." -ForegroundColor Gray
    
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        choco install kubernetes-helm -y
        return $true
    }
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install -e --id Helm.Helm --accept-source-agreements --accept-package-agreements
        return $true
    }
    
    # Manual download
    $latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/helm/helm/releases/latest"
    $version = $latestRelease.tag_name
    $downloadUrl = "https://get.helm.sh/helm-$version-windows-amd64.zip"
    
    $zipPath = Join-Path $env:TEMP "helm.zip"
    $extractPath = Join-Path $env:TEMP "helm"
    
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    
    $installDir = Join-Path $env:LOCALAPPDATA "helm"
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Move-Item -Path (Join-Path $extractPath "windows-amd64\helm.exe") -Destination $installDir -Force
    
    # Add to PATH
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$currentPath;$installDir", "User")
        $env:Path = "$env:Path;$installDir"
    }
    
    # Cleanup
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    
    return $true
}

function Install-HelmLinux {
    Write-Host "Installing Helm on Linux..." -ForegroundColor Gray
    
    & curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    return $true
}

function Install-HelmMacOS {
    Write-Host "Installing Helm on macOS..." -ForegroundColor Gray
    
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        & brew install helm
    } else {
        & curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    }
    
    return $true
}

function Install-Kind {
    param([string]$Platform)
    
    Write-Host "Installing kind (Kubernetes in Docker)..." -ForegroundColor Gray
    
    switch ($Platform) {
        "Windows" {
            if (Get-Command choco -ErrorAction SilentlyContinue) {
                choco install kind -y
            } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
                winget install -e --id Kubernetes.kind --accept-source-agreements --accept-package-agreements
            } else {
                # Manual download
                $version = (Invoke-RestMethod -Uri "https://api.github.com/repos/kubernetes-sigs/kind/releases/latest").tag_name
                $downloadUrl = "https://kind.sigs.k8s.io/dl/$version/kind-windows-amd64"
                $installDir = Join-Path $env:LOCALAPPDATA "kind"
                New-Item -ItemType Directory -Path $installDir -Force | Out-Null
                Invoke-WebRequest -Uri $downloadUrl -OutFile (Join-Path $installDir "kind.exe")
                
                $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($currentPath -notlike "*$installDir*") {
                    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$installDir", "User")
                    $env:Path = "$env:Path;$installDir"
                }
            }
        }
        "Linux" {
            $version = (curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            & curl -Lo ./kind "https://kind.sigs.k8s.io/dl/$version/kind-linux-amd64"
            & chmod +x ./kind
            & sudo mv ./kind /usr/local/bin/kind
        }
        "macOS" {
            if (Get-Command brew -ErrorAction SilentlyContinue) {
                & brew install kind
            } else {
                $version = (curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
                $arch = if ((uname -m) -eq "arm64") { "arm64" } else { "amd64" }
                & curl -Lo ./kind "https://kind.sigs.k8s.io/dl/$version/kind-darwin-$arch"
                & chmod +x ./kind
                & sudo mv ./kind /usr/local/bin/kind
            }
        }
    }
    
    return (Get-Command kind -ErrorAction SilentlyContinue) -ne $null
}

function Install-K3d {
    param([string]$Platform)
    
    Write-Host "Installing k3d (k3s in Docker)..." -ForegroundColor Gray
    
    switch ($Platform) {
        "Windows" {
            if (Get-Command choco -ErrorAction SilentlyContinue) {
                choco install k3d -y
            } else {
                # Use install script via PowerShell
                Invoke-WebRequest -Uri "https://raw.githubusercontent.com/k3d-io/k3d/main/install.ps1" -OutFile "$env:TEMP\install-k3d.ps1"
                & "$env:TEMP\install-k3d.ps1"
            }
        }
        { $_ -in "Linux", "macOS" } {
            & curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
        }
    }
    
    return (Get-Command k3d -ErrorAction SilentlyContinue) -ne $null
}

function Install-Minikube {
    param([string]$Platform)
    
    Write-Host "Installing minikube..." -ForegroundColor Gray
    
    switch ($Platform) {
        "Windows" {
            if (Get-Command choco -ErrorAction SilentlyContinue) {
                choco install minikube -y
            } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
                winget install -e --id Kubernetes.minikube --accept-source-agreements --accept-package-agreements
            }
        }
        "Linux" {
            & curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
            & sudo install minikube-linux-amd64 /usr/local/bin/minikube
            Remove-Item minikube-linux-amd64 -Force -ErrorAction SilentlyContinue
        }
        "macOS" {
            if (Get-Command brew -ErrorAction SilentlyContinue) {
                & brew install minikube
            } else {
                $arch = if ((uname -m) -eq "arm64") { "arm64" } else { "amd64" }
                & curl -LO "https://storage.googleapis.com/minikube/releases/latest/minikube-darwin-$arch"
                & sudo install "minikube-darwin-$arch" /usr/local/bin/minikube
            }
        }
    }
    
    return (Get-Command minikube -ErrorAction SilentlyContinue) -ne $null
}

function New-LocalCluster {
    param(
        [string]$Type,
        [string]$Name
    )
    
    Write-Host "Creating local Kubernetes cluster: $Name..." -ForegroundColor Cyan
    
    switch ($Type) {
        "kind" {
            # Create kind cluster with config for AitherOS
            $kindConfig = @"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $Name
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  - containerPort: 8001
    hostPort: 8001
    protocol: TCP
  - containerPort: 3000
    hostPort: 3000
    protocol: TCP
"@
            $configPath = Join-Path $env:TEMP "kind-config.yaml"
            $kindConfig | Set-Content -Path $configPath
            
            kind create cluster --config $configPath
            Remove-Item $configPath -Force -ErrorAction SilentlyContinue
        }
        "k3d" {
            k3d cluster create $Name --port "80:80@loadbalancer" --port "443:443@loadbalancer" --port "8001:8001@loadbalancer" --port "3000:3000@loadbalancer"
        }
        "minikube" {
            minikube start --profile=$Name --driver=docker --ports=80:80,443:443,8001:8001,3000:3000
        }
    }
    
    # Wait for cluster to be ready
    Write-Host "Waiting for cluster to be ready..." -ForegroundColor Gray
    kubectl wait --for=condition=Ready nodes --all --timeout=120s
    
    Write-Host "Cluster $Name created successfully!" -ForegroundColor Green
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Kubernetes Tools Installation" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Detect platform
$platform = if ($IsWindows -or $env:OS -eq "Windows_NT") { "Windows" }
            elseif ($IsLinux) { "Linux" }
            elseif ($IsMacOS) { "macOS" }
            else { "Unknown" }

Write-Host "Platform: $platform" -ForegroundColor Gray
Write-Host ""

# Install kubectl
Write-Host "kubectl" -ForegroundColor Yellow
Write-Host "-" * 40

$kubectl = Test-KubectlInstalled
if ($kubectl.Installed) {
    Write-Host "kubectl already installed: $($kubectl.Version)" -ForegroundColor Green
} else {
    $success = switch ($platform) {
        "Windows" { Install-KubectlWindows }
        "Linux" { Install-KubectlLinux }
        "macOS" { Install-KubectlMacOS }
    }
    
    if ($success) {
        Write-Host "kubectl installed successfully!" -ForegroundColor Green
    } else {
        Write-Error "kubectl installation failed"
        exit 1
    }
}

Write-Host ""

# Install Helm
Write-Host "Helm" -ForegroundColor Yellow
Write-Host "-" * 40

$helm = Test-HelmInstalled
if ($helm.Installed) {
    Write-Host "Helm already installed: $($helm.Version)" -ForegroundColor Green
} else {
    $success = switch ($platform) {
        "Windows" { Install-HelmWindows }
        "Linux" { Install-HelmLinux }
        "macOS" { Install-HelmMacOS }
    }
    
    if ($success) {
        Write-Host "Helm installed successfully!" -ForegroundColor Green
    } else {
        Write-Warning "Helm installation failed (non-critical)"
    }
}

Write-Host ""

# Install local cluster tool
if ($LocalCluster -ne "none") {
    Write-Host "Local Cluster Tool ($LocalCluster)" -ForegroundColor Yellow
    Write-Host "-" * 40
    
    $clusterToolInstalled = Get-Command $LocalCluster -ErrorAction SilentlyContinue
    
    if ($clusterToolInstalled) {
        Write-Host "$LocalCluster already installed" -ForegroundColor Green
    } else {
        $success = switch ($LocalCluster) {
            "kind" { Install-Kind -Platform $platform }
            "k3d" { Install-K3d -Platform $platform }
            "minikube" { Install-Minikube -Platform $platform }
        }
        
        if ($success) {
            Write-Host "$LocalCluster installed successfully!" -ForegroundColor Green
        } else {
            Write-Warning "$LocalCluster installation failed (non-critical)"
        }
    }
    
    # Create cluster if requested
    if ($CreateCluster -and (Get-Command $LocalCluster -ErrorAction SilentlyContinue)) {
        Write-Host ""
        New-LocalCluster -Type $LocalCluster -Name $ClusterName
    }
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Kubernetes tools installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
