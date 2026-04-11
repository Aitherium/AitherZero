#Requires -Version 7.0
<#
.SYNOPSIS
    Auto-detect and install all AitherOS deployment dependencies.

.DESCRIPTION
    Intelligently detects the current platform and installs everything
    needed to deploy AitherOS. Idempotent — safe to run multiple times.
    
    Installs (if missing):
    - Docker / Docker Desktop
    - Docker Compose plugin
    - Git
    - vLLM Docker volumes (for local GPU AI inference)
    - NVIDIA Container Toolkit (if GPU detected)
    
    Skips anything already installed. Reports what was installed vs skipped.

.PARAMETER NonInteractive
    Suppress prompts, auto-accept defaults.

.PARAMETER Force
    Force reinstall even if already present.

.PARAMETER SkipOllama
    Skip Ollama installation.

.PARAMETER SkipGPU
    Skip NVIDIA GPU driver/toolkit detection.

.EXAMPLE
    .\3021_Install-Dependencies.ps1

.NOTES
    Category: deploy
    Dependencies: None (bootstraps itself)
    Platform: Windows, Linux, macOS
    Script: 3021
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$NonInteractive,
    [switch]$Force,
    [switch]$SkipvLLM,
    [switch]$SkipGPU
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. "$PSScriptRoot/../_init.ps1"

$installed = @()
$skipped = @()
$failed = @()

