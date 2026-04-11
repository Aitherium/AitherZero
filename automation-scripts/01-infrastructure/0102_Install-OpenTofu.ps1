#Requires -Version 7.0

<#
.SYNOPSIS
    Install OpenTofu — the open-source infrastructure-as-code tool.

.DESCRIPTION
    Installs OpenTofu (>= 1.6.0) using the best available method:
      1. winget (Windows, preferred)
      2. Chocolatey (Windows fallback)
      3. Official install script (Linux/macOS)
      4. Direct binary download (universal fallback)

    Also installs the Taliesin Hyper-V provider plugin if -IncludeHyperVProvider is set.

    Idempotent — detects existing installations and exits early.

.PARAMETER Version
    Specific version to install. Default: 'latest'.

.PARAMETER IncludeHyperVProvider
    Also install the taliesins/hyperv OpenTofu provider after OpenTofu is installed.

.PARAMETER Force
    Re-install even if already detected.

.EXAMPLE
    .\0102_Install-OpenTofu.ps1
    Installs the latest version of OpenTofu.

.EXAMPLE
    .\0102_Install-OpenTofu.ps1 -IncludeHyperVProvider
    Installs OpenTofu and pre-fetches the Hyper-V provider.

.NOTES
    Category:     infrastructure
    Dependencies: None
    Platform:     Windows, Linux, macOS
    Exit Codes:   0 = success, 1 = failure
#>

[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [switch]$IncludeHyperVProvider,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
# Check if already installed
# ─────────────────────────────────────────────
function Test-OpenTofuInstalled {
    $cmd = Get-Command tofu -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $ver = & tofu version -json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            return @{ Installed = $true; Version = $ver.terraform_version; Path = $cmd.Source }
        }
        catch {
            return @{ Installed = $true; Version = 'unknown'; Path = $cmd.Source }
        }
    }
    # Also check terraform as fallback
    $tfCmd = Get-Command terraform -ErrorAction SilentlyContinue
    if ($tfCmd) {
        return @{ Installed = $true; Version = 'terraform'; Path = $tfCmd.Source }
    }
    return @{ Installed = $false; Version = $null; Path = $null }
}

$existing = Test-OpenTofuInstalled
if ($existing.Installed -and -not $Force) {
    Write-Host "[OK] OpenTofu already installed: v$($existing.Version) at $($existing.Path)" -ForegroundColor Green
    # Still install provider if requested
    if ($IncludeHyperVProvider) {
        # Jump to provider install section
    }
    else {
        exit 0
    }
}

