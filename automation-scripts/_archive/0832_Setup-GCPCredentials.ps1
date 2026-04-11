#Requires -Version 7.0

# Stage: Cloud
# Dependencies: gcloud CLI
# Description: Setup GCP credentials for AitherOS deployment
# Tags: cloud, gcp, credentials, setup

<#
.SYNOPSIS
    Setup GCP credentials for AitherOS deployment.

.DESCRIPTION
    This script helps configure GCP credentials for deploying AitherOS.
    It can:
    - Create a new service account for deployments
    - Generate and store credentials
    - Configure workload identity for GitHub Actions
    - Store credentials in AitherSecrets vault

.PARAMETER ProjectId
    GCP Project ID (required)

.PARAMETER CreateServiceAccount
    Create a new service account for deployments

.PARAMETER SetupWorkloadIdentity
    Setup Workload Identity for GitHub Actions

.PARAMETER StoreInVault
    Store credentials in AitherSecrets vault

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    # Initial setup
    .\0832_Setup-GCPCredentials.ps1 -ProjectId my-project-123 -CreateServiceAccount

.EXAMPLE
    # Setup for GitHub Actions CI/CD
    .\0832_Setup-GCPCredentials.ps1 -ProjectId my-project-123 -SetupWorkloadIdentity
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ProjectId,

    [Parameter()]
    [switch]$CreateServiceAccount,

    [Parameter()]
    [switch]$SetupWorkloadIdentity,

    [Parameter()]
    [switch]$StoreInVault,

    [Parameter()]
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"
Write-ScriptLog "Setting up GCP credentials for AitherOS"

