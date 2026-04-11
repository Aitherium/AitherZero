#Requires -Version 7.0

<#
.SYNOPSIS
    Validate that all infrastructure prerequisites are present and offer to install missing ones.

.DESCRIPTION
    Checks for the presence of required infrastructure tools:
      - Windows ADK / oscdimg.exe (ISO building)
      - OpenTofu / Terraform (IaC provisioning)
      - Hyper-V role (VM hosting)
      - DISM (WIM manipulation — built-in on Windows)
      - WinRM / PSRemoting (remote management)

    Reports status of each prerequisite and, if -AutoInstall is set, invokes
    the appropriate installer scripts from the 01-infrastructure directory.

.PARAMETER AutoInstall
    Automatically install missing prerequisites without prompting.

.PARAMETER Scope
    Which prerequisite groups to validate.
    'All' checks everything. Other scopes allow targeted checks.

.PARAMETER PassThru
    Return a structured object with results instead of console output.

.EXAMPLE
    .\0100_Validate-InfraPrerequisites.ps1
    Validates and reports status of all infrastructure prerequisites.

.EXAMPLE
    .\0100_Validate-InfraPrerequisites.ps1 -AutoInstall -Scope ISO
    Checks and auto-installs only ISO-building prerequisites (ADK, DISM).

.NOTES
    Category:     infrastructure
    Dependencies: None
    Platform:     Windows
    Exit Codes:   0 = all present, 1 = missing (auto-install failed or not requested)
#>

