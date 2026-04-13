#Requires -Version 7.0
<#
.SYNOPSIS
    Installs and configures a GitHub Actions self-hosted runner as a Windows service.

.DESCRIPTION
    Downloads the latest GitHub Actions runner, configures it for the AitherOS
    repository, and installs it as a Windows service for automatic CD deployments.

.PARAMETER Token
    GitHub runner registration token. If omitted, attempts to generate one via `gh auth token`.

.PARAMETER RunnerName
    Display name for the runner. Default: hostname.

.PARAMETER Labels
    Comma-separated labels. Default: "self-hosted,windows,aitheros-local,gpu"

.PARAMETER InstallPath
    Installation directory. Default: "D:\actions-runner"

.PARAMETER RepoUrl
    Repository URL. Default: https://github.com/Aitherium/AitherOS

.PARAMETER Uninstall
    Remove the runner service and configuration.

.EXAMPLE
    .\3045_Setup-GitHubRunner.ps1
    .\3045_Setup-GitHubRunner.ps1 -Token "AXXXXXXX" -RunnerName "aitheros-prod"
    .\3045_Setup-GitHubRunner.ps1 -Uninstall

.NOTES
    Category: deploy
    Dependencies: gh CLI (for token generation), Docker Desktop
    Platform: Windows
#>

[CmdletBinding()]
param(
    [string]$Token,
    [string]$RunnerName = $env:COMPUTERNAME,
    [string]$Labels = "self-hosted,windows,aitheros-local,gpu",
    [string]$InstallPath = "D:\actions-runner",
    [string]$RepoUrl = "https://github.com/Aitherium/AitherOS",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  GitHub Actions Self-Hosted Runner Setup" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# UNINSTALL
# =============================================================================
if ($Uninstall) {
    if (-not (Test-Path $InstallPath)) {
        Write-Warning "Runner not found at $InstallPath"
        return
    }
    try {
        $svcName = "actions.runner.Aitherium-AitherOS.$RunnerName"
        Write-Host "Stopping runner service..." -ForegroundColor Yellow
        & sc.exe stop $svcName 2>$null
        Start-Sleep -Seconds 2
        Write-Host "Removing runner service..." -ForegroundColor Yellow
        & sc.exe delete $svcName 2>$null
    } catch {
        Write-Warning "Service removal issue: $_"
    }
    Push-Location $InstallPath
    try {
        Write-Host "Removing runner configuration..." -ForegroundColor Yellow
        & .\config.cmd remove --token (gh api -X POST repos/Aitherium/AitherOS/actions/runners/registration-token --jq .token)
        Write-Host "Runner uninstalled." -ForegroundColor Green
    } finally {
        Pop-Location
    }
    return
}

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host "Checking prerequisites..." -ForegroundColor Yellow

# Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker Desktop is required. Install from https://docker.com/products/docker-desktop"
}
$dockerInfo = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker Desktop is not running. Start it first."
}
Write-Host "  Docker: OK" -ForegroundColor Green

# PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "PowerShell 7+ is required. Current: $($PSVersionTable.PSVersion)"
}
Write-Host "  PowerShell: $($PSVersionTable.PSVersion)" -ForegroundColor Green

# gh CLI
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "GitHub CLI (gh) is required. Install: winget install GitHub.cli"
}
Write-Host "  GitHub CLI: OK" -ForegroundColor Green

# NVIDIA GPU (optional)
$hasGpu = $false
try {
    $null = nvidia-smi 2>$null
    if ($LASTEXITCODE -eq 0) { $hasGpu = $true }
} catch {}
if ($hasGpu) {
    Write-Host "  NVIDIA GPU: detected" -ForegroundColor Green
} else {
    Write-Host "  NVIDIA GPU: not detected (removing gpu label)" -ForegroundColor Yellow
    $Labels = $Labels -replace ',gpu', ''
}

# =============================================================================
# GET REGISTRATION TOKEN
# =============================================================================
if (-not $Token) {
    Write-Host ""
    Write-Host "Generating registration token via gh CLI..." -ForegroundColor Yellow
    try {
        $Token = gh api -X POST repos/Aitherium/AitherOS/actions/runners/registration-token --jq .token
        if (-not $Token -or $Token.Length -lt 10) {
            throw "Empty token returned"
        }
        Write-Host "  Token acquired (${($Token.Substring(0,6))}...)" -ForegroundColor Green
    } catch {
        Write-Error "Failed to get registration token. Run 'gh auth login' first, or pass -Token manually."
    }
}

