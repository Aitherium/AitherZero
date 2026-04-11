#Requires -Version 7.0

# Stage: Cloud
# Dependencies: None
# Description: Install Google Cloud SDK (gcloud CLI)
# Tags: cloud, gcp, install, prerequisites

<#
.SYNOPSIS
    Installs Google Cloud SDK (gcloud CLI) for AitherOS cloud deployments.

.DESCRIPTION
    This script installs the Google Cloud SDK which provides the gcloud CLI
    required for deploying AitherOS to Google Cloud Platform.
    
    Installation methods:
    - Windows: winget or direct installer
    - Linux: apt/yum or direct installer
    - macOS: brew or direct installer

.PARAMETER Method
    Installation method: auto, winget, brew, apt, installer

.PARAMETER Configure
    Run initial configuration after installation

.PARAMETER ProjectId
    GCP Project ID to configure after installation

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    # Auto-detect best installation method
    .\0833_Install-GCloudCLI.ps1

.EXAMPLE
    # Install and configure for a specific project
    .\0833_Install-GCloudCLI.ps1 -Configure -ProjectId gen-lang-client-0770506509

.EXAMPLE
    # Force winget installation
    .\0833_Install-GCloudCLI.ps1 -Method winget
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateSet('auto', 'winget', 'brew', 'apt', 'yum', 'installer')]
    [string]$Method = 'auto',

    [Parameter()]
    [switch]$Configure,

    [Parameter()]
    [string]$ProjectId,

    [Parameter()]
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"
Write-ScriptLog "Starting Google Cloud SDK installation"

