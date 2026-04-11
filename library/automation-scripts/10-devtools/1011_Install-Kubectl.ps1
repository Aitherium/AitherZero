<#
.SYNOPSIS
    Installs kubectl (Kubernetes CLI).

.DESCRIPTION
    Downloads and installs the latest stable version of kubectl.
    Verifies installation.

.EXAMPLE
    ./0220_Install-Kubectl.ps1

.NOTES
    Script Number: 0220
    Author: AitherZero
#>
[CmdletBinding()]
param()

try {
    Write-Host "Installing kubectl..." -ForegroundColor Cyan

    if ($IsLinux) {
        $url = "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        curl -LO $url
        chmod +x kubectl
        mkdir -p ~/.local/bin
        mv ./kubectl ~/.local/bin/kubectl
        
        # Ensure path is updated in current session if needed, though usually handled by shell
        if ($env:PATH -notlike "*~/.local/bin*") {
            $env:PATH += ":$HOME/.local/bin"
        }
    }
    elseif ($IsWindows) {
        winget install -e --id Kubernetes.kubectl
    }
    
    # Verify
    kubectl version --client
    Write-Host "kubectl installed successfully." -ForegroundColor Green
}
catch {
    Write-Error "kubectl installation failed: $_"
    exit 1
}
