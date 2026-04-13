#Requires -Version 7.0

<#
.SYNOPSIS
    Install the Windows Assessment and Deployment Kit (ADK) for ISO building.

.DESCRIPTION
    Installs Windows ADK and optional WinPE addons using winget, Chocolatey, or
    direct download. The ADK provides oscdimg.exe which is required by the
    AitherOS ISO builder (3105_Build-WindowsISO.ps1).

    The script is idempotent — it detects existing installations and exits early.

    Install methods tried in order:
      1. winget (preferred — non-interactive, no reboot)
      2. Chocolatey (if winget unavailable)
      3. Direct download from Microsoft (fallback)

.PARAMETER IncludeWinPE
    Also install ADK Windows PE Addons (needed for PXE boot media).

.PARAMETER InstallPath
    Custom installation path. Default: standard ADK location.

.PARAMETER Force
    Re-install even if already detected.

.EXAMPLE
    .\0101_Install-WindowsADK.ps1
    Installs Windows ADK with default options.

.EXAMPLE
    .\0101_Install-WindowsADK.ps1 -IncludeWinPE -Force
    Force-installs ADK and WinPE addons.

.NOTES
    Category:     infrastructure
    Dependencies: None
    Platform:     Windows
    Exit Codes:   0 = success, 1 = failure, 200 = restart needed
#>

[CmdletBinding()]
param(
    [switch]$IncludeWinPE,
    [string]$InstallPath,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
# Platform guard
# ─────────────────────────────────────────────
if (-not $IsWindows) {
    Write-Host "[SKIP] Windows ADK is only available on Windows." -ForegroundColor Yellow
    exit 0
}

# ─────────────────────────────────────────────
# Check if already installed
# ─────────────────────────────────────────────
function Find-Oscdimg {
    # Check env override first
    if ($env:OSCDIMG_PATH -and (Test-Path $env:OSCDIMG_PATH)) {
        return $env:OSCDIMG_PATH
    }
    # Standard locations
    $paths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$existingOscdimg = Find-Oscdimg
if ($existingOscdimg -and -not $Force) {
    Write-Host "[OK] Windows ADK already installed. oscdimg.exe: $existingOscdimg" -ForegroundColor Green
    exit 0
}

# ─────────────────────────────────────────────
# Admin check
# ─────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "[!] Windows ADK installation requires Administrator privileges." -ForegroundColor Red
    Write-Host "    Please run this script in an elevated PowerShell session." -ForegroundColor Yellow
    exit 1
}

Write-Host "`n════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Installing Windows ADK" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════`n" -ForegroundColor Cyan

$installed = $false

# ─────────────────────────────────────────────
# Method 1: winget
# ─────────────────────────────────────────────
if (-not $installed -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "  [1/3] Trying winget..." -ForegroundColor Yellow

    try {
        $wingetArgs = @('install', '--id', 'Microsoft.WindowsADK', '--accept-source-agreements', '--accept-package-agreements', '--silent')
        if ($InstallPath) { $wingetArgs += @('--location', $InstallPath) }

        Write-Host "    winget install Microsoft.WindowsADK" -ForegroundColor Gray
        $output = & winget @wingetArgs 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $output -match 'already installed') {
            Write-Host "    ADK core installed via winget" -ForegroundColor Green
            $installed = $true

            if ($IncludeWinPE) {
                Write-Host "    Installing WinPE addons..." -ForegroundColor Gray
                $peArgs = @('install', '--id', 'Microsoft.ADKPEAddon', '--accept-source-agreements', '--accept-package-agreements', '--silent')
                $peOutput = & winget @peArgs 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0 -and $peOutput -notmatch 'already installed') {
                    Write-Warning "    WinPE addon install returned non-zero: $LASTEXITCODE"
                }
            }
        }
        else {
            Write-Host "    winget returned $LASTEXITCODE — trying next method" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "    winget failed: $($_.Exception.Message)" -ForegroundColor Gray
    }
}

# ─────────────────────────────────────────────
# Method 2: Chocolatey
# ─────────────────────────────────────────────
if (-not $installed -and (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "  [2/3] Trying Chocolatey..." -ForegroundColor Yellow

    try {
        $chocoArgs = @('install', 'windows-adk-deploy', '-y', '--no-progress')
        Write-Host "    choco install windows-adk-deploy" -ForegroundColor Gray
        & choco @chocoArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    ADK installed via Chocolatey" -ForegroundColor Green
            $installed = $true

            if ($IncludeWinPE) {
                & choco install windows-adk-winpe -y --no-progress 2>&1 | Out-Null
            }
        }
        else {
            Write-Host "    choco returned $LASTEXITCODE — trying next method" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "    Chocolatey failed: $($_.Exception.Message)" -ForegroundColor Gray
    }
}

# ─────────────────────────────────────────────
# Method 3: Direct download
# ─────────────────────────────────────────────
if (-not $installed) {
    Write-Host "  [3/3] Trying direct download..." -ForegroundColor Yellow

    $adkUrl = 'https://go.microsoft.com/fwlink/?linkid=2243390'  # ADK for Windows 11 / Server 2025
    $tempDir = Join-Path $env:TEMP "adk_install_$(Get-Random)"
    $adkSetup = Join-Path $tempDir 'adksetup.exe'

    try {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

        Write-Host "    Downloading ADK installer..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $adkUrl -OutFile $adkSetup -UseBasicParsing -ErrorAction Stop

        # Install Deployment Tools feature only (contains oscdimg)
        $installArgs = @('/quiet', '/norestart', '/features', 'OptionId.DeploymentTools')
        if ($InstallPath) { $installArgs += @('/installpath', $InstallPath) }

        Write-Host "    Running ADK setup (Deployment Tools feature)..." -ForegroundColor Gray
        $proc = Start-Process -FilePath $adkSetup -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Host "    ADK installed via direct download" -ForegroundColor Green
            $installed = $true

            if ($proc.ExitCode -eq 3010) {
                Write-Host "    [!] System restart may be required." -ForegroundColor Yellow
            }

            if ($IncludeWinPE) {
                $peUrl = 'https://go.microsoft.com/fwlink/?linkid=2243391'
                $peSetup = Join-Path $tempDir 'adkwinpesetup.exe'
                Write-Host "    Downloading WinPE addon..." -ForegroundColor Gray
                Invoke-WebRequest -Uri $peUrl -OutFile $peSetup -UseBasicParsing -ErrorAction Stop
                $peProc = Start-Process -FilePath $peSetup -ArgumentList '/quiet', '/norestart' -Wait -PassThru -NoNewWindow
                if ($peProc.ExitCode -ne 0 -and $peProc.ExitCode -ne 3010) {
                    Write-Warning "    WinPE addon returned exit code: $($peProc.ExitCode)"
                }
            }
        }
        else {
            Write-Host "    ADK setup returned: $($proc.ExitCode)" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "    Direct download failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─────────────────────────────────────────────
# Verify
# ─────────────────────────────────────────────
$finalCheck = Find-Oscdimg
if ($finalCheck) {
    Write-Host "`n  [OK] Windows ADK ready. oscdimg.exe: $finalCheck" -ForegroundColor Green
    # Set env for current session
    $env:OSCDIMG_PATH = $finalCheck
    exit 0
}
else {
    Write-Host "`n  [FAIL] Windows ADK installation could not be verified." -ForegroundColor Red
    Write-Host "  Try manual installation:" -ForegroundColor Yellow
    Write-Host "    winget install Microsoft.WindowsADK" -ForegroundColor Yellow
    Write-Host "    winget install Microsoft.ADKPEAddon" -ForegroundColor Yellow
    exit 1
}
