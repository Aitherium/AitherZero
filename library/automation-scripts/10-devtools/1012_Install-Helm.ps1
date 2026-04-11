<#
.SYNOPSIS
    Installs Helm (Kubernetes Package Manager).

.DESCRIPTION
    Downloads and installs the latest version of Helm.

.EXAMPLE
    ./0221_Install-Helm.ps1

.NOTES
    Script Number: 0221
    Author: AitherZero
#>
[CmdletBinding()]
param()

try {
    Write-Host "Installing Helm..." -ForegroundColor Cyan

    if ($IsLinux) {
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
        Remove-Item get_helm.sh
    }
    elseif ($IsWindows) {
        winget install -e --id Helm.Helm
    }

    # Verify
    helm version
    Write-Host "Helm installed successfully." -ForegroundColor Green
}
catch {
    Write-Error "Helm installation failed: $_"
    exit 1
}