function Test-CommandExists {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Install-WithWinget {
    param([string]$PackageId, [string]$Name)
    if (-not (Test-CommandExists 'winget')) {
        Write-Warning "winget not available - please install $Name manually"
        $script:failed += $Name
        return $false
    }
    Write-Host "    ↓ Installing $Name via winget..." -ForegroundColor Yellow
    $wingetArgs = @('install', '--id', $PackageId, '--accept-package-agreements', '--accept-source-agreements')
    if ($NonInteractive) { $wingetArgs += '--silent' }
    & winget @wingetArgs 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

Write-Host "`n  Dependency Auto-Installer" -ForegroundColor Cyan
Write-Host "  Platform: $($IsWindows ? 'Windows' : ($IsLinux ? 'Linux' : 'macOS'))" -ForegroundColor Gray
Write-Host ""

# ── 1. Git ─────────────────────────────────────────────────────
Write-Host "  [1/5] Git..." -ForegroundColor White
if (Test-CommandExists 'git') {
    $gitVersion = (git --version 2>&1) -replace 'git version\s*', ''
    Write-Host "    ✓ Git $gitVersion" -ForegroundColor Green
    $skipped += 'Git'
}
else {
    if ($IsWindows) {
        Install-WithWinget 'Git.Git' 'Git'
    }
    elseif ($IsLinux) {
        Write-Host "    ↓ Installing Git..." -ForegroundColor Yellow
        if (Test-CommandExists 'apt-get') { sudo apt-get install -y git 2>&1 | Out-Null }
        elseif (Test-CommandExists 'dnf') { sudo dnf install -y git 2>&1 | Out-Null }
        elseif (Test-CommandExists 'yum') { sudo yum install -y git 2>&1 | Out-Null }
    }
    elseif ($IsMacOS) {
        Write-Host "    ↓ Installing Git via Homebrew..." -ForegroundColor Yellow
        brew install git 2>&1 | Out-Null
    }
    if (Test-CommandExists 'git') {
        Write-Host "    ✓ Git installed" -ForegroundColor Green
        $installed += 'Git'
    }
    else {
        Write-Host "    ✗ Git installation failed" -ForegroundColor Red
        $failed += 'Git'
    }
}

# ── 2. Docker ──────────────────────────────────────────────────
Write-Host "  [2/5] Docker..." -ForegroundColor White
if (Test-CommandExists 'docker') {
    try {
        docker info 2>&1 | Out-Null
        $dockerVersion = (docker version --format '{{.Server.Version}}' 2>&1)
        Write-Host "    ✓ Docker $dockerVersion (running)" -ForegroundColor Green
        $skipped += 'Docker'
    }
    catch {
        Write-Host "    ⚠ Docker installed but daemon not running" -ForegroundColor Yellow
        if ($IsWindows) {
            Write-Host "    → Starting Docker Desktop..." -ForegroundColor Gray
            Start-Process "Docker Desktop" -ErrorAction SilentlyContinue
            Write-Host "    → Waiting 30s for Docker to start..." -ForegroundColor Gray
            Start-Sleep -Seconds 30
            try {
                docker info 2>&1 | Out-Null
                Write-Host "    ✓ Docker started" -ForegroundColor Green
                $installed += 'Docker (started)'
            }
            catch {
                Write-Host "    ✗ Docker daemon failed to start" -ForegroundColor Red
                $failed += 'Docker daemon'
            }
        }
        else {
            Write-Host "    → Try: sudo systemctl start docker" -ForegroundColor Gray
            $failed += 'Docker daemon'
        }
    }
}
else {
    if ($IsWindows) {
        $dockerInstalled = Install-WithWinget 'Docker.DockerDesktop' 'Docker Desktop'
        if ($dockerInstalled) {
            Write-Host "    ✓ Docker Desktop installed (restart may be required)" -ForegroundColor Green
            $installed += 'Docker Desktop'
        }
    }
    elseif ($IsLinux) {
        Write-Host "    ↓ Installing Docker via official script..." -ForegroundColor Yellow
        try {
            curl -fsSL https://get.docker.com | sudo bash 2>&1 | Out-Null
            sudo usermod -aG docker $env:USER 2>&1 | Out-Null
            sudo systemctl enable docker 2>&1 | Out-Null
            sudo systemctl start docker 2>&1 | Out-Null
            Write-Host "    ✓ Docker installed and started" -ForegroundColor Green
            $installed += 'Docker'
        }
        catch {
            Write-Host "    ✗ Docker installation failed: $($_.Exception.Message)" -ForegroundColor Red
            $failed += 'Docker'
        }
    }
    elseif ($IsMacOS) {
        $dockerInstalled = $false
        if (Test-CommandExists 'brew') {
            Write-Host "    ↓ Installing Docker via Homebrew..." -ForegroundColor Yellow
            brew install --cask docker 2>&1 | Out-Null
            $dockerInstalled = $?
        }
        if ($dockerInstalled) {
            Write-Host "    ✓ Docker installed (launch Docker.app to start)" -ForegroundColor Green
            $installed += 'Docker'
        }
        else {
            Write-Host "    ✗ Install Docker Desktop from https://docker.com/get-started" -ForegroundColor Red
            $failed += 'Docker'
        }
    }
}

# ── 3. Docker Compose ──────────────────────────────────────────
Write-Host "  [3/5] Docker Compose..." -ForegroundColor White
$composeOk = $false
try {
    $composeVer = docker compose version --short 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    ✓ Docker Compose v$composeVer" -ForegroundColor Green
        $composeOk = $true
        $skipped += 'Docker Compose'
    }
}
catch { }

if (-not $composeOk) {
    if ($IsLinux) {
        Write-Host "    ↓ Installing Docker Compose plugin..." -ForegroundColor Yellow
        try {
            sudo apt-get install -y docker-compose-plugin 2>&1 | Out-Null
            Write-Host "    ✓ Docker Compose installed" -ForegroundColor Green
            $installed += 'Docker Compose'
        }
        catch {
            Write-Host "    ✗ Install docker-compose-plugin manually" -ForegroundColor Red
            $failed += 'Docker Compose'
        }
    }
    else {
        Write-Host "    ⚠ Docker Compose not available — included with Docker Desktop" -ForegroundColor Yellow
    }
}

# ── 4. vLLM Docker Volumes (required for AI inference) ─────────
Write-Host "  [4/5] vLLM Docker Volumes..." -ForegroundColor White
if ($SkipvLLM -or $env:AITHEROS_SKIP_VLLM -eq '1') {
    Write-Host "    ○ Skipped (--SkipvLLM)" -ForegroundColor DarkGray
    $skipped += 'vLLM'
}
elseif (Test-CommandExists 'docker') {
    $requiredVolumes = @('aither-hf-cache', 'aither-vllm-cache')
    $allExist = $true
    foreach ($vol in $requiredVolumes) {
        $exists = docker volume ls -q 2>$null | Where-Object { $_ -eq $vol }
        if (-not $exists) {
            docker volume create --name $vol 2>&1 | Out-Null
            Write-Host "    + Created volume: $vol" -ForegroundColor Yellow
            $allExist = $false
        }
    }
    if ($allExist) {
        Write-Host "    ✓ vLLM Docker volumes ready" -ForegroundColor Green
        $skipped += 'vLLM volumes'
    } else {
        Write-Host "    ✓ vLLM Docker volumes created" -ForegroundColor Green
        $installed += 'vLLM volumes'
    }
    Write-Host "    → Start vLLM: docker compose -f docker-compose.vllm-multimodel.yml up -d" -ForegroundColor Gray
}
else {
    Write-Host "    ○ Docker not available — vLLM volumes skipped" -ForegroundColor DarkGray
    $skipped += 'vLLM (no Docker)'
}

# ── 5. NVIDIA GPU ──────────────────────────────────────────────
Write-Host "  [5/5] GPU Detection..." -ForegroundColor White
if ($SkipGPU) {
    Write-Host "    ○ Skipped (--SkipGPU)" -ForegroundColor DarkGray
    $skipped += 'GPU'
}
else {
    $hasGPU = $false
    try {
        if (Test-CommandExists 'nvidia-smi') {
            $gpuInfo = nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>&1
            if ($LASTEXITCODE -eq 0 -and $gpuInfo) {
                Write-Host "    ✓ NVIDIA GPU: $($gpuInfo.Trim())" -ForegroundColor Green
                $hasGPU = $true

                # Check NVIDIA Container Toolkit
                if ($IsLinux) {
                    $nctCheck = docker run --rm --gpus all nvidia/cuda:12.2.2-base-ubuntu22.04 nvidia-smi 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    ✓ NVIDIA Container Toolkit ready" -ForegroundColor Green
                    }
                    else {
                        Write-Host "    ⚠ NVIDIA Container Toolkit not configured" -ForegroundColor Yellow
                        Write-Host "    → Install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html" -ForegroundColor Gray
                    }
                }
            }
        }
    }
    catch { }

    if (-not $hasGPU) {
        Write-Host "    ○ No NVIDIA GPU detected (CPU-only mode)" -ForegroundColor DarkGray
        $skipped += 'GPU'
    }
}

# ── Summary ────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray
if ($installed.Count -gt 0) {
    Write-Host "  Installed: $($installed -join ', ')" -ForegroundColor Green
}
if ($skipped.Count -gt 0) {
    Write-Host "  Skipped:   $($skipped -join ', ')" -ForegroundColor DarkGray
}
if ($failed.Count -gt 0) {
    Write-Host "  Failed:    $($failed -join ', ')" -ForegroundColor Red
    if ('Docker' -in $failed -or 'Docker daemon' -in $failed) {
        throw "Docker is required for AitherOS deployment. Please install Docker and retry."
    }
}
Write-Host ""
