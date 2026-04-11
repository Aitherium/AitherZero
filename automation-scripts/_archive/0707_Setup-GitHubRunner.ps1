<#
.SYNOPSIS
    Sets up a self-hosted GitHub Actions runner with GPU support for training jobs.

.DESCRIPTION
    This script automates the setup of a self-hosted GitHub Actions runner with:
    - NVIDIA CUDA drivers and toolkit
    - Docker with NVIDIA Container Toolkit
    - GitHub Actions runner registration
    - Proper labels for GPU workloads
    - AitherNode installation for training jobs

.PARAMETER RunnerName
    Name for the runner (defaults to hostname).

.PARAMETER Labels
    Additional labels for the runner (gpu, cuda, training added automatically).

.PARAMETER Token
    GitHub runner registration token. If not provided, attempts to get from gh CLI.

.PARAMETER Uninstall
    Removes the runner and cleans up.

.PARAMETER ShowOutput
    Show detailed output during execution.

.EXAMPLE
    .\0707_Setup-GitHubRunner.ps1 -ShowOutput
    Sets up a GPU runner with default settings.

.EXAMPLE
    .\0707_Setup-GitHubRunner.ps1 -RunnerName "beast-gpu" -Labels @("a6000", "48gb") -ShowOutput
    Sets up a runner with custom name and labels.

.NOTES
    Stage: Git & CI
    Order: 0707
    Category: GitHub Actions
    Author: AitherZero
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [string]$RunnerName = $env:COMPUTERNAME,
    
    [string[]]$Labels = @(),
    
    [string]$Token,
    
    [string]$Repository = "Aitherium/AitherZero-Internal",
    
    [string]$RunnerVersion = "2.321.0",
    
    [switch]$Uninstall,
    
    [switch]$SkipDocker,
    
    [switch]$SkipAitherNode,
    
    [switch]$ShowOutput
)

# Initialize script environment
. "$PSScriptRoot/_init.ps1"

$script:ExitCode = 0
$RunnerDir = "$env:USERPROFILE\actions-runner"

#region Helper Functions

function Write-Status {
    param([string]$Message, [string]$Type = "INFO")
    if ($ShowOutput) {
        $color = switch ($Type) {
            "SUCCESS" { "Green" }
            "ERROR" { "Red" }
            "WARNING" { "Yellow" }
            default { "Cyan" }
        }
        Write-Host "[$Type] $Message" -ForegroundColor $color
    }
    Write-ScriptLog -Message $Message -Level $Type
}

function Test-AdminPrivileges {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-GPUInfo {
    try {
        $nvidia = Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.Name -like "*NVIDIA*" }
        if ($nvidia) {
            return @{
                Name = $nvidia.Name
                Memory = [math]::Round($nvidia.AdapterRAM / 1GB, 2)
                HasGPU = $true
            }
        }
    } catch {}
    
    return @{ HasGPU = $false }
}

function Get-CUDAVersion {
    try {
        $nvcc = & nvcc --version 2>&1
        if ($nvcc -match "release (\d+\.\d+)") {
            return $matches[1]
        }
    } catch {}
    return $null
}

function Get-RegistrationToken {
    param([string]$Repo)
    
    Write-Status "Getting registration token from GitHub..."
    
    # Try using gh CLI first
    try {
        $token = & gh api "repos/$Repo/actions/runners/registration-token" --method POST -q '.token' 2>$null
        if ($token -and $token.Length -gt 0) {
            return $token
        }
    } catch {}
    
    # Try using GITHUB_TOKEN environment variable
    if ($env:GITHUB_TOKEN) {
        try {
            $headers = @{
                "Authorization" = "Bearer $env:GITHUB_TOKEN"
                "Accept" = "application/vnd.github.v3+json"
            }
            $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/runners/registration-token" -Method Post -Headers $headers
            return $response.token
        } catch {}
    }
    
    Write-Status "Could not get registration token automatically" -Type "WARNING"
    Write-Status "Please get token from: https://github.com/$Repo/settings/actions/runners/new" -Type "WARNING"
    return $null
}

#endregion

#region Installation Functions

