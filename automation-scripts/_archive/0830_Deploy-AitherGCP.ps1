#Requires -Version 7.0

# Stage: Cloud
# Dependencies: OpenTofu, gcloud CLI
# Description: Deploy AitherOS to Google Cloud Platform
# Tags: cloud, gcp, deploy, infrastructure

<#
.SYNOPSIS
    Deploys AitherOS to Google Cloud Platform using OpenTofu.

.DESCRIPTION
    This script deploys the complete AitherOS ecosystem to GCP using Infrastructure as Code.
    
    Configuration is loaded from AitherZero config.psd1 and config.local.psd1:
    - Cloud.GCP.ProjectId - GCP Project ID
    - Cloud.GCP.Region - GCP Region
    - Cloud.GCP.DefaultProfile - Deployment profile (minimal/demo/full)
    - Cloud.GCP.Account - GCP account email
    
    It supports three deployment profiles:
    - minimal: ~$30-50/mo - Basic demo with Cloud Run
    - demo:    ~$80-120/mo - Full demo with higher resources
    - full:    ~$250-400/mo - Production with GKE and GPU support

.PARAMETER Profile
    Deployment profile: minimal, demo, or full (default: from config or 'minimal')

.PARAMETER ProjectId
    GCP Project ID (default: from config.local.psd1)

.PARAMETER Region
    GCP Region (default: from config or 'us-central1')

.PARAMETER Environment
    Environment name: dev, staging, or production

.PARAMETER GeminiApiKey
    Google Gemini API key (optional, can be set via env var)

.PARAMETER AutoApprove
    Skip confirmation prompt

.PARAMETER BuildImages
    Build and push Docker images before deploying

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    # Deploy using all defaults from config
    .\0830_Deploy-AitherGCP.ps1

.EXAMPLE
    # Deploy minimal demo (overriding config)
    .\0830_Deploy-AitherGCP.ps1 -Profile minimal -ProjectId my-project-123

.EXAMPLE
    # Deploy full production with GPU
    .\0830_Deploy-AitherGCP.ps1 -Profile full -Environment production -AutoApprove
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateSet('minimal', 'demo', 'full')]
    [string]$Profile,

    [Parameter()]
    [string]$ProjectId,

    [Parameter()]
    [string]$Region,

    [Parameter()]
    [ValidateSet('dev', 'staging', 'production')]
    [string]$Environment = 'dev',

    [Parameter()]
    [string]$GeminiApiKey,

    [Parameter()]
    [switch]$AutoApprove,

    [Parameter()]
    [switch]$BuildImages,

    [Parameter()]
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"

# =========================================================================
# Load configuration defaults from config.psd1 / config.local.psd1
# =========================================================================

$config = Get-AitherConfigs -ErrorAction SilentlyContinue
$gcpConfig = $config.Cloud.GCP

# Apply config defaults if parameters not specified
if (-not $ProjectId) {
    $ProjectId = $gcpConfig.ProjectId
    if (-not $ProjectId) {
        $ProjectId = $env:AITHERZERO_GCP_PROJECT_ID
    }
}

if (-not $Region) {
    $Region = $gcpConfig.Region
    if (-not $Region) {
        $Region = $env:AITHERZERO_GCP_REGION
        if (-not $Region) { $Region = 'us-central1' }
    }
}

if (-not $Profile) {
    $Profile = $gcpConfig.DefaultProfile
    if (-not $Profile) { $Profile = 'minimal' }
}

# Validate required parameters
if (-not $ProjectId) {
    Write-ScriptLog "ERROR: ProjectId is required. Set it via:" -Level Error
    Write-ScriptLog "  1. Parameter: -ProjectId 'my-project'" -Level Error
    Write-ScriptLog "  2. Config: Cloud.GCP.ProjectId in config.local.psd1" -Level Error
    Write-ScriptLog "  3. Environment: `$env:AITHERZERO_GCP_PROJECT_ID" -Level Error
    exit 1
}

Write-ScriptLog "Starting AitherOS GCP Deployment"
Write-ScriptLog "Profile: $Profile | Project: $ProjectId | Region: $Region"
Write-ScriptLog "Config source: $(if ($gcpConfig.ProjectId) { 'config.local.psd1' } else { 'parameters/env' })"

# =========================================================================
# Load .env file if exists
# =========================================================================

$envFile = Join-Path $projectRoot ".env"
if (Test-Path $envFile) {
    Write-ScriptLog "Loading environment from .env file"
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            # Only set if not already defined
            if (-not [Environment]::GetEnvironmentVariable($key)) {
                [Environment]::SetEnvironmentVariable($key, $value, 'Process')
            }
        }
    }
}

