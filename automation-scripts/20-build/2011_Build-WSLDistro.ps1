#Requires -Version 7.0
<#
.SYNOPSIS
    Builds and installs the AitherOS WSL distribution.

.DESCRIPTION
    Automates the full AitherOS WSL distro lifecycle:
      1. Builds a Docker image (Ubuntu 24.04 + Python + PowerShell + Node + all deps)
      2. Exports the rootfs tarball
      3. Imports into WSL as "AitherOS"
      4. Configures default user, Docker access, shell environment

    The distro includes everything needed to develop and run AitherOS services
    natively in Linux without manually installing dependencies.

.PARAMETER Action
    What to do:
      install    - Full build + import (default)
      build      - Build Docker image only (no WSL import)
      rebuild    - Unregister existing distro, then install fresh
      uninstall  - Remove the AitherOS WSL distro
      status     - Show current distro status
      shell      - Launch a shell in the distro
      update     - Rebuild image and re-import (preserves nothing)

.PARAMETER InstallPath
    Where to store the WSL virtual disk. Default: C:\WSL\AitherOS

.PARAMETER MountSource
    Symlink /opt/aitheros to the Windows source tree instead of copying.
    Enables live editing from Windows but with slower filesystem I/O.

.PARAMETER NoCache
    Force a full Docker rebuild without cache.

.PARAMETER Tag
    Docker image tag. Default: "latest"

.PARAMETER SetDefault
    Set AitherOS as the default WSL distribution.

.EXAMPLE
    .\2011_Build-WSLDistro.ps1
    # Full build + install

.EXAMPLE
    .\2011_Build-WSLDistro.ps1 -Action rebuild
    # Remove old distro and reinstall

.EXAMPLE
    .\2011_Build-WSLDistro.ps1 -Action build
    # Build the Docker image only (no WSL import)

.EXAMPLE
    .\2011_Build-WSLDistro.ps1 -MountSource
    # Install with live Windows source mount

.EXAMPLE
    .\2011_Build-WSLDistro.ps1 -Action status
    # Show distro info

.EXAMPLE
    .\2011_Build-WSLDistro.ps1 -Action uninstall
    # Remove the AitherOS distro completely

.NOTES
    Category: build
    Dependencies: Docker Desktop, WSL2
    Platform: Windows
#>

[CmdletBinding()]
param(
    [ValidateSet("install", "build", "rebuild", "uninstall", "status", "shell", "update")]
    [string]$Action = "install",

    [string]$InstallPath = "C:\WSL\AitherOS",

    [switch]$MountSource,

    [switch]$NoCache,

    [string]$Tag = "latest",

    [switch]$SetDefault
)

$ErrorActionPreference = 'Stop'

# ── Resolve workspace root ──────────────────────────────────────────────────
. "$PSScriptRoot/../_init.ps1"

$distroName    = "AitherOS"
$imageName     = "aitheros-wsl"
$fullImageName = "${imageName}:${Tag}"
$dockerfilePath = Join-Path $projectRoot "wsl" "Dockerfile.wsl"
$tarPath       = Join-Path $projectRoot "wsl" "aitheros-rootfs.tar"

# ── Banner ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Magenta
Write-Host "  ⬡ AitherOS WSL Distribution Builder" -ForegroundColor Magenta
Write-Host ("=" * 60) -ForegroundColor Magenta
Write-Host ""

# ── Helper functions ────────────────────────────────────────────────────────
function Test-DistroExists {
    $distros = (wsl --list --quiet 2>&1) -split "`n" | ForEach-Object { $_.Trim().TrimEnd("`0") } | Where-Object { $_ }
    return ($distros -contains $distroName)
}

function Test-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Error "Docker is not installed. Install Docker Desktop first."
        exit 1
    }
    try {
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "not running" }
    } catch {
        Write-Error "Docker daemon is not running. Start Docker Desktop."
        exit 1
    }
}

function Test-WslReady {
    try {
        $ver = wsl --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "no wsl" }
    } catch {
        Write-Error "WSL is not installed. Run: wsl --install"
        exit 1
    }
}