[CmdletBinding()]
param(
    [switch]$AutoInstall,

    [ValidateSet('All', 'ISO', 'Tofu', 'HyperV', 'Remoting')]
    [string]$Scope = 'All',

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

# ─────────────────────────────────────────────
# Helper: coloured check/cross output
# ─────────────────────────────────────────────
function Write-PrereqResult {
    param([string]$Name, [bool]$Present, [string]$Detail = '')
    $icon = if ($Present) { '[OK]' } else { '[--]' }
    $color = if ($Present) { 'Green' } else { 'Red' }
    $msg = "  $icon $Name"
    if ($Detail) { $msg += " — $Detail" }
    Write-Host $msg -ForegroundColor $color
}

# ─────────────────────────────────────────────
# Collect results
# ─────────────────────────────────────────────
$results = [ordered]@{}

Write-Host "`n╔════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Infrastructure Prerequisite Validator     ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# ── OS Check ──
if (-not $IsWindows) {
    Write-Host "  This validator targets Windows infrastructure." -ForegroundColor Yellow
    Write-Host "  Some checks may not apply on Linux/macOS.`n" -ForegroundColor Yellow
}

# ── Administrator Check ──
$isAdmin = if ($IsWindows) {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} else { (id -u) -eq 0 }
Write-PrereqResult 'Administrator' $isAdmin $(if ($isAdmin) { 'Elevated' } else { 'Some installs require elevation' })
$results['Administrator'] = $isAdmin

# ── PowerShell 7+ ──
$ps7 = $PSVersionTable.PSVersion.Major -ge 7
Write-PrereqResult 'PowerShell 7+' $ps7 "v$($PSVersionTable.PSVersion)"
$results['PowerShell7'] = $ps7

# ═══════════════════════════════════════════
# DISM (built-in on Windows)
# ═══════════════════════════════════════════
if ($Scope -in @('All', 'ISO')) {
    $dismPresent = $null -ne (Get-Command dism.exe -ErrorAction SilentlyContinue)
    Write-PrereqResult 'DISM' $dismPresent $(if ($dismPresent) { (dism.exe /? 2>&1 | Select-String 'Version' | Select-Object -First 1).ToString().Trim() } else { 'Not found (Windows built-in — check PATH)' })
    $results['DISM'] = $dismPresent
}

# ═══════════════════════════════════════════
# Windows ADK / oscdimg.exe
# ═══════════════════════════════════════════
if ($Scope -in @('All', 'ISO')) {
    $oscdimg = $env:OSCDIMG_PATH
    if (-not $oscdimg) {
        $adkPaths = @(
            "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
            "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
            "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
        )
        foreach ($p in $adkPaths) {
            if (Test-Path $p) { $oscdimg = $p; break }
        }
    }
    $adkPresent = $oscdimg -and (Test-Path $oscdimg)
    Write-PrereqResult 'Windows ADK (oscdimg)' $adkPresent $(if ($adkPresent) { $oscdimg } else { 'Not found' })
    $results['WindowsADK'] = $adkPresent

    if (-not $adkPresent -and $AutoInstall) {
        $installerScript = Join-Path $scriptDir '0101_Install-WindowsADK.ps1'
        if (Test-Path $installerScript) {
            Write-Host "    → Auto-installing Windows ADK..." -ForegroundColor Yellow
            try {
                & $installerScript -ErrorAction Stop
                $results['WindowsADK'] = $true
                Write-Host "    → Windows ADK installed" -ForegroundColor Green
            }
            catch {
                Write-Warning "    → Windows ADK install failed: $($_.Exception.Message)"
            }
        }
        else {
            Write-Warning "    → Installer script not found: $installerScript"
        }
    }
}

# ═══════════════════════════════════════════
# OpenTofu / Terraform
# ═══════════════════════════════════════════
if ($Scope -in @('All', 'Tofu')) {
    $tofuCmd = Get-Command tofu -ErrorAction SilentlyContinue
    $tfCmd = Get-Command terraform -ErrorAction SilentlyContinue
    $iacPresent = $null -ne $tofuCmd -or $null -ne $tfCmd
    $iacDetail = if ($tofuCmd) { "tofu $(& tofu version -json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue | Select-Object -ExpandProperty terraform_version -ErrorAction SilentlyContinue)" }
                 elseif ($tfCmd) { "terraform $(terraform version -json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue | Select-Object -ExpandProperty terraform_version -ErrorAction SilentlyContinue)" }
                 else { 'Not found' }
    Write-PrereqResult 'OpenTofu / Terraform' $iacPresent $iacDetail
    $results['OpenTofu'] = $iacPresent

    if (-not $iacPresent -and $AutoInstall) {
        $installerScript = Join-Path $scriptDir '0102_Install-OpenTofu.ps1'
        if (Test-Path $installerScript) {
            Write-Host "    → Auto-installing OpenTofu..." -ForegroundColor Yellow
            try {
                & $installerScript -ErrorAction Stop
                $results['OpenTofu'] = $true
                Write-Host "    → OpenTofu installed" -ForegroundColor Green
            }
            catch {
                Write-Warning "    → OpenTofu install failed: $($_.Exception.Message)"
            }
        }
        else {
            Write-Warning "    → Installer script not found: $installerScript"
        }
    }
}

# ═══════════════════════════════════════════
# Hyper-V
# ═══════════════════════════════════════════
if ($Scope -in @('All', 'HyperV')) {
    $hvPresent = $false
    $hvDetail = 'Not available'
    if ($IsWindows) {
        try {
            $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
            if ($hvFeature -and $hvFeature.State -eq 'Enabled') {
                $hvPresent = $true
                $hvDetail = 'Enabled'
            }
            elseif ($hvFeature) {
                $hvDetail = "State: $($hvFeature.State)"
            }
        }
        catch {
            # Try server variant
            try {
                $hvRole = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
                if ($hvRole -and $hvRole.Installed) {
                    $hvPresent = $true
                    $hvDetail = 'Installed (Server)'
                }
                elseif ($hvRole) {
                    $hvDetail = "State: $($hvRole.InstallState)"
                }
            }
            catch {
                $hvDetail = 'Cannot determine (run as Administrator)'
            }
        }
    }
    Write-PrereqResult 'Hyper-V' $hvPresent $hvDetail
    $results['HyperV'] = $hvPresent

    if (-not $hvPresent -and $AutoInstall) {
        $installerScript = Join-Path $scriptDir '0105_Enable-HyperV.ps1'
        if (Test-Path $installerScript) {
            Write-Host "    → Auto-enabling Hyper-V..." -ForegroundColor Yellow
            try {
                & $installerScript -ErrorAction Stop
                # Hyper-V enable may require reboot — check exit code
                if ($LASTEXITCODE -eq 200) {
                    Write-Host "    → Hyper-V enabled — REBOOT REQUIRED" -ForegroundColor Yellow
                    $results['HyperV'] = 'RebootRequired'
                }
                else {
                    $results['HyperV'] = $true
                    Write-Host "    → Hyper-V enabled" -ForegroundColor Green
                }
            }
            catch {
                Write-Warning "    → Hyper-V enable failed: $($_.Exception.Message)"
            }
        }
        else {
            Write-Warning "    → Installer script not found: $installerScript"
        }
    }
}

# ═══════════════════════════════════════════
# WinRM / PSRemoting
# ═══════════════════════════════════════════
if ($Scope -in @('All', 'Remoting')) {
    $winrmPresent = $false
    $winrmDetail = 'Not configured'
    if ($IsWindows) {
        try {
            $winrmService = Get-Service WinRM -ErrorAction SilentlyContinue
            if ($winrmService -and $winrmService.Status -eq 'Running') {
                $winrmPresent = $true
                $winrmDetail = 'Running'
            }
            elseif ($winrmService) {
                $winrmDetail = "Status: $($winrmService.Status)"
            }
        }
        catch {
            $winrmDetail = 'Cannot check (run as Administrator)'
        }
    }
    Write-PrereqResult 'WinRM Service' $winrmPresent $winrmDetail
    $results['WinRM'] = $winrmPresent
}

# ═══════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════
$missing = ($results.GetEnumerator() | Where-Object { $_.Value -eq $false }).Count
$rebootNeeded = ($results.GetEnumerator() | Where-Object { $_.Value -eq 'RebootRequired' }).Count

Write-Host ""
if ($missing -eq 0 -and $rebootNeeded -eq 0) {
    Write-Host "  All prerequisites satisfied!" -ForegroundColor Green
}
elseif ($rebootNeeded -gt 0) {
    Write-Host "  $rebootNeeded prerequisite(s) require a system reboot." -ForegroundColor Yellow
    Write-Host "  Please reboot and re-run this validator." -ForegroundColor Yellow
}
else {
    Write-Host "  $missing prerequisite(s) missing." -ForegroundColor Red
    if (-not $AutoInstall) {
        Write-Host "  Re-run with -AutoInstall to automatically resolve." -ForegroundColor Yellow
        Write-Host "  Or install manually and re-validate." -ForegroundColor Yellow
    }
}
Write-Host ""

if ($PassThru) {
    return [PSCustomObject]@{
        PSTypeName     = 'AitherOS.InfraPrerequisites'
        Timestamp      = Get-Date -Format 'o'
        Results        = $results
        AllPresent     = ($missing -eq 0 -and $rebootNeeded -eq 0)
        MissingCount   = $missing
        RebootRequired = $rebootNeeded -gt 0
    }
}

exit $(if ($missing -gt 0) { 1 } else { 0 })