try {
    # =========================================================================
    # Prerequisites Check & Auto-Install
    # =========================================================================
    
    Write-ScriptLog "Checking and installing prerequisites..."

    # Helper function to refresh PATH
    function Update-SessionPath {
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    }

    # Refresh PATH at start (pick up any recently installed tools)
    Update-SessionPath

    # -------------------------------------------------------------------------
    # 1. gcloud CLI - Auto-install if missing
    # -------------------------------------------------------------------------
    $gcloudCmd = Get-Command gcloud -ErrorAction SilentlyContinue
    
    # Also check common Windows install paths if not in PATH
    if (-not $gcloudCmd -and $IsWindows) {
        $commonPaths = @(
            "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"
            "$env:ProgramFiles\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"
            "$env:ProgramFiles (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"
        )
        foreach ($path in $commonPaths) {
            if (Test-Path $path) {
                $gcloudDir = Split-Path $path -Parent
                $env:Path = "$gcloudDir;$env:Path"
                $gcloudCmd = Get-Command gcloud -ErrorAction SilentlyContinue
                if ($gcloudCmd) {
                    Write-ScriptLog "Found gcloud at: $gcloudDir"
                    break
                }
            }
        }
    }
    
    if (-not $gcloudCmd) {
        Write-ScriptLog "gcloud CLI not found. Installing automatically..." -Level Warning
        
        $installerScript = Join-Path $PSScriptRoot "0833_Install-GCloudCLI.ps1"
        if (Test-Path $installerScript) {
            & $installerScript -Method Auto -ShowOutput:$ShowOutput
            Update-SessionPath
            
            $gcloudCmd = Get-Command gcloud -ErrorAction SilentlyContinue
            if (-not $gcloudCmd) {
                throw "gcloud CLI installation completed but requires terminal restart. Please close and reopen PowerShell, then run this script again."
            }
            Write-ScriptLog "gcloud CLI installed successfully!" -Level Success
        } else {
            throw "gcloud CLI not found and installer script missing. Install manually: https://cloud.google.com/sdk/docs/install"
        }
    }
    $gcloudVersion = & gcloud version --format="value(Google Cloud SDK)" 2>&1
    Write-ScriptLog "gcloud CLI: $gcloudVersion"

    # -------------------------------------------------------------------------
    # 2. OpenTofu - Auto-install if missing
    # -------------------------------------------------------------------------
    $tofuCmd = Get-Command tofu -ErrorAction SilentlyContinue
    if (-not $tofuCmd) {
        Write-ScriptLog "OpenTofu not found. Installing automatically..." -Level Warning
        
        $installerScript = Join-Path $PSScriptRoot "0008_Install-OpenTofu.ps1"
        if (Test-Path $installerScript) {
            # Force install without config check
            & $installerScript -Configuration @{Features=@{Infrastructure=@{OpenTofu=@{Enabled=$true}}}}
            Update-SessionPath
            
            $tofuCmd = Get-Command tofu -ErrorAction SilentlyContinue
            if (-not $tofuCmd) {
                throw "OpenTofu installation completed but requires terminal restart. Please close and reopen PowerShell, then run this script again."
            }
            Write-ScriptLog "OpenTofu installed successfully!" -Level Success
        } else {
            throw "OpenTofu not found and installer script missing. Install manually: https://opentofu.org/docs/intro/install/"
        }
    }
    $tofuVersion = & tofu version 2>&1 | Select-Object -First 1
    Write-ScriptLog "OpenTofu: $tofuVersion"

    # -------------------------------------------------------------------------
    # 3. Docker - Check if available (optional - will use Cloud Build if not)
    # -------------------------------------------------------------------------
    $script:useCloudBuild = $false
    if ($BuildImages) {
        $dockerAvailable = $false
        $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
        
        if ($dockerCmd) {
            $dockerVersion = & docker version --format "{{.Server.Version}}" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $dockerAvailable = $true
                Write-ScriptLog "Docker: $dockerVersion"
            } else {
                Write-ScriptLog "Docker installed but not running. Will use Cloud Build instead." -Level Warning
            }
        } else {
            Write-ScriptLog "Docker not found. Will use Cloud Build for container images." -Level Warning
        }
        
        if (-not $dockerAvailable) {
            $script:useCloudBuild = $true
            Write-ScriptLog "Container images will be built using Google Cloud Build"
        }
    }

    # =========================================================================
    # GCP Authentication - Fully Automated
    # =========================================================================

    Write-ScriptLog "Verifying GCP authentication..."
    
    # Check if authenticated
    $account = & gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>&1
    if (-not $account -or $account -match "ERROR") {
        Write-ScriptLog "Not authenticated to GCP. Starting authentication..."
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║  GCP Authentication Required                                 ║" -ForegroundColor Yellow
        Write-Host "║  A browser window will open for Google login.                ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""
        
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) {
            throw "GCP authentication failed. Please try again."
        }
        $account = & gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>&1
    }
    Write-ScriptLog "Authenticated as: $account"

    # Set project
    & gcloud config set project $ProjectId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set GCP project: $ProjectId. Make sure the project exists and you have access."
    }
    Write-ScriptLog "Project set to: $ProjectId"

    # Enable application default credentials for OpenTofu
    $adcPath = if ($IsWindows) { "$env:APPDATA\gcloud\application_default_credentials.json" } else { "$HOME/.config/gcloud/application_default_credentials.json" }
    if (-not (Test-Path $adcPath)) {
        Write-ScriptLog "Setting up application default credentials for OpenTofu..."
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║  Application Default Credentials Required                    ║" -ForegroundColor Yellow
        Write-Host "║  This allows OpenTofu to authenticate with GCP.              ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""
        
        & gcloud auth application-default login --no-launch-browser
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to setup application default credentials"
        }
    }

    # =========================================================================
    # Enable Required GCP APIs
    # =========================================================================

    Write-ScriptLog "Enabling required GCP APIs..."
    $requiredApis = @(
        "cloudresourcemanager.googleapis.com"
        "compute.googleapis.com"
        "run.googleapis.com"
        "artifactregistry.googleapis.com"
        "secretmanager.googleapis.com"
        "vpcaccess.googleapis.com"
    )
    
    if ($Profile -eq 'full') {
        $requiredApis += @(
            "container.googleapis.com"
        )
    }

    foreach ($api in $requiredApis) {
        Write-ScriptLog "  Enabling $api..."
        & gcloud services enable $api --quiet 2>&1 | Out-Null
    }
    Write-ScriptLog "All required APIs enabled"

    # =========================================================================
    # State Bucket Setup
    # =========================================================================

    $stateBucket = "$ProjectId-aither-state"
    Write-ScriptLog "Checking state bucket: gs://$stateBucket"

    $bucketExists = & gsutil ls "gs://$stateBucket" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-ScriptLog "Creating state bucket..."
        & gsutil mb -l $Region "gs://$stateBucket"
        & gsutil versioning set on "gs://$stateBucket"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create state bucket"
        }
    }

    # =========================================================================
    # Build and Push Docker Images (if requested)
    # =========================================================================

    if ($BuildImages) {
        Write-ScriptLog "Building and pushing Docker images..."

        # Configure Docker for Artifact Registry
        # Configure Docker for Artifact Registry
        & gcloud auth configure-docker "$Region-docker.pkg.dev" --quiet

        # Create Artifact Registry repository if it doesn't exist
        $registry = "$Region-docker.pkg.dev/$ProjectId/aither-$Environment"
        & gcloud artifacts repositories create "aither-$Environment" `
            --repository-format=docker `
            --location=$Region `
            --description="AitherOS container images" 2>&1 | Out-Null

        # Check if local Docker is available
        if (-not $script:useCloudBuild) {
            # Build images locally with docker-compose
            $composeFile = Join-Path $projectRoot "docker-compose.aitheros.yml"
            if (Test-Path $composeFile) {
                Push-Location $projectRoot
                try {
                    & docker compose -f docker-compose.aitheros.yml build
                    & docker tag aither-veil:latest "$registry/aither-veil:latest"
                    & docker push "$registry/aither-veil:latest"
                    & docker tag aither-node:latest "$registry/aither-node:latest"
                    & docker push "$registry/aither-node:latest"
                    Write-ScriptLog "Images pushed to: $registry"
                }
                finally {
                    Pop-Location
                }
            }
        }
        else {
            # Use Google Cloud Build to build images remotely
            Write-ScriptLog "Building images with Google Cloud Build..."
            
            Push-Location $projectRoot
            try {
                # Build AitherVeil (Dashboard)
                Write-ScriptLog "Building AitherVeil image with Cloud Build..."
                $veilDockerfile = Join-Path $projectRoot "AitherOS/AitherVeil/Dockerfile"
                if (Test-Path $veilDockerfile) {
                    # Build from project root with Dockerfile path specified
                    & gcloud builds submit $projectRoot `
                        --config (Join-Path $projectRoot "AitherOS/AitherVeil/cloudbuild.yaml") `
                        --substitutions "_REGISTRY=$registry" `
                        --quiet 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        # Try simpler approach if cloudbuild.yaml doesn't exist
                        Write-ScriptLog "Trying direct Dockerfile build..." -Level Warning
                        & gcloud builds submit $projectRoot `
                            --dockerfile "AitherOS/AitherVeil/Dockerfile" `
                            --tag "$registry/aither-veil:latest" `
                            --ignore-file ".gcloudignore" `
                            --quiet 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            Write-ScriptLog "Failed to build AitherVeil image" -Level Warning
                        }
                    }
                }

                # Build AitherNode (MCP Server)
                Write-ScriptLog "Building AitherNode image with Cloud Build..."
                $nodeDockerfile = Join-Path $projectRoot "AitherOS/Dockerfile"
                if (Test-Path $nodeDockerfile) {
                    & gcloud builds submit $projectRoot `
                        --dockerfile "AitherOS/Dockerfile" `
                        --tag "$registry/aither-node:latest" `
                        --ignore-file ".gcloudignore" `
                        --quiet 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Write-ScriptLog "Failed to build AitherNode image" -Level Warning
                    }
                }

                Write-ScriptLog "Cloud Build completed. Images at: $registry"
            }
            finally {
                Pop-Location
            }
        }
    }

    # =========================================================================
    # OpenTofu Deployment
    # =========================================================================

    $gcpModulePath = Join-Path $projectRoot "AitherZero/library/infrastructure/modules/gcp"
    $profilePath = Join-Path $gcpModulePath "profiles/$Profile.tfvars"

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
            "-var=region=$Region"
            "-var=environment=$Environment"
            "-var=profile=$Profile"
        )

        # Add Gemini API key if provided (check multiple sources)
        $apiKey = $GeminiApiKey
        if (-not $apiKey) { $apiKey = $env:GEMINI_API_KEY }
        if (-not $apiKey) { $apiKey = $env:GOOGLE_API_KEY }
        
        if ($apiKey) {
            Write-ScriptLog "Found API key, adding to secrets"
            $tfVars += "-var=secrets={`"gemini_api_key`":`"$apiKey`"}"
        }
        else {
            Write-ScriptLog "No API key found. Set GOOGLE_API_KEY or GEMINI_API_KEY in .env" -Level 'Warning'
        }

        # Plan
        Write-ScriptLog "Planning deployment..."
        $planFile = "aither-$Environment.tfplan"
        $planArgs = $tfVars + @("-out", $planFile)
        & tofu plan @planArgs
        if ($LASTEXITCODE -ne 0) {
            throw "OpenTofu plan failed"
        }

        # Show cost estimate
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  Estimated Monthly Cost: " -NoNewline
        switch ($Profile) {
            'minimal' { Write-Host '$30-50/month' -ForegroundColor Green }
            'demo' { Write-Host '$80-120/month' -ForegroundColor Yellow }
            'full' { Write-Host '$250-400/month' -ForegroundColor Red }
        }
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""

        # Confirm
        if (-not $AutoApprove) {
            $confirm = Read-Host "Do you want to proceed with deployment? (yes/no)"
            if ($confirm -notmatch '^(yes|y)$') {
                Write-ScriptLog "Deployment cancelled by user"
                exit 0
            }
        }

        # Apply
        Write-ScriptLog "Applying deployment..."
        & tofu apply $planFile
        if ($LASTEXITCODE -ne 0) {
            throw "OpenTofu apply failed"
        }

        # Get outputs
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  ✅ AitherOS Deployed Successfully!" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host ""

        $veilUrl = & tofu output -raw veil_url 2>$null
        $nodeUrl = & tofu output -raw node_url 2>$null
        $registryUrl = & tofu output -raw registry_url 2>$null

        if ($veilUrl) {
            Write-Host "  🌐 Dashboard:  $veilUrl" -ForegroundColor Cyan
        }
        if ($nodeUrl) {
            Write-Host "  🔌 API:        $nodeUrl" -ForegroundColor Cyan
        }
        if ($registryUrl) {
            Write-Host "  📦 Registry:   $registryUrl" -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host "  💡 Teardown command:" -ForegroundColor Yellow
        Write-Host "     .\0831_Destroy-AitherGCP.ps1 -ProjectId $ProjectId -Environment $Environment" -ForegroundColor Gray
        Write-Host ""

        # Save deployment info
        $deploymentInfo = @{
            Timestamp   = Get-Date -Format "o"
            Profile     = $Profile
            ProjectId   = $ProjectId
            Region      = $Region
            Environment = $Environment
            VeilUrl     = $veilUrl
            NodeUrl     = $nodeUrl
            RegistryUrl = $registryUrl
        }
        $deploymentInfo | ConvertTo-Json | Set-Content (Join-Path $projectRoot "logs/aither/gcp-deployment.json")

    }
    finally {
        Pop-Location
    }

    Write-ScriptLog "GCP deployment completed successfully"
    exit 0

}
catch {
    Write-ScriptLog "GCP deployment failed: $_" -Level 'Error'
    exit 1
}