function Show-Status {
    Write-Host "  Distro:    " -NoNewline -ForegroundColor Gray
    if (Test-DistroExists) {
        Write-Host "$distroName (installed)" -ForegroundColor Green
        
        Write-Host "  Install:   $InstallPath" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Environment:" -ForegroundColor Yellow
        
        $info = wsl -d $distroName -- bash -c "
            echo \"  user:    \$(whoami)\"
            echo \"  python:  \$(python3 --version 2>/dev/null || echo missing)\"
            echo \"  pwsh:    \$(pwsh --version 2>/dev/null || echo missing)\"
            echo \"  node:    \$(node --version 2>/dev/null || echo missing)\"
            echo \"  docker:  \$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo 'not connected')\"
            echo \"  source:  \$(ls /opt/aitheros/AitherZero/AitherZero.psd1 2>/dev/null && echo present || echo missing)\"
            echo \"  venv:    \$(test -f /opt/aitheros/.venv/bin/python && echo active || echo missing)\"
        " 2>&1
        $info | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
    } else {
        Write-Host "Not installed" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Image:     " -NoNewline -ForegroundColor Gray
    $imageId = docker images -q $fullImageName 2>$null
    if ($imageId) {
        $imageSize = docker images --format "{{.Size}}" $fullImageName
        Write-Host "$fullImageName ($imageSize)" -ForegroundColor Green
    } else {
        Write-Host "Not built" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Invoke-Build {
    Test-DockerReady

    Write-Host "  Action:    Build Docker image" -ForegroundColor Yellow
    Write-Host "  Image:     $fullImageName" -ForegroundColor Gray
    Write-Host "  Dockerfile: wsl/Dockerfile.wsl" -ForegroundColor Gray
    Write-Host "  Context:   $projectRoot" -ForegroundColor Gray
    Write-Host "  NoCache:   $NoCache" -ForegroundColor Gray
    Write-Host ""

    if (-not (Test-Path $dockerfilePath)) {
        Write-Error "Dockerfile not found: $dockerfilePath"
        exit 1
    }

    $buildArgs = @(
        "build"
        "--file", $dockerfilePath
        "--tag", $fullImageName
        "--progress", "plain"
    )

    if ($NoCache) {
        $buildArgs += "--no-cache"
    }

    $buildArgs += $projectRoot

    Write-Host "  docker $($buildArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host ""

    & docker @buildArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker build failed"
        exit 1
    }

    Write-Host ""
    Write-Host "  ✓ Image built: $fullImageName" -ForegroundColor Green

    $imageSize = docker images --format "{{.Size}}" $fullImageName
    Write-Host "  ✓ Size: $imageSize" -ForegroundColor Green
    Write-Host ""
}

function Invoke-Export {
    $containerName = "aitheros-wsl-export"

    Write-Host "  Exporting rootfs tarball..." -ForegroundColor Yellow
    
    # Cleanup stale container
    docker rm -f $containerName 2>$null | Out-Null

    docker create --name $containerName $fullImageName | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create export container"; exit 1 }

    docker export $containerName -o $tarPath
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to export rootfs"; exit 1 }

    docker rm -f $containerName | Out-Null

    $sizeMB = [math]::Round((Get-Item $tarPath).Length / 1MB, 0)
    Write-Host "  ✓ Exported: wsl/aitheros-rootfs.tar ($sizeMB MB)" -ForegroundColor Green
    Write-Host ""
}

function Invoke-Import {
    Test-WslReady

    Write-Host "  Importing into WSL as '$distroName'..." -ForegroundColor Yellow

    if (-not (Test-Path $InstallPath)) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    }

    wsl --import $distroName $InstallPath $tarPath
    if ($LASTEXITCODE -ne 0) { Write-Error "WSL import failed"; exit 1 }

    Write-Host "  ✓ Imported to $InstallPath" -ForegroundColor Green
    Write-Host ""
}

function Invoke-PostConfig {
    Write-Host "  Configuring distro..." -ForegroundColor Yellow

    # Ensure docker group and user membership
    wsl -d $distroName -- bash -c "
        getent group docker >/dev/null 2>&1 || sudo groupadd docker
        sudo usermod -aG docker aither 2>/dev/null || true
    "

    # If MountSource, symlink Windows source
    if ($MountSource) {
        $winPath = $projectRoot -replace '\\', '/'
        $driveLetter = $winPath.Substring(0, 1).ToLower()
        $wslPath = "/mnt/$driveLetter$($winPath.Substring(2))"

        Write-Host "  Mounting source: /opt/aitheros → $wslPath" -ForegroundColor Yellow
        wsl -d $distroName -- bash -c "
            sudo rm -rf /opt/aitheros
            sudo ln -s '$wslPath' /opt/aitheros
            sudo chown -h aither:aither /opt/aitheros
        "
        Write-Host "  ✓ Source mounted (live edits from Windows)" -ForegroundColor Green
    }

    if ($SetDefault) {
        wsl --set-default $distroName
        Write-Host "  ✓ Set as default WSL distro" -ForegroundColor Green
    }

    Write-Host "  ✓ Configuration complete" -ForegroundColor Green
    Write-Host ""
}

function Invoke-Uninstall {
    if (Test-DistroExists) {
        Write-Host "  Unregistering $distroName..." -ForegroundColor Yellow
        wsl --unregister $distroName
        Write-Host "  ✓ Distro removed" -ForegroundColor Green

        if (Test-Path $InstallPath) {
            Remove-Item -Recurse -Force $InstallPath
            Write-Host "  ✓ Install path removed: $InstallPath" -ForegroundColor Green
        }
    } else {
        Write-Host "  $distroName is not installed" -ForegroundColor Yellow
    }

    # Cleanup tarball if exists
    if (Test-Path $tarPath) {
        Remove-Item -Force $tarPath
    }
    Write-Host ""
}

function Show-Summary {
    Write-Host ("=" * 60) -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  ⬡ AitherOS WSL is ready!" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Launch:         " -NoNewline; Write-Host "wsl -d AitherOS" -ForegroundColor White
    Write-Host "  PowerShell:     " -NoNewline; Write-Host "wsl -d AitherOS pwsh" -ForegroundColor White
    Write-Host "  VS Code:        " -NoNewline; Write-Host "code --remote wsl+AitherOS /opt/aitheros" -ForegroundColor White
    Write-Host "  Start services: " -NoNewline; Write-Host "wsl -d AitherOS -- dstart" -ForegroundColor White
    Write-Host ""
    Write-Host "  ⚠  Enable Docker WSL integration for AitherOS in:" -ForegroundColor Yellow
    Write-Host "     Docker Desktop → Settings → Resources → WSL Integration" -ForegroundColor Gray
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Magenta
    Write-Host ""
}

# ── Action dispatch ─────────────────────────────────────────────────────────

switch ($Action) {
    "status" {
        Show-Status
    }

    "build" {
        Invoke-Build
    }

    "install" {
        if (Test-DistroExists) {
            Write-Host "  $distroName already exists." -ForegroundColor Cyan
            Write-Host "  Use -Action rebuild to replace, or -Action status to inspect." -ForegroundColor Gray
            Write-Host ""
            exit 0
        }
        Invoke-Build
        Invoke-Export
        Invoke-Import
        Invoke-PostConfig
        # Cleanup tarball
        if (Test-Path $tarPath) { Remove-Item -Force $tarPath }
        Show-Summary
    }

    "rebuild" {
        Invoke-Uninstall
        Invoke-Build
        Invoke-Export
        Invoke-Import
        Invoke-PostConfig
        if (Test-Path $tarPath) { Remove-Item -Force $tarPath }
        Show-Summary
    }

    "update" {
        if (Test-DistroExists) {
            Write-Host "  Removing old distro for update..." -ForegroundColor Yellow
            wsl --unregister $distroName
        }
        Invoke-Build
        Invoke-Export
        Invoke-Import
        Invoke-PostConfig
        if (Test-Path $tarPath) { Remove-Item -Force $tarPath }
        Show-Summary
    }

    "uninstall" {
        Invoke-Uninstall
        Write-Host "  ⬡ AitherOS WSL has been removed." -ForegroundColor Magenta
        Write-Host ""
    }

    "shell" {
        if (-not (Test-DistroExists)) {
            Write-Error "$distroName is not installed. Run with -Action install first."
            exit 1
        }
        wsl -d $distroName
    }
}

exit 0