try {
    # =========================================================================
    # Prerequisites
    # =========================================================================

    $gcloudVersion = & gcloud version --format="value(Google Cloud SDK)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud CLI not found. Install from: https://cloud.google.com/sdk/docs/install"
    }

    # Authenticate
    $account = & gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>&1
    if (-not $account) {
        Write-ScriptLog "Not authenticated. Running 'gcloud auth login'..."
        & gcloud auth login
    }

    & gcloud config set project $ProjectId 2>&1 | Out-Null

    # =========================================================================
    # Create Service Account
    # =========================================================================

    if ($CreateServiceAccount) {
        $saName = "aither-deployer"
        $saEmail = "$saName@$ProjectId.iam.gserviceaccount.com"

        Write-ScriptLog "Creating service account: $saEmail"

        # Create service account
        & gcloud iam service-accounts create $saName `
            --display-name="AitherOS Deployer" `
            --description="Service account for deploying AitherOS infrastructure" `
            2>&1 | Out-Null

        # Grant required roles
        $roles = @(
            "roles/run.admin",
            "roles/artifactregistry.admin",
            "roles/secretmanager.admin",
            "roles/compute.admin",
            "roles/container.admin",
            "roles/iam.serviceAccountUser",
            "roles/storage.admin"
        )

        foreach ($role in $roles) {
            Write-ScriptLog "Granting: $role"
            & gcloud projects add-iam-policy-binding $ProjectId `
                --member="serviceAccount:$saEmail" `
                --role="$role" `
                --quiet 2>&1 | Out-Null
        }

        # Generate key file
        $keyPath = Join-Path $projectRoot "AitherZero/config/gcp-credentials.json"
        Write-ScriptLog "Generating key file: $keyPath"
        
        & gcloud iam service-accounts keys create $keyPath `
            --iam-account="$saEmail"

        if (Test-Path $keyPath) {
            Write-Host ""
            Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
            Write-Host "  ✅ Service Account Created!" -ForegroundColor Green
            Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
            Write-Host ""
            Write-Host "  📧 Email: $saEmail" -ForegroundColor Cyan
            Write-Host "  🔑 Key:   $keyPath" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  ⚠️  Keep this key file secure! It grants full deploy access." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Set environment variable:" -ForegroundColor Gray
            Write-Host "  `$env:GOOGLE_APPLICATION_CREDENTIALS = '$keyPath'" -ForegroundColor Gray
            Write-Host ""
        }
    }

    # =========================================================================
    # Setup Workload Identity (for GitHub Actions)
    # =========================================================================

    if ($SetupWorkloadIdentity) {
        Write-ScriptLog "Setting up Workload Identity Federation for GitHub Actions"

        $poolName = "aither-github-pool"
        $providerName = "aither-github"
        $saName = "aither-github-actions"
        $saEmail = "$saName@$ProjectId.iam.gserviceaccount.com"

        # Create workload identity pool
        & gcloud iam workload-identity-pools create $poolName `
            --location="global" `
            --display-name="AitherOS GitHub Pool" `
            2>&1 | Out-Null

        # Create GitHub provider
        & gcloud iam workload-identity-pools providers create-oidc $providerName `
            --location="global" `
            --workload-identity-pool=$poolName `
            --display-name="GitHub" `
            --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" `
            --issuer-uri="https://token.actions.githubusercontent.com" `
            2>&1 | Out-Null

        # Create service account for GitHub Actions
        & gcloud iam service-accounts create $saName `
            --display-name="AitherOS GitHub Actions" `
            2>&1 | Out-Null

        # Grant roles
        $roles = @(
            "roles/run.admin",
            "roles/artifactregistry.writer",
            "roles/storage.objectAdmin"
        )

        foreach ($role in $roles) {
            & gcloud projects add-iam-policy-binding $ProjectId `
                --member="serviceAccount:$saEmail" `
                --role="$role" `
                --quiet 2>&1 | Out-Null
        }

        # Allow GitHub to impersonate the service account
        $poolId = (& gcloud iam workload-identity-pools describe $poolName --location="global" --format="value(name)")
        
        & gcloud iam service-accounts add-iam-policy-binding $saEmail `
            --role="roles/iam.workloadIdentityUser" `
            --member="principalSet://iam.googleapis.com/$poolId/attribute.repository/Aitherium/AitherZero" `
            2>&1 | Out-Null

        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  ✅ Workload Identity Configured!" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Add these secrets to your GitHub repository:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  GCP_PROJECT_ID:          $ProjectId" -ForegroundColor Gray
        Write-Host "  GCP_SERVICE_ACCOUNT:     $saEmail" -ForegroundColor Gray
        Write-Host "  GCP_WORKLOAD_IDENTITY:   $poolId/providers/$providerName" -ForegroundColor Gray
        Write-Host ""
    }

    # =========================================================================
    # Store in AitherSecrets
    # =========================================================================

    if ($StoreInVault) {
        $keyPath = Join-Path $projectRoot "AitherZero/config/gcp-credentials.json"
        
        if (Test-Path $keyPath) {
            Write-ScriptLog "Storing credentials in AitherSecrets vault"
            
            # Check if AitherSecrets is available
            if (Get-Command Set-AitherSecret -ErrorAction SilentlyContinue) {
                $keyContent = Get-Content $keyPath -Raw
                Set-AitherSecret -Name "GCP_CREDENTIALS" -Value $keyContent -Provider "GCP"
                Write-ScriptLog "Credentials stored in vault as 'GCP_CREDENTIALS'"
            }
            else {
                Write-ScriptLog "AitherSecrets not available. Skipping vault storage." -Level 'Warning'
            }
        }
        else {
            Write-ScriptLog "No credentials file found. Run with -CreateServiceAccount first." -Level 'Warning'
        }
    }

    # =========================================================================
    # Default: Just authenticate
    # =========================================================================

    if (-not $CreateServiceAccount -and -not $SetupWorkloadIdentity -and -not $StoreInVault) {
        Write-ScriptLog "Setting up application default credentials..."
        
        & gcloud auth application-default login
        
        Write-Host ""
        Write-Host "✅ Application default credentials configured!" -ForegroundColor Green
        Write-Host ""
        Write-Host "You can now run:" -ForegroundColor Cyan
        Write-Host "  .\0830_Deploy-AitherGCP.ps1 -Profile demo -ProjectId $ProjectId" -ForegroundColor Gray
        Write-Host ""
    }

    Write-ScriptLog "GCP credential setup completed"
    exit 0

}
catch {
    Write-ScriptLog "GCP credential setup failed: $_" -Level 'Error'
    exit 1
}