try {
    # =========================================================================
    # Check if already installed
    # =========================================================================

    $existingGcloud = Get-Command gcloud -ErrorAction SilentlyContinue
    if ($existingGcloud) {
        $version = & gcloud version 2>$null | Select-String "Google Cloud SDK" | Select-Object -First 1
        Write-ScriptLog "Google Cloud SDK already installed: $version"
        
        if ($Configure -or $ProjectId) {
            # Jump to configuration
            goto ConfigureGcloud
        }
        
        Write-Host ""
        Write-Host "✓ gcloud CLI is already installed and ready!" -ForegroundColor Green
        Write-Host "  Path: $($existingGcloud.Source)" -ForegroundColor Gray
        Write-Host ""
        exit 0
    }

    # =========================================================================
    # Determine installation method
    # =========================================================================

    if ($Method -eq 'auto') {
        if ($IsWindows) {
            # Check for winget
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                $Method = 'winget'
            }
            else {
                $Method = 'installer'
            }
        }
        elseif ($IsMacOS) {
            if (Get-Command brew -ErrorAction SilentlyContinue) {
                $Method = 'brew'
            }
            else {
                $Method = 'installer'
            }
        }
        elseif ($IsLinux) {
            if (Get-Command apt -ErrorAction SilentlyContinue) {
                $Method = 'apt'
            }
            elseif (Get-Command yum -ErrorAction SilentlyContinue) {
                $Method = 'yum'
            }
            else {
                $Method = 'installer'
            }
        }
    }

    Write-ScriptLog "Installation method: $Method"

    # =========================================================================
    # Install based on method
    # =========================================================================

    switch ($Method) {
        'winget' {
            Write-ScriptLog "Installing via winget..."
            Write-Host ""
            Write-Host "Installing Google Cloud SDK via winget..." -ForegroundColor Cyan
            Write-Host "This may take a few minutes..." -ForegroundColor Gray
            Write-Host ""

            $result = & winget install Google.CloudSDK --accept-package-agreements --accept-source-agreements 2>&1
            
            if ($LASTEXITCODE -eq 0 -or $result -match "successfully installed") {
                Write-ScriptLog "winget installation completed"
                
                # Refresh PATH
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                
                # Also add common installation paths
                $gcloudPaths = @(
                    "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin",
                    "$env:ProgramFiles\Google\Cloud SDK\google-cloud-sdk\bin",
                    "$env:ProgramFiles(x86)\Google\Cloud SDK\google-cloud-sdk\bin"
                )
                foreach ($p in $gcloudPaths) {
                    if (Test-Path $p) {
                        $env:Path += ";$p"
                    }
                }
            }
            else {
                throw "winget installation failed: $result"
            }
        }

        'brew' {
            Write-ScriptLog "Installing via Homebrew..."
            & brew install --cask google-cloud-sdk
            if ($LASTEXITCODE -ne 0) {
                throw "Homebrew installation failed"
            }
        }

        'apt' {
            Write-ScriptLog "Installing via apt..."
            
            # Add Google Cloud SDK repo
            & sudo apt-get update
            & sudo apt-get install -y apt-transport-https ca-certificates gnupg curl
            & curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
            & echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
            & sudo apt-get update
            & sudo apt-get install -y google-cloud-cli
            
            if ($LASTEXITCODE -ne 0) {
                throw "apt installation failed"
            }
        }

        'yum' {
            Write-ScriptLog "Installing via yum..."
            
            # Add Google Cloud SDK repo
            $repoContent = @"
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el8-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
"@
            $repoContent | sudo tee /etc/yum.repos.d/google-cloud-sdk.repo
            & sudo yum install -y google-cloud-cli
            
            if ($LASTEXITCODE -ne 0) {
                throw "yum installation failed"
            }
        }

        'installer' {
            Write-ScriptLog "Using direct installer..."
            
            if ($IsWindows) {
                $installerUrl = "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe"
                $installerPath = Join-Path $env:TEMP "GoogleCloudSDKInstaller.exe"
                
                Write-Host "Downloading Google Cloud SDK installer..." -ForegroundColor Cyan
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
                
                Write-Host "Running installer (follow the prompts)..." -ForegroundColor Yellow
                Start-Process -FilePath $installerPath -Wait
                
                # Refresh PATH
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            }
            else {
                # Linux/macOS direct installer
                $installerUrl = "https://sdk.cloud.google.com"
                Write-Host "Running Google Cloud SDK installer..." -ForegroundColor Cyan
                & curl $installerUrl | bash
            }
        }
    }

    # =========================================================================
    # Verify installation
    # =========================================================================

    Write-ScriptLog "Verifying installation..."
    
    # Try to find gcloud
    $gcloudCmd = Get-Command gcloud -ErrorAction SilentlyContinue
    
    if (-not $gcloudCmd) {
        # Check common paths on Windows
        if ($IsWindows) {
            $commonPaths = @(
                "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
                "$env:ProgramFiles\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
                "$env:ProgramFiles(x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
                "$env:USERPROFILE\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"
            )
            
            foreach ($p in $commonPaths) {
                if (Test-Path $p) {
                    $binPath = Split-Path $p -Parent
                    $env:Path += ";$binPath"
                    Write-ScriptLog "Added to PATH: $binPath"
                    $gcloudCmd = Get-Command gcloud -ErrorAction SilentlyContinue
                    break
                }
            }
        }
    }

    if ($gcloudCmd) {
        $version = & gcloud version 2>$null | Select-String "Google Cloud SDK" | Select-Object -First 1
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  ✓ Google Cloud SDK Installed Successfully!" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Version: $version" -ForegroundColor Cyan
        Write-Host "  Path:    $($gcloudCmd.Source)" -ForegroundColor Gray
        Write-Host ""
    }
    else {
        Write-Host ""
        Write-Host "⚠ Installation completed but gcloud not found in PATH." -ForegroundColor Yellow
        Write-Host "  Please restart your terminal or run:" -ForegroundColor Yellow
        Write-Host '  $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine")' -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Or open a new PowerShell window." -ForegroundColor Gray
        Write-Host ""
        exit 0
    }

    # =========================================================================
    # Configuration (if requested)
    # =========================================================================

    if ($Configure -or $ProjectId) {
        Write-ScriptLog "Configuring gcloud CLI..."
        Write-Host ""
        Write-Host "Configuring Google Cloud SDK..." -ForegroundColor Cyan
        Write-Host ""

        # Check if already authenticated
        $authList = & gcloud auth list --format="value(account)" 2>$null
        if (-not $authList) {
            Write-Host "Opening browser for authentication..." -ForegroundColor Yellow
            & gcloud auth login
            
            if ($LASTEXITCODE -ne 0) {
                Write-ScriptLog "Authentication failed or cancelled" -Level 'Warning'
            }
        }
        else {
            Write-Host "Already authenticated as: $authList" -ForegroundColor Green
        }

        # Set project if provided
        if ($ProjectId) {
            Write-ScriptLog "Setting project to: $ProjectId"
            & gcloud config set project $ProjectId
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Project set to: $ProjectId" -ForegroundColor Green
            }
        }

        # Setup application default credentials
        $adcPath = "$env:APPDATA\gcloud\application_default_credentials.json"
        if (-not (Test-Path $adcPath)) {
            Write-Host ""
            Write-Host "Setting up application default credentials..." -ForegroundColor Yellow
            & gcloud auth application-default login
        }

        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  ✓ Google Cloud SDK Configured!" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host ""
        
        if ($ProjectId) {
            Write-Host "  You can now deploy with:" -ForegroundColor Cyan
            Write-Host "  .\0830_Deploy-AitherGCP.ps1 -Profile demo -ProjectId $ProjectId" -ForegroundColor Gray
        }
        Write-Host ""
    }
    else {
        Write-Host "  Next steps:" -ForegroundColor Yellow
        Write-Host "  1. Run: gcloud auth login" -ForegroundColor Gray
        Write-Host "  2. Run: gcloud config set project YOUR_PROJECT_ID" -ForegroundColor Gray
        Write-Host "  3. Deploy: .\0830_Deploy-AitherGCP.ps1 -Profile demo -ProjectId YOUR_PROJECT_ID" -ForegroundColor Gray
        Write-Host ""
    }

    Write-ScriptLog "Google Cloud SDK installation completed"
    exit 0

}
catch {
    Write-ScriptLog "Google Cloud SDK installation failed: $_" -Level 'Error'
    Write-Host ""
    Write-Host "Installation failed. Try manual installation:" -ForegroundColor Red
    Write-Host "  https://cloud.google.com/sdk/docs/install" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}
