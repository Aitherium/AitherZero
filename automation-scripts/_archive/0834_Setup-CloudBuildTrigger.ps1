<#
.SYNOPSIS
    Sets up Cloud Build triggers for automatic deployment on git push.

.DESCRIPTION
    This script configures GCP Cloud Build triggers to automatically build and deploy
    AitherOS when commits are pushed to the main branch. It handles:
    - GitHub connection setup (if needed)
    - Repository linking
    - Trigger creation for main branch
    - Optional staging branch trigger

.PARAMETER ProjectId
    GCP Project ID. Defaults to value from .env or config.

.PARAMETER Region
    GCP region for Cloud Build. Defaults to us-central1.

.PARAMETER Repository
    GitHub repository in format 'owner/repo'. Defaults to Aitherium/AitherZero-Internal.

.PARAMETER Branch
    Branch pattern to trigger builds. Defaults to '^main$'.

.PARAMETER Environment
    Environment name (dev, staging, prod). Defaults to dev.

.PARAMETER ConnectionName
    Name for the GitHub connection. Defaults to 'github-aitherium'.

.EXAMPLE
    .\0834_Setup-CloudBuildTrigger.ps1 -ProjectId "my-project" -Repository "Aitherium/AitherZero-Internal"

.NOTES
    Part of AitherZero GCP automation suite.
    Requires gcloud CLI with authenticated user having Cloud Build Admin role.
#>
[CmdletBinding()]
param(
    [string]$ProjectId,
    [string]$Region = "us-central1",
    [string]$Repository = "Aitherium/AitherZero-Internal",
    [string]$Branch = "^main$",
    [string]$Environment = "dev",
    [string]$ConnectionName = "github-aitherium",
    [switch]$ShowOutput
)

