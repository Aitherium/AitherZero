#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys AitherOS to a Kubernetes cluster.

.DESCRIPTION
    Deploys AitherOS to Kubernetes using kubectl and kustomize.
    Supports different components and rolling updates.

.PARAMETER Namespace
    Kubernetes namespace. Default: "aitheros"

.PARAMETER Context
    Kubernetes context to use. Default: current context

.PARAMETER Component
    Component to deploy: "all", "genesis", "services", "veil". Default: "all"

.PARAMETER DryRun
    Show what would be applied without making changes. Default: $false

.PARAMETER Wait
    Wait for deployment to complete. Default: $true

.EXAMPLE
    .\3002_Deploy-K8sCluster.ps1 -Namespace aitheros-prod

.NOTES
    Category: deploy
    Dependencies: kubectl, kustomize
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [string]$Namespace = "aitheros",
    [string]$Context = "",
    
    [ValidateSet("all", "genesis", "services", "veil", "setup")]
    [string]$Component = "all",
    
    [switch]$DryRun,
    [switch]$Wait = $true
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent
$k8sDir = Join-Path $workspaceRoot "docker/k8s"

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Deploying AitherOS to Kubernetes" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Validate kubectl
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Error "kubectl is not installed."
    exit 1
}

# Set context if provided
if ($Context) {
    kubectl config use-context $Context
}

# Verify cluster connection
Write-Host "Verifying cluster connection..." -ForegroundColor Gray
$clusterInfo = kubectl cluster-info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Cannot connect to Kubernetes cluster"
    exit 1
}

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Component:  $Component" -ForegroundColor Gray
Write-Host "  Dry Run:    $DryRun" -ForegroundColor Gray
Write-Host ""

# Determine what to apply
$manifests = @()

switch ($Component) {
    "setup" {
        $manifests = @("namespace.yaml")
    }
    "genesis" {
        $manifests = @("genesis-deployment.yaml")
    }
    "services" {
        $manifests = @("services-statefulset.yaml")
    }
    "veil" {
        $manifests = @("veil-deployment.yaml")
    }
    "all" {
        # Use kustomize for full deployment
        $manifests = @("kustomization")
    }
}

# Apply manifests
foreach ($manifest in $manifests) {
    Write-Host "Applying: $manifest" -ForegroundColor Yellow
    
    $applyArgs = @("apply")
    
    if ($manifest -eq "kustomization") {
        $applyArgs += "-k", $k8sDir
    } else {
        $applyArgs += "-f", (Join-Path $k8sDir $manifest)
    }
    
    if ($DryRun) {
        $applyArgs += "--dry-run=client"
    }
    
    $applyArgs += "-n", $Namespace
    
    Write-Host "kubectl $($applyArgs -join ' ')" -ForegroundColor DarkGray
    
    kubectl @applyArgs
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to apply $manifest"
        exit 1
    }
}

# Wait for deployment if requested
if ($Wait -and -not $DryRun) {
    Write-Host ""
    Write-Host "Waiting for deployments to be ready..." -ForegroundColor Yellow
    
    kubectl rollout status deployment/genesis -n $Namespace --timeout=300s
    kubectl rollout status deployment/veil -n $Namespace --timeout=300s
}

# Show status
if (-not $DryRun) {
    Write-Host ""
    Write-Host "Deployment Status:" -ForegroundColor Yellow
    kubectl get pods -n $Namespace
    Write-Host ""
    kubectl get services -n $Namespace
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Kubernetes deployment complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Access via port-forward:" -ForegroundColor Yellow
Write-Host "    kubectl -n $Namespace port-forward svc/genesis 8001:8001" -ForegroundColor White
Write-Host "    kubectl -n $Namespace port-forward svc/veil 3000:3000" -ForegroundColor White
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
exit 0
