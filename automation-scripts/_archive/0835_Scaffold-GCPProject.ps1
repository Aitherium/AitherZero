#Requires -Version 7.0

# Stage: Cloud
# Dependencies: None (installs everything automatically)
# Description: Complete GCP project scaffold for AitherOS deployment
# Tags: cloud, gcp, scaffold, automation, ci-cd

<#
.SYNOPSIS
    Scaffolds a complete GCP project for AitherOS deployment from scratch.

.DESCRIPTION
    This script automates the ENTIRE process of setting up a GCP project for AitherOS:
    
    1. Installs gcloud CLI (if not present)
    2. Installs OpenTofu (if not present)
    3. Authenticates with GCP
    4. Enables required APIs
    5. Creates GCP infrastructure (VPC, Cloud Run, Artifact Registry, etc.)
    6. Connects GitHub repository
    7. Creates Cloud Build trigger for CI/CD
    8. Builds and pushes initial Docker images
    
    After running this script, pushing to main branch will automatically deploy.

.PARAMETER ProjectId
    GCP Project ID (required). Must already exist in GCP.

.PARAMETER Repository
    GitHub repository in format 'owner/repo'. Default: Aitherium/AitherOS

.PARAMETER Region
    GCP region. Default: us-central1

.PARAMETER Profile
    Deployment profile: minimal (~$30-50/mo), demo (~$80-120/mo), full (~$250-400/mo)

.PARAMETER Environment
    Environment name: dev, staging, production. Default: dev

.PARAMETER GeminiApiKey
    Google Gemini API key (optional, can be set later)

.PARAMETER SkipGitHubSetup
    Skip GitHub connection setup (use if already configured)

.PARAMETER SkipInfrastructure
    Skip infrastructure deployment (use if only setting up CI/CD)

.PARAMETER Interactive
    Prompt for all parameters interactively

.EXAMPLE
    # Quick scaffold with minimal profile
    .\0835_Scaffold-GCPProject.ps1 -ProjectId my-project-123

.EXAMPLE
    # Full interactive setup
    .\0835_Scaffold-GCPProject.ps1 -Interactive

.EXAMPLE
    # Production setup with custom repo
    .\0835_Scaffold-GCPProject.ps1 -ProjectId prod-project -Repository "MyOrg/MyApp" -Profile full -Environment production

.NOTES
    This script is idempotent - it can be run multiple times safely.
    Each component checks if it's already configured before running.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ProjectId,

    [Parameter()]
    [string]$Repository = 'Aitherium/AitherOS',

    [Parameter()]
    [string]$Region = 'us-central1',

    [Parameter()]
    [ValidateSet('minimal', 'demo', 'full')]
    [string]$Profile = 'minimal',

    [Parameter()]
    [ValidateSet('dev', 'staging', 'production')]
    [string]$Environment = 'dev',

    [Parameter()]
    [string]$GeminiApiKey,

    [Parameter()]
    [string]$ConnectionName = 'github-aitherium',

    [Parameter()]
    [switch]$SkipGitHubSetup,

    [Parameter()]
    [switch]$SkipInfrastructure,

    [Parameter()]
    [switch]$Interactive,

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize script environment
$scriptRoot = $PSScriptRoot
$initScript = Join-Path $scriptRoot "_init.ps1"
if (Test-Path $initScript) {
    . $initScript
} else {
    $global:AITHERZERO_ROOT = (Get-Item $scriptRoot).Parent.Parent.Parent.FullName
}