# Initialize script environment
$scriptRoot = $PSScriptRoot
$initScript = Join-Path $scriptRoot "_init.ps1"
if (Test-Path $initScript) {
    . $initScript
} else {
    # Fallback if _init.ps1 not found
    $global:AITHERZERO_ROOT = (Get-Item $scriptRoot).Parent.Parent.Parent.FullName
}

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Info')
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Error'   { 'Red' }
        'Warning' { 'Yellow' }
        'Success' { 'Green' }
        default   { 'White' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Find gcloud
$gcloudPaths = @(
    (Get-Command gcloud -ErrorAction SilentlyContinue)?.Source,
    "C:\Users\$env:USERNAME\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
    "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
    "/usr/bin/gcloud",
    "/usr/local/bin/gcloud"
)

$gcloud = $null
foreach ($path in $gcloudPaths) {
    if ($path -and (Test-Path $path)) {
        $gcloud = $path
        break
    }
}

if (-not $gcloud) {
    Write-ScriptLog "gcloud CLI not found. Please install it first." -Level 'Error'
    Write-ScriptLog "Run: .\0833_Install-GCloudCLI.ps1" -Level 'Warning'
    exit 1
}

Write-ScriptLog "Using gcloud: $gcloud"

# Get project ID from environment if not specified
if (-not $ProjectId) {
    $envFile = Join-Path $global:AITHERZERO_ROOT ".env"
    if (Test-Path $envFile) {
        $envContent = Get-Content $envFile -Raw
        if ($envContent -match 'GCP_PROJECT_ID=([^\r\n]+)') {
            $ProjectId = $matches[1].Trim('"', "'")
        }
    }
    if (-not $ProjectId) {
        $ProjectId = & $gcloud config get-value project 2>$null
    }
}

if (-not $ProjectId) {
    Write-ScriptLog "No project ID specified and none found in config/env" -Level 'Error'
    exit 1
}

Write-ScriptLog "Project: $ProjectId"
Write-ScriptLog "Repository: $Repository"
Write-ScriptLog "Branch pattern: $Branch"

# Parse repository
$repoParts = $Repository -split '/'
$repoOwner = $repoParts[0]
$repoName = $repoParts[1]

# Enable required APIs
Write-ScriptLog "Enabling required APIs..."
$apis = @(
    "cloudbuild.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "run.googleapis.com"
)

foreach ($api in $apis) {
    & $gcloud services enable $api --project=$ProjectId 2>$null
}

# Check/Create GitHub connection
Write-ScriptLog "Checking GitHub connection..."
$connections = & $gcloud builds connections list --region=$Region --project=$ProjectId --format="value(name)" 2>$null
$connectionExists = $connections -match $ConnectionName

if (-not $connectionExists) {
    Write-ScriptLog "Creating GitHub connection: $ConnectionName" -Level 'Warning'
    
    # Grant Cloud Build service account Secret Manager permissions
    $projectNumber = & $gcloud projects describe $ProjectId --format="value(projectNumber)"
    $serviceAccount = "service-${projectNumber}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
    
    Write-ScriptLog "Granting Secret Manager permissions to Cloud Build..."
    & $gcloud projects add-iam-policy-binding $ProjectId `
        --member="serviceAccount:$serviceAccount" `
        --role="roles/secretmanager.admin" `
        --quiet 2>$null
    
    # Create connection
    & $gcloud builds connections create github $ConnectionName `
        --region=$Region `
        --project=$ProjectId
    
    if ($LASTEXITCODE -ne 0) {
        Write-ScriptLog "Failed to create GitHub connection" -Level 'Error'
        exit 1
    }
    
    Write-ScriptLog "GitHub connection created. Please complete OAuth in browser." -Level 'Warning'
    Write-ScriptLog "After completing OAuth, run this script again to create triggers." -Level 'Warning'
    exit 0
}

# Check connection status
$connectionStatus = & $gcloud builds connections describe $ConnectionName `
    --region=$Region `
    --project=$ProjectId `
    --format="value(installationState.stage)" 2>$null

if ($connectionStatus -eq "PENDING_USER_OAUTH" -or $connectionStatus -eq "PENDING_INSTALL_APP") {
    Write-ScriptLog "GitHub connection is pending authorization" -Level 'Warning'
    
    # Get OAuth URL
    $oauthUrl = & $gcloud builds connections describe $ConnectionName `
        --region=$Region `
        --project=$ProjectId `
        --format="value(installationState.message)" 2>$null
    
    Write-ScriptLog "Please complete authorization at:" -Level 'Warning'
    Write-ScriptLog $oauthUrl -Level 'Warning'
    
    Start-Process $oauthUrl
    exit 0
}

Write-ScriptLog "GitHub connection is active" -Level 'Success'

# Link repository
Write-ScriptLog "Linking repository: $Repository"
$repoLinkName = $repoName.ToLower() -replace '[^a-z0-9-]', '-'

$existingRepos = & $gcloud builds repositories list `
    --connection=$ConnectionName `
    --region=$Region `
    --project=$ProjectId `
    --format="value(name)" 2>$null

$repoLinked = $existingRepos -match $repoLinkName

if (-not $repoLinked) {
    Write-ScriptLog "Creating repository link..."
    & $gcloud builds repositories create $repoLinkName `
        --connection=$ConnectionName `
        --region=$Region `
        --project=$ProjectId `
        --remote-uri="https://github.com/$Repository.git"
    
    if ($LASTEXITCODE -ne 0) {
        Write-ScriptLog "Failed to link repository" -Level 'Error'
        exit 1
    }
    Write-ScriptLog "Repository linked successfully" -Level 'Success'
} else {
    Write-ScriptLog "Repository already linked" -Level 'Success'
}

# Create trigger
$triggerName = "aither-$Environment-deploy"
Write-ScriptLog "Creating Cloud Build trigger: $triggerName"

$existingTriggers = & $gcloud builds triggers list `
    --region=$Region `
    --project=$ProjectId `
    --format="value(name)" 2>$null

$triggerExists = $existingTriggers -match $triggerName

if ($triggerExists) {
    Write-ScriptLog "Trigger already exists. Updating..." -Level 'Warning'
    & $gcloud builds triggers delete $triggerName `
        --region=$Region `
        --project=$ProjectId `
        --quiet 2>$null
}

# Create trigger with repository event config
$repoFullPath = "projects/$ProjectId/locations/$Region/connections/$ConnectionName/repositories/$repoLinkName"

& $gcloud builds triggers create github `
    --name=$triggerName `
    --region=$Region `
    --project=$ProjectId `
    --repository=$repoFullPath `
    --branch-pattern=$Branch `
    --build-config="cloudbuild.yaml" `
    --substitutions="_ENVIRONMENT=$Environment,_REGION=$Region" `
    --description="Auto-deploy AitherOS $Environment on push to main"

if ($LASTEXITCODE -ne 0) {
    Write-ScriptLog "Failed to create trigger" -Level 'Error'
    exit 1
}

Write-ScriptLog "Cloud Build trigger created successfully!" -Level 'Success'

# Summary
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✅ Cloud Build Trigger Setup Complete!" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Trigger Name:  $triggerName" -ForegroundColor White
Write-Host "  Repository:    $Repository" -ForegroundColor White
Write-Host "  Branch:        $Branch" -ForegroundColor White
Write-Host "  Environment:   $Environment" -ForegroundColor White
Write-Host ""
Write-Host "  Now when you push to main, Cloud Build will automatically:" -ForegroundColor Yellow
Write-Host "    1. Build Docker images for AitherNode and AitherVeil" -ForegroundColor White
Write-Host "    2. Push images to Artifact Registry" -ForegroundColor White
Write-Host "    3. Deploy to Cloud Run" -ForegroundColor White
Write-Host ""
Write-Host "  View builds: https://console.cloud.google.com/cloud-build/builds?project=$ProjectId" -ForegroundColor Cyan
Write-Host ""
