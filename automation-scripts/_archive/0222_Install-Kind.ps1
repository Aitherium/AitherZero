<#
.SYNOPSIS
    Installs Kind (Kubernetes in Docker).

.DESCRIPTION
    Downloads and installs Kind for local cluster testing.
    Requires Docker to be installed.

.EXAMPLE
    ./0222_Install-Kind.ps1

.NOTES
    Script Number: 0222
    Author: AitherZero
#>
[CmdletBinding()]
param()

try {
    Write-Host "Checking for Docker..." -ForegroundColor Cyan
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Throw "Docker is required for Kind but is not installed. Run script 0208 first."
    }

    Write-Host "Installing Kind..." -ForegroundColor Cyan

    if ($IsLinux) {
        # Detect arch
        $arch = "amd64"
        if ((uname -m) -eq "aarch64") { $arch = "arm64" }
        
        $url = "https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-$arch"
        curl -Lo ./kind $url
        chmod +x ./kind
        mkdir -p ~/.local/bin
        mv ./kind ~/.local/bin/kind
    }
    elseif ($IsWindows) {
        winget install -e --id Kubernetes.kind
    }

    # Verify
    kind version
    Write-Host "Kind installed successfully." -ForegroundColor Green
}
catch {
    Write-Error "Kind installation failed: $_"
    exit 1
}