function Install-CUDA {
    Write-Status "Checking CUDA installation..."
    
    $cudaVersion = Get-CUDAVersion
    if ($cudaVersion) {
        Write-Status "CUDA $cudaVersion already installed" -Type "SUCCESS"
        return $true
    }
    
    Write-Status "Installing CUDA Toolkit..."
    
    # Check for winget
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            winget install --id Nvidia.CUDA --silent --accept-source-agreements --accept-package-agreements
            Write-Status "CUDA installed via winget" -Type "SUCCESS"
            return $true
        } catch {
            Write-Status "winget CUDA install failed: $_" -Type "WARNING"
        }
    }
    
    # Manual download fallback
    $cudaUrl = "https://developer.download.nvidia.com/compute/cuda/12.4.0/local_installers/cuda_12.4.0_551.61_windows.exe"
    $cudaInstaller = "$env:TEMP\cuda_installer.exe"
    
    Write-Status "Downloading CUDA from NVIDIA..."
    try {
        Invoke-WebRequest -Uri $cudaUrl -OutFile $cudaInstaller -UseBasicParsing
        Start-Process -FilePath $cudaInstaller -ArgumentList "-s" -Wait
        Write-Status "CUDA installed" -Type "SUCCESS"
        return $true
    } catch {
        Write-Status "CUDA installation failed: $_" -Type "ERROR"
        return $false
    }
}

function Install-Docker {
    Write-Status "Checking Docker installation..."
    
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Status "Docker already installed" -Type "SUCCESS"
        
        # Check for NVIDIA runtime
        $info = docker info 2>&1
        if ($info -match "nvidia") {
            Write-Status "NVIDIA Container Toolkit already configured" -Type "SUCCESS"
            return $true
        }
    } else {
        Write-Status "Installing Docker Desktop..."
        
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id Docker.DockerDesktop --silent --accept-source-agreements --accept-package-agreements
            Write-Status "Docker Desktop installed - requires restart" -Type "WARNING"
        } else {
            Write-Status "Please install Docker Desktop manually" -Type "ERROR"
            return $false
        }
    }
    
    return $true
}

function Install-GitHubRunner {
    Write-Status "Setting up GitHub Actions runner..."
    
    # Create runner directory
    if (-not (Test-Path $RunnerDir)) {
        New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
    }
    
    # Download runner
    $runnerZip = "$RunnerDir\actions-runner.zip"
    $runnerUrl = "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip"
    
    if (-not (Test-Path "$RunnerDir\config.cmd")) {
        Write-Status "Downloading GitHub Actions runner v$RunnerVersion..."
        Invoke-WebRequest -Uri $runnerUrl -OutFile $runnerZip -UseBasicParsing
        
        Write-Status "Extracting runner..."
        Expand-Archive -Path $runnerZip -DestinationPath $RunnerDir -Force
        Remove-Item $runnerZip -Force
    } else {
        Write-Status "Runner already downloaded" -Type "SUCCESS"
    }
    
    # Get GPU info for labels
    $gpuInfo = Get-GPUInfo
    $allLabels = @("self-hosted", "Windows", "X64")
    
    if ($gpuInfo.HasGPU) {
        $allLabels += @("gpu", "cuda", "training")
        Write-Status "GPU detected: $($gpuInfo.Name) ($($gpuInfo.Memory) GB)" -Type "SUCCESS"
        
        # Add memory-based labels
        if ($gpuInfo.Memory -ge 40) {
            $allLabels += "gpu-large"
        } elseif ($gpuInfo.Memory -ge 20) {
            $allLabels += "gpu-medium"
        } else {
            $allLabels += "gpu-small"
        }
    }
    
    # Add custom labels
    $allLabels += $Labels
    $labelString = ($allLabels | Select-Object -Unique) -join ","
    
    # Get registration token
    if (-not $Token) {
        $Token = Get-RegistrationToken -Repo $Repository
        
        if (-not $Token) {
            Write-Status "Please provide a registration token with -Token parameter" -Type "ERROR"
            return $false
        }
    }
    
    # Configure runner
    Write-Status "Configuring runner with labels: $labelString"
    Push-Location $RunnerDir
    try {
        & .\config.cmd --url "https://github.com/$Repository" --token $Token --name $RunnerName --labels $labelString --runasservice --replace
        Write-Status "Runner configured successfully" -Type "SUCCESS"
    } catch {
        Write-Status "Runner configuration failed: $_" -Type "ERROR"
        return $false
    } finally {
        Pop-Location
    }
    
    return $true
}