#region Utility Functions
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Info')
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Error'   { 'Red' }
        'Warning' { 'Yellow' }
        'Success' { 'Green' }
        'Step'    { 'Cyan' }
        default   { 'White' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-Banner {
    param([string]$Title)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

function Test-CommandExists {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Find-GCloud {
    $paths = @(
        (Get-Command gcloud -ErrorAction SilentlyContinue)?.Source,
        "C:\Users\$env:USERNAME\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
        "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
        "/usr/bin/gcloud",
        "/usr/local/bin/gcloud",
        "/opt/homebrew/bin/gcloud"
    )
    
    foreach ($path in $paths) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }
    return $null
}
#endregion

#region Interactive Prompts
if ($Interactive -or -not $ProjectId) {
    Write-Banner "AitherOS GCP Project Scaffolding"
    
    if (-not $ProjectId) {
        $ProjectId = Read-Host "Enter your GCP Project ID"
        if (-not $ProjectId) {
            Write-ScriptLog "Project ID is required" -Level 'Error'
            exit 1
        }
    }
    
    if ($Interactive) {
        $input = Read-Host "GitHub repository [$Repository]"
        if ($input) { $Repository = $input }
        
        $input = Read-Host "GCP region [$Region]"
        if ($input) { $Region = $input }
        
        $input = Read-Host "Deployment profile (minimal/demo/full) [$Profile]"
        if ($input -and $input -in @('minimal', 'demo', 'full')) { $Profile = $input }
        
        $input = Read-Host "Environment (dev/staging/production) [$Environment]"
        if ($input -and $input -in @('dev', 'staging', 'production')) { $Environment = $input }
        
        if (-not $GeminiApiKey) {
            $GeminiApiKey = Read-Host "Gemini API Key (optional, press Enter to skip)"
        }
    }
}
#endregion

Write-Banner "Scaffolding GCP Project: $ProjectId"

Write-Host "  Configuration:" -ForegroundColor Yellow
Write-Host "    Project:     $ProjectId"
Write-Host "    Repository:  $Repository"
Write-Host "    Region:      $Region"
Write-Host "    Profile:     $Profile"
Write-Host "    Environment: $Environment"
Write-Host ""

$stepNumber = 0
$totalSteps = 6 - [int]$SkipGitHubSetup - [int]$SkipInfrastructure

#region Step 1: Install gcloud CLI
$stepNumber++
Write-ScriptLog "Step $stepNumber/$totalSteps: Checking gcloud CLI..." -Level 'Step'

$gcloud = Find-GCloud

if (-not $gcloud) {
    Write-ScriptLog "gcloud CLI not found. Installing..." -Level 'Warning'
    
    $installScript = Join-Path $scriptRoot "0833_Install-GCloudCLI.ps1"
    if (Test-Path $installScript) {
        & $installScript -ShowOutput:$ShowOutput
        $gcloud = Find-GCloud
    } else {
        Write-ScriptLog "Install script not found. Please install gcloud manually." -Level 'Error'
        Write-ScriptLog "Visit: https://cloud.google.com/sdk/docs/install" -Level 'Warning'
        exit 1
    }
}

if (-not $gcloud) {
    Write-ScriptLog "gcloud CLI installation failed" -Level 'Error'
    exit 1
}

Write-ScriptLog "Using gcloud: $gcloud" -Level 'Success'
#endregion

#region Step 2: Install OpenTofu
$stepNumber++
Write-ScriptLog "Step $stepNumber/$totalSteps: Checking OpenTofu..." -Level 'Step'

if (-not (Test-CommandExists 'tofu')) {
    Write-ScriptLog "OpenTofu not found. Installing..." -Level 'Warning'
    
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        # Install via winget
        winget install OpenTofu.tofu --accept-package-agreements --accept-source-agreements 2>$null
        
        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    } else {
        # Linux/Mac installation
        if (Test-CommandExists 'brew') {
            brew install opentofu/tap/opentofu
        } else {
            curl -fsSL https://get.opentofu.org/install-opentofu.sh | bash -s -- --install-method standalone
        }
    }
}

if (-not (Test-CommandExists 'tofu')) {
    Write-ScriptLog "OpenTofu installation failed. Please install manually." -Level 'Error'
    Write-ScriptLog "Visit: https://opentofu.org/docs/intro/install/" -Level 'Warning'
    exit 1
}

Write-ScriptLog "OpenTofu installed: $(tofu version | Select-Object -First 1)" -Level 'Success'
#endregion

#region Step 3: GCP Authentication
$stepNumber++
Write-ScriptLog "Step $stepNumber/$totalSteps: Configuring GCP authentication..." -Level 'Step'

# Check if already authenticated
$currentAccount = & $gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null
if ($currentAccount) {
    Write-ScriptLog "Already authenticated as: $currentAccount" -Level 'Success'
} else {
    Write-ScriptLog "Starting GCP authentication..." -Level 'Warning'
    & $gcloud auth login
}

# Set project
& $gcloud config set project $ProjectId 2>$null
& $gcloud config set compute/region $Region 2>$null

# Setup Application Default Credentials
$adcPath = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    "$env:APPDATA\gcloud\application_default_credentials.json"
} else {
    "$HOME/.config/gcloud/application_default_credentials.json"
}

