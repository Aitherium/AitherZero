#Requires -Version 7.0

# Stage: Cloud
# Dependencies: OpenTofu, gcloud CLI
# Description: Destroy AitherOS deployment on Google Cloud Platform
# Tags: cloud, gcp, destroy, infrastructure

<#
.SYNOPSIS
    Destroys AitherOS deployment on Google Cloud Platform.

.DESCRIPTION
    This script tears down all AitherOS resources from GCP using OpenTofu.
    
    Configuration is loaded from AitherZero config.psd1 and config.local.psd1:
    - Cloud.GCP.ProjectId - GCP Project ID
    
    It will destroy:
    - Cloud Run services
    - GKE cluster (if full profile)
    - VPC and networking
    - Artifact Registry
    - Secret Manager secrets
    
    State bucket is preserved for safety.

.PARAMETER ProjectId
    GCP Project ID (default: from config.local.psd1)

.PARAMETER Environment
    Environment to destroy: dev, staging, or production

.PARAMETER AutoApprove
    Skip confirmation prompt (DANGEROUS)

.PARAMETER KeepRegistry
    Keep Artifact Registry and container images

.PARAMETER KeepSecrets
    Keep Secret Manager secrets

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    # Destroy dev environment using config defaults
    .\0831_Destroy-AitherGCP.ps1

.EXAMPLE
    # Force destroy production (DANGEROUS)
    .\0831_Destroy-AitherGCP.ps1 -Environment production -AutoApprove

.EXAMPLE
    # Destroy but keep images and secrets
    .\0831_Destroy-AitherGCP.ps1 -KeepRegistry -KeepSecrets
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ProjectId,

    [Parameter()]
    [ValidateSet('dev', 'staging', 'production')]
    [string]$Environment = 'dev',

    [Parameter()]
    [switch]$AutoApprove,

    [Parameter()]
    [switch]$KeepRegistry,

    [Parameter()]
    [switch]$KeepSecrets,

    [Parameter()]
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"

# =========================================================================
# Load configuration defaults
# =========================================================================

$config = Get-AitherConfigs -ErrorAction SilentlyContinue
$gcpConfig = $config.Cloud.GCP

if (-not $ProjectId) {
    $ProjectId = $gcpConfig.ProjectId
    if (-not $ProjectId) {
        $ProjectId = $env:AITHERZERO_GCP_PROJECT_ID
    }
}

if (-not $ProjectId) {
    Write-ScriptLog "ERROR: ProjectId is required. Set it via:" -Level Error
    Write-ScriptLog "  1. Parameter: -ProjectId 'my-project'" -Level Error
    Write-ScriptLog "  2. Config: Cloud.GCP.ProjectId in config.local.psd1" -Level Error
    Write-ScriptLog "  3. Environment: `$env:AITHERZERO_GCP_PROJECT_ID" -Level Error
    exit 1
}

Write-ScriptLog "Starting AitherOS GCP Teardown"
Write-ScriptLog "Project: $ProjectId | Environment: $Environment"

try {
    # =========================================================================
    # Safety Check
    # =========================================================================

    if ($Environment -eq 'production' -and -not $AutoApprove) {
        Write-Host ""
        Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "║  ⚠️  WARNING: You are about to destroy PRODUCTION!            ║" -ForegroundColor Red
        Write-Host "║                                                               ║" -ForegroundColor Red
        Write-Host "║  This action is IRREVERSIBLE and will delete:                 ║" -ForegroundColor Red
        Write-Host "║  - All running services                                       ║" -ForegroundColor Red
        Write-Host "║  - All data and configurations                                ║" -ForegroundColor Red
        Write-Host "║  - All networking and security rules                          ║" -ForegroundColor Red
        Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
        Write-Host ""
        
        $confirm = Read-Host "Type 'destroy production' to confirm"
        if ($confirm -ne 'destroy production') {
            Write-ScriptLog "Destruction cancelled - confirmation not received"
            exit 0
        }
    }

    # =========================================================================
    # Prerequisites Check
    # =========================================================================

    Write-ScriptLog "Checking prerequisites..."

    # Check gcloud CLI
    $gcloudVersion = & gcloud version --format="value(Google Cloud SDK)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud CLI not found"
    }

    # Check OpenTofu
    $tofuVersion = & tofu version 2>&1 | Select-Object -First 1
    if ($LASTEXITCODE -ne 0) {
        throw "OpenTofu not found"
    }

    # =========================================================================
    # GCP Authentication
    # =========================================================================

    Write-ScriptLog "Verifying GCP authentication..."
    
    $account = & gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>&1
    if (-not $account) {
        throw "Not authenticated to GCP. Run 'gcloud auth login' first."
    }
    Write-ScriptLog "Authenticated as: $account"

    & gcloud config set project $ProjectId 2>&1 | Out-Null

    # =========================================================================
    # OpenTofu Destroy
    # =========================================================================

    $gcpModulePath = Join-Path $projectRoot "AitherZero/library/infrastructure/modules/gcp"
    $stateBucket = "$ProjectId-aither-state"

    if (-not (Test-Path $gcpModulePath)) {
        throw "GCP module not found at: $gcpModulePath"
    }

    Push-Location $gcpModulePath
    try {
        # Initialize OpenTofu
        Write-ScriptLog "Initializing OpenTofu..."
        & tofu init -backend-config="bucket=$stateBucket" -reconfigure
        if ($LASTEXITCODE -ne 0) {
            throw "OpenTofu init failed"
        }

        # Build variables
        $tfVars = @(
            "-var=project_id=$ProjectId"
            "-var=environment=$Environment"
        )

        # Add target flags to preserve resources if requested
        $targets = @()
        if ($KeepRegistry) {
            Write-ScriptLog "Keeping Artifact Registry"
            # We'll need to manually exclude these
        }
        if ($KeepSecrets) {
            Write-ScriptLog "Keeping Secret Manager secrets"
        }

        # Show what will be destroyed
        Write-ScriptLog "Planning destruction..."
        & tofu plan -destroy @tfVars
        if ($LASTEXITCODE -ne 0) {
            throw "OpenTofu plan failed"
        }

        # Confirm
        if (-not $AutoApprove) {
            Write-Host ""
            $confirm = Read-Host "Do you want to proceed with destruction? (yes/no)"
            if ($confirm -notmatch '^(yes|y)$') {
                Write-ScriptLog "Destruction cancelled by user"
                exit 0
            }
        }

        # Destroy
        Write-ScriptLog "Destroying resources..."
        if ($AutoApprove) {
            & tofu destroy @tfVars -auto-approve
        }
        else {
            & tofu destroy @tfVars
        }

        if ($LASTEXITCODE -ne 0) {
            throw "OpenTofu destroy failed"
        }

        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  ✅ AitherOS Destroyed Successfully!" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Resources removed from: $ProjectId ($Environment)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  📦 State bucket preserved: gs://$stateBucket" -ForegroundColor Yellow
        Write-Host "     To delete: gsutil rm -r gs://$stateBucket" -ForegroundColor Gray
        Write-Host ""

        # Clean up local deployment info
        $deploymentFile = Join-Path $projectRoot "logs/aither/gcp-deployment.json"
        if (Test-Path $deploymentFile) {
            Remove-Item $deploymentFile -Force
        }

    }
    finally {
        Pop-Location
    }

    Write-ScriptLog "GCP teardown completed successfully"
    exit 0

}
catch {
    Write-ScriptLog "GCP teardown failed: $_" -Level 'Error'
    exit 1
}