function Install-AitherNode {
    Write-Status "Setting up AitherNode for runner..."
    
    $venvPath = "$projectRoot\AitherOS\agents\NarrativeAgent\.venv"
    
    # Install Python dependencies
    if (Test-Path "$venvPath\Scripts\python.exe") {
        Write-Status "Installing training dependencies..."
        & "$venvPath\Scripts\pip.exe" install torch "transformers>=5.0.0" peft accelerate bitsandbytes trl datasets wandb --quiet
        Write-Status "Training dependencies installed" -Type "SUCCESS"
    } else {
        Write-Status "Python venv not found - run 0781_Setup-AitherTrainer.ps1 first" -Type "WARNING"
    }
    
    return $true
}

function Set-GitHubSecrets {
    Write-Status "Configuring GitHub secrets for training..."
    
    $secrets = @{
        "WANDB_API_KEY" = "Weights & Biases API key for experiment tracking"
        "HF_TOKEN" = "Hugging Face token for model downloads"
    }
    
    foreach ($secret in $secrets.Keys) {
        $value = [System.Environment]::GetEnvironmentVariable($secret, "User")
        if ($value) {
            Write-Status "Setting $secret in GitHub..."
            try {
                & gh secret set $secret --body $value --repo $Repository 2>$null
                Write-Status "$secret configured" -Type "SUCCESS"
            } catch {
                Write-Status "Could not set $secret - gh CLI may need authentication" -Type "WARNING"
            }
        } else {
            Write-Status "$secret not found in environment - $($secrets[$secret])" -Type "WARNING"
        }
    }
}

function Uninstall-GitHubRunner {
    Write-Status "Removing GitHub Actions runner..."
    
    if (-not (Test-Path $RunnerDir)) {
        Write-Status "Runner not installed" -Type "WARNING"
        return
    }
    
    # Get removal token
    $removeToken = Get-RegistrationToken -Repo $Repository
    
    if ($removeToken) {
        Push-Location $RunnerDir
        try {
            & .\config.cmd remove --token $removeToken
            Write-Status "Runner unregistered" -Type "SUCCESS"
        } catch {
            Write-Status "Could not unregister runner: $_" -Type "WARNING"
        } finally {
            Pop-Location
        }
    }
    
    # Remove directory
    Remove-Item -Path $RunnerDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Status "Runner directory removed" -Type "SUCCESS"
}

#endregion

#region Main Execution

try {
    # Check admin
    if (-not (Test-AdminPrivileges)) {
        Write-Status "Administrator privileges recommended for full setup" -Type "WARNING"
    }
    
    if ($Uninstall) {
        Uninstall-GitHubRunner
        exit 0
    }
    
    Write-Status "=== GitHub Actions Runner Setup ===" -Type "INFO"
    Write-Status "Runner Name: $RunnerName" -Type "INFO"
    Write-Status "Repository: $Repository" -Type "INFO"
    
    # Step 1: GPU check and CUDA
    $gpuInfo = Get-GPUInfo
    if ($gpuInfo.HasGPU) {
        if (-not (Get-CUDAVersion)) {
            Install-CUDA
        }
    } else {
        Write-Status "No NVIDIA GPU detected - runner will be CPU-only" -Type "WARNING"
    }
    
    # Step 2: Docker
    if (-not $SkipDocker) {
        Install-Docker
    }
    
    # Step 3: GitHub Runner
    $runnerInstalled = Install-GitHubRunner
    
    if (-not $runnerInstalled) {
        Write-Status "Runner setup incomplete" -Type "ERROR"
        $script:ExitCode = 1
        exit $script:ExitCode
    }
    
    # Step 4: AitherNode setup
    if (-not $SkipAitherNode) {
        Install-AitherNode
    }
    
    # Step 5: GitHub secrets
    Set-GitHubSecrets
    
    Write-Status "=== Runner Setup Complete ===" -Type "SUCCESS"
    Write-Status "Runner location: $RunnerDir" -Type "INFO"
    Write-Status "Start runner service: Start-Service actions.runner.*" -Type "INFO"
    
    # Show summary
    if ($ShowOutput) {
        Write-Host ""
        Write-Host "Next Steps:" -ForegroundColor Cyan
        Write-Host "  1. Verify runner at: https://github.com/$Repository/settings/actions/runners" -ForegroundColor White
        Write-Host "  2. Set environment variables: WANDB_API_KEY, HF_TOKEN" -ForegroundColor White
        Write-Host "  3. Run: gh secret set WANDB_API_KEY --body <your-key>" -ForegroundColor White
        Write-Host "  4. Trigger training: gh workflow run training.yml" -ForegroundColor White
    }
    
} catch {
    Write-AitherError -ErrorRecord $_ -Context "GitHubRunner-Setup"
    $script:ExitCode = 1
}

exit $script:ExitCode

#endregion