if (-not $existing.Installed -or $Force) {
    Write-Host "`n════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Installing OpenTofu" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════`n" -ForegroundColor Cyan

    $installed = $false

    # ─────────────────────────────────────────────
    # Windows: winget
    # ─────────────────────────────────────────────
    if ($IsWindows -and -not $installed -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  [1/4] Trying winget..." -ForegroundColor Yellow
        try {
            $wingetArgs = @('install', '--id', 'OpenTofu.OpenTofu', '--accept-source-agreements', '--accept-package-agreements', '--silent')
            if ($Version -ne 'latest') { $wingetArgs += @('--version', $Version) }
            $output = & winget @wingetArgs 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -or $output -match 'already installed') {
                $installed = $true
                Write-Host "    OpenTofu installed via winget" -ForegroundColor Green

                # Refresh PATH for current session
                $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
                $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
                $env:PATH = "$machinePath;$userPath"
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
    # Windows: Chocolatey
    # ─────────────────────────────────────────────
    if ($IsWindows -and -not $installed -and (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host "  [2/4] Trying Chocolatey..." -ForegroundColor Yellow
        try {
            $chocoArgs = @('install', 'opentofu', '-y', '--no-progress')
            if ($Version -ne 'latest') { $chocoArgs += @('--version', $Version) }
            & choco @chocoArgs 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
                Write-Host "    OpenTofu installed via Chocolatey" -ForegroundColor Green
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
    # Linux/macOS: official install script
    # ─────────────────────────────────────────────
    if (-not $IsWindows -and -not $installed) {
        Write-Host "  [3/4] Trying official install script..." -ForegroundColor Yellow
        try {
            # OpenTofu official installer
            $installScript = Invoke-RestMethod -Uri 'https://get.opentofu.org/install-opentofu.sh' -ErrorAction Stop
            $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "install-opentofu-$(Get-Random).sh"
            $installScript | Set-Content $tempScript -Encoding UTF8
            chmod +x $tempScript 2>$null

            $methodArgs = @($tempScript, '--install-method', 'standalone')
            if ($Version -ne 'latest') { $methodArgs += @('--opentofu-version', $Version) }

            & bash @methodArgs 2>&1 | Out-String | Write-Host
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
                Write-Host "    OpenTofu installed via official script" -ForegroundColor Green
            }

            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "    Official script failed: $($_.Exception.Message)" -ForegroundColor Gray
        }
    }

    # ─────────────────────────────────────────────
    # Universal: direct binary download
    # ─────────────────────────────────────────────
    if (-not $installed) {
        Write-Host "  [4/4] Trying direct binary download..." -ForegroundColor Yellow
        try {
            # Determine platform and architecture
            $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
            $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
            $ext = if ($IsWindows) { 'zip' } else { 'tar.gz' }

            # Get latest version if needed
            if ($Version -eq 'latest') {
                $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/opentofu/opentofu/releases/latest' -ErrorAction Stop
                $Version = $releases.tag_name -replace '^v', ''
            }

            $downloadUrl = "https://github.com/opentofu/opentofu/releases/download/v${Version}/tofu_${Version}_${os}_${arch}.${ext}"
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "tofu_install_$(Get-Random)"
            $downloadFile = Join-Path $tempDir "tofu.${ext}"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            Write-Host "    Downloading: $downloadUrl" -ForegroundColor Gray
            Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadFile -UseBasicParsing -ErrorAction Stop

            # Extract and install
            $installDir = if ($IsWindows) { Join-Path $env:ProgramFiles 'OpenTofu' } else { '/usr/local/bin' }

            if ($IsWindows) {
                if (-not (Test-Path $installDir)) { New-Item -Path $installDir -ItemType Directory -Force | Out-Null }
                Expand-Archive -Path $downloadFile -DestinationPath $installDir -Force

                # Add to PATH if not already there
                $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
                if ($machinePath -notlike "*$installDir*") {
                    [Environment]::SetEnvironmentVariable('PATH', "$machinePath;$installDir", 'Machine')
                    $env:PATH = "$env:PATH;$installDir"
                    Write-Host "    Added $installDir to system PATH" -ForegroundColor Gray
                }
            }
            else {
                $extractDir = Join-Path $tempDir 'extract'
                New-Item -Path $extractDir -ItemType Directory -Force | Out-Null
                tar -xzf $downloadFile -C $extractDir 2>&1 | Out-Null
                $tofuBin = Get-ChildItem -Path $extractDir -Filter 'tofu' -Recurse | Select-Object -First 1
                if ($tofuBin) {
                    Copy-Item $tofuBin.FullName $installDir -Force
                    chmod +x (Join-Path $installDir 'tofu') 2>$null
                }
            }

            $installed = $true
            Write-Host "    OpenTofu $Version installed to $installDir" -ForegroundColor Green

            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "    Direct download failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # ─────────────────────────────────────────────
    # Verify
    # ─────────────────────────────────────────────
    $check = Test-OpenTofuInstalled
    if ($check.Installed) {
        Write-Host "`n  [OK] OpenTofu ready: v$($check.Version) at $($check.Path)" -ForegroundColor Green
    }
    else {
        Write-Host "`n  [FAIL] OpenTofu could not be verified after installation." -ForegroundColor Red
        Write-Host "  Try: winget install OpenTofu.OpenTofu" -ForegroundColor Yellow
        exit 1
    }
}

# ─────────────────────────────────────────────
# Optional: Hyper-V Provider pre-fetch
# ─────────────────────────────────────────────
if ($IncludeHyperVProvider) {
    Write-Host "`n  Installing Taliesin Hyper-V provider..." -ForegroundColor Yellow

    # Create a minimal .tf file to trigger provider download
    $tempTf = Join-Path ([System.IO.Path]::GetTempPath()) "hv_provider_$(Get-Random)"
    New-Item -Path $tempTf -ItemType Directory -Force | Out-Null
    @"
terraform {
  required_providers {
    hyperv = {
      source  = "taliesins/hyperv"
      version = ">= 1.2.1"
    }
  }
}
"@ | Set-Content (Join-Path $tempTf 'providers.tf') -Encoding UTF8

    Push-Location $tempTf
    try {
        $tofuExe = if (Get-Command tofu -ErrorAction SilentlyContinue) { 'tofu' } else { 'terraform' }
        $initOutput = & $tofuExe init -no-color 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Taliesin Hyper-V provider cached" -ForegroundColor Green
        }
        else {
            Write-Warning "  Provider init returned non-zero. You may need to run 'tofu init' manually."
        }
    }
    catch {
        Write-Warning "  Provider install failed: $($_.Exception.Message)"
    }
    finally {
        Pop-Location
        Remove-Item -Path $tempTf -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit 0