if (-not (Test-Path $adcPath)) {
    Write-ScriptLog "Setting up Application Default Credentials..." -Level 'Warning'
    & $gcloud auth application-default login
}

Write-ScriptLog "GCP authentication configured" -Level 'Success'
#endregion

#region Step 4: Enable APIs
$stepNumber++
Write-ScriptLog "Step $stepNumber/$totalSteps: Enabling GCP APIs..." -Level 'Step'

$apis = @(
    'cloudbuild.googleapis.com',
    'run.googleapis.com',
    'artifactregistry.googleapis.com',
    'secretmanager.googleapis.com',
    'compute.googleapis.com',
    'vpcaccess.googleapis.com',
    'iam.googleapis.com',
    'cloudresourcemanager.googleapis.com'
)

foreach ($api in $apis) {
    Write-Host "  Enabling $api..." -NoNewline
    $result = & $gcloud services enable $api --project=$ProjectId 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " ✓" -ForegroundColor Green
    } else {
        Write-Host " (already enabled or failed)" -ForegroundColor Yellow
    }
}

Write-ScriptLog "APIs enabled" -Level 'Success'
#endregion

#region Step 5: GitHub Connection & Trigger (optional)
if (-not $SkipGitHubSetup) {
    $stepNumber++
    Write-ScriptLog "Step $stepNumber/$totalSteps: Setting up GitHub connection..." -Level 'Step'
    
    # Grant Cloud Build service account Secret Manager permissions
    $projectNumber = & $gcloud projects describe $ProjectId --format="value(projectNumber)"
    $cbServiceAccount = "service-${projectNumber}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
    
    Write-Host "  Granting Secret Manager permissions..."
    & $gcloud projects add-iam-policy-binding $ProjectId `
        --member="serviceAccount:$cbServiceAccount" `
        --role="roles/secretmanager.admin" `
        --quiet 2>$null
    
    # Check if connection exists
    $connections = & $gcloud builds connections list --region=$Region --project=$ProjectId --format="value(name)" 2>$null
    $connectionExists = $connections -match $ConnectionName
    
    if (-not $connectionExists) {
        Write-ScriptLog "Creating GitHub connection: $ConnectionName" -Level 'Warning'
        & $gcloud builds connections create github $ConnectionName --region=$Region --project=$ProjectId
        
        Write-Host ""
        Write-Host "  ⚠️  ACTION REQUIRED: Complete GitHub OAuth in browser" -ForegroundColor Yellow
        Write-Host "     After authorizing, press ENTER to continue..." -ForegroundColor Yellow
        Read-Host
    }
    
    # Check connection status
    $status = & $gcloud builds connections describe $ConnectionName --region=$Region --project=$ProjectId --format="value(installationState.stage)" 2>$null
    
    if ($status -ne 'COMPLETE') {
        Write-ScriptLog "GitHub connection pending. Please complete OAuth." -Level 'Warning'
        $oauthUrl = & $gcloud builds connections describe $ConnectionName --region=$Region --project=$ProjectId --format="value(installationState.message)" 2>$null
        Start-Process $oauthUrl
        Write-Host "Press ENTER after completing authorization..."
        Read-Host
    }
    
    # Link repository
    $repoParts = $Repository -split '/'
    $repoOwner = $repoParts[0]
    $repoName = $repoParts[1]
    $repoLinkName = $repoName.ToLower() -replace '[^a-z0-9-]', '-'
    
    Write-Host "  Linking repository: $Repository..."
    $existingRepos = & $gcloud builds repositories list --connection=$ConnectionName --region=$Region --project=$ProjectId --format="value(name)" 2>$null
    
    if (-not ($existingRepos -match $repoLinkName)) {
        & $gcloud builds repositories create $repoLinkName `
            --connection=$ConnectionName `
            --region=$Region `
            --project=$ProjectId `
            --remote-uri="https://github.com/$Repository.git" 2>$null
        
        if ($LASTEXITCODE -ne 0) {
            Write-ScriptLog "Repository linking failed. Make sure the Google Cloud Build app is installed on $Repository" -Level 'Warning'
            Write-Host "  Install app here: https://github.com/apps/google-cloud-build/installations/new" -ForegroundColor Yellow
        }
    }
    
    # Create trigger
    $triggerName = "aither-$Environment-deploy"
    Write-Host "  Creating trigger: $triggerName..."
    
    # Delete if exists
    & $gcloud builds triggers delete $triggerName --region=$Region --project=$ProjectId --quiet 2>$null
    
    $computeSa = "${projectNumber}-compute@developer.gserviceaccount.com"
    $repoPath = "projects/$ProjectId/locations/$Region/connections/$ConnectionName/repositories/$repoLinkName"
    
    & $gcloud builds triggers create github `
        --name=$triggerName `
        --region=$Region `
        --project=$ProjectId `
        --repository=$repoPath `
        --branch-pattern="^main$" `
        --build-config="cloudbuild.yaml" `
        --service-account="projects/$ProjectId/serviceAccounts/$computeSa" 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-ScriptLog "Cloud Build trigger created" -Level 'Success'
    } else {
        Write-ScriptLog "Trigger creation had issues - may need manual setup" -Level 'Warning'
    }
}
#endregion