# =============================================================================
# DOWNLOAD RUNNER
# =============================================================================
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

$configCmd = Join-Path $InstallPath "config.cmd"
if (-not (Test-Path $configCmd)) {
    Write-Host ""
    Write-Host "Downloading latest GitHub Actions runner..." -ForegroundColor Yellow

    # Get latest release URL
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest"
    $asset = $releases.assets | Where-Object { $_.name -match 'actions-runner-win-x64-[\d.]+\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        Write-Error "Could not find Windows x64 runner asset"
    }

    $zipPath = Join-Path $env:TEMP "actions-runner.zip"
    Write-Host "  Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath

    Write-Host "  Extracting to $InstallPath..."
    Expand-Archive -Path $zipPath -DestinationPath $InstallPath -Force
    Remove-Item $zipPath -Force

    Write-Host "  Runner downloaded." -ForegroundColor Green
} else {
    Write-Host "Runner already exists at $InstallPath" -ForegroundColor Green
}

# =============================================================================
# CONFIGURE RUNNER
# =============================================================================
$runsvcCmd = Join-Path $InstallPath ".runner"
if (-not (Test-Path $runsvcCmd)) {
    Write-Host ""
    Write-Host "Configuring runner..." -ForegroundColor Yellow
    Write-Host "  Name:   $RunnerName"
    Write-Host "  Labels: $Labels"
    Write-Host "  Repo:   $RepoUrl"

    Push-Location $InstallPath
    try {
        & .\config.cmd `
            --url $RepoUrl `
            --token $Token `
            --name $RunnerName `
            --labels $Labels `
            --work "_work" `
            --runasservice `
            --replace `
            --unattended
        if ($LASTEXITCODE -ne 0) {
            throw "Runner configuration failed (exit code $LASTEXITCODE)"
        }
        Write-Host "  Runner configured." -ForegroundColor Green
    } finally {
        Pop-Location
    }
} else {
    Write-Host "Runner already configured." -ForegroundColor Green
}

# =============================================================================
# INSTALL AND START SERVICE
# =============================================================================
Write-Host ""
Write-Host "Installing Windows service..." -ForegroundColor Yellow

$svcName = "actions.runner.Aitherium-AitherOS.$RunnerName"
$exePath = Join-Path $InstallPath "bin\RunnerService.exe"

try {
    # Create Windows service using sc.exe (requires admin)
    $result = & sc.exe create $svcName binPath= "`"$exePath`"" start= auto displayname= "GitHub Actions Runner (AitherOS)"
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe create failed: $result"
    }
    & sc.exe description $svcName "GitHub Actions self-hosted runner for Aitherium/AitherOS"
    & sc.exe start $svcName
    Start-Sleep -Seconds 3
    $status = & sc.exe query $svcName | Select-String "STATE"
    Write-Host "  Service status: $status" -ForegroundColor Green
} catch {
    Write-Warning "Service setup issue: $_. You may need to run as Administrator."
    Write-Host "  Alternative: start the runner manually with: cd $InstallPath && .\run.cmd" -ForegroundColor Yellow
}

# =============================================================================
# VERIFY
# =============================================================================
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "  Self-Hosted Runner Setup Complete" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "  Install path: $InstallPath"
Write-Host "  Runner name:  $RunnerName"
Write-Host "  Labels:       $Labels"
Write-Host ""
Write-Host "  Verify in GitHub: Settings > Actions > Runners"
Write-Host "  The runner should appear as 'Idle' within 30 seconds."
Write-Host ""
Write-Host "  To manage:" -ForegroundColor Yellow
Write-Host "    Start:     sc.exe start actions.runner.Aitherium-AitherOS.$RunnerName"
Write-Host "    Stop:      sc.exe stop actions.runner.Aitherium-AitherOS.$RunnerName"
Write-Host "    Status:    sc.exe query actions.runner.Aitherium-AitherOS.$RunnerName"
Write-Host "    Manual:    cd $InstallPath && .\run.cmd"
Write-Host "    Uninstall: .\3045_Setup-GitHubRunner.ps1 -Uninstall"
Write-Host ""