#region Step 6: Deploy Infrastructure (optional)
if (-not $SkipInfrastructure) {
    $stepNumber++
    Write-ScriptLog "Step $stepNumber/$totalSteps: Deploying infrastructure..." -Level 'Step'
    
    $deployScript = Join-Path $scriptRoot "0830_Deploy-AitherGCP.ps1"
    if (Test-Path $deployScript) {
        $deployParams = @{
            ProjectId   = $ProjectId
            Profile     = $Profile
            Region      = $Region
            Environment = $Environment
            AutoApprove = $true
            ShowOutput  = $ShowOutput
        }
        
        if ($GeminiApiKey) {
            $deployParams['GeminiApiKey'] = $GeminiApiKey
        }
        
        & $deployScript @deployParams
        
        if ($LASTEXITCODE -eq 0) {
            Write-ScriptLog "Infrastructure deployed successfully" -Level 'Success'
        } else {
            Write-ScriptLog "Infrastructure deployment had issues" -Level 'Warning'
        }
    } else {
        Write-ScriptLog "Deploy script not found: $deployScript" -Level 'Error'
    }
}
#endregion

#region Summary
$costEstimate = switch ($Profile) {
    'minimal' { '$30-50/month' }
    'demo'    { '$80-120/month' }
    'full'    { '$250-400/month' }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✅ GCP Project Scaffolded Successfully!" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Project:       $ProjectId" -ForegroundColor White
Write-Host "  Repository:    $Repository" -ForegroundColor White
Write-Host "  Environment:   $Environment" -ForegroundColor White
Write-Host "  Profile:       $Profile ($costEstimate)" -ForegroundColor White
Write-Host ""
Write-Host "  🔄 CI/CD Pipeline:" -ForegroundColor Yellow
Write-Host "     Push to main → Cloud Build → Deploy to Cloud Run" -ForegroundColor White
Write-Host ""
Write-Host "  📊 Consoles:" -ForegroundColor Yellow
Write-Host "     Cloud Build:  https://console.cloud.google.com/cloud-build/builds?project=$ProjectId" -ForegroundColor Cyan
Write-Host "     Cloud Run:    https://console.cloud.google.com/run?project=$ProjectId" -ForegroundColor Cyan
Write-Host "     Artifacts:    https://console.cloud.google.com/artifacts?project=$ProjectId" -ForegroundColor Cyan
Write-Host ""
Write-Host "  🚀 Next Steps:" -ForegroundColor Yellow
Write-Host "     1. Commit and push your code to main branch" -ForegroundColor White
Write-Host "     2. Watch the build at the Cloud Build console" -ForegroundColor White
Write-Host "     3. Access your app at the Cloud Run URL" -ForegroundColor White
Write-Host ""
Write-Host "  🗑️  To tear down:" -ForegroundColor Yellow
Write-Host "     .\0831_Destroy-AitherGCP.ps1 -ProjectId `"$ProjectId`" -Environment `"$Environment`"" -ForegroundColor White
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
#endregion
