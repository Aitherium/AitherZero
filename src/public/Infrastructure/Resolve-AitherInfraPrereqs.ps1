#Requires -Version 7.0

<#
.SYNOPSIS
    Resolve and auto-install infrastructure prerequisites for the AitherOS ISO pipeline.

.DESCRIPTION
    Acts as a dependency resolver for the AitherOS ISO build and deploy pipeline.
    Checks for all required tools and, if missing, invokes the appropriate installer
    script from the 01-infrastructure automation directory.

    Called automatically by:
      - New-AitherWindowsISO (the orchestrator cmdlet)
      - 3105_Build-WindowsISO.ps1 (the ISO builder)

    Can also be used standalone for validation.

    Required components by pipeline phase:
      ISO Build:   Windows ADK (oscdimg.exe), DISM, Administrator
      Tofu Apply:  OpenTofu >= 1.6.0, Taliesin Hyper-V provider
      VM Hosting:  Hyper-V role enabled
      Remote Mgmt: WinRM / PSRemoting

.PARAMETER Scope
    Which prerequisites to resolve:
      - All:      Everything needed for the full pipeline
      - ISO:      Only ISO building prerequisites (ADK, DISM)
      - Deploy:   Only deployment prerequisites (OpenTofu, Hyper-V)
      - Validate: Check-only, do not install anything

.PARAMETER AutoInstall
    Automatically install missing prerequisites without prompting.
    Default: $true (since this is designed to be called by automation).

.PARAMETER ScriptsDir
    Path to the 01-infrastructure automation scripts directory.
    Auto-detected from module root if not specified.

.PARAMETER PassThru
    Return a result object instead of throwing on failure.

.EXAMPLE
    Resolve-AitherInfraPrereqs
    Checks and auto-installs all prerequisites for the full pipeline.

.EXAMPLE
    Resolve-AitherInfraPrereqs -Scope ISO -PassThru
    Checks ISO prerequisites only and returns a status object.

.EXAMPLE
    Resolve-AitherInfraPrereqs -Scope Validate
    Validation-only mode — reports status without installing anything.

.OUTPUTS
    PSCustomObject (if -PassThru) with properties: AllSatisfied, Results, RebootRequired

.NOTES
    Exported AitherZero module function — available after Import-Module AitherZero.
#>
function Resolve-AitherInfraPrereqs {
    [CmdletBinding()]
    param(
        [ValidateSet('All', 'ISO', 'Deploy', 'Validate')]
        [string]$Scope = 'All',

        [bool]$AutoInstall = $true,

        [string]$ScriptsDir,

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # ─────────────────────────────────────────────
    # Locate installer scripts directory
    # ─────────────────────────────────────────────
    if (-not $ScriptsDir) {
        # Try module root
        $moduleRoot = if (Get-Command Get-AitherModuleRoot -ErrorAction SilentlyContinue) {
            Get-AitherModuleRoot
        }
        else {
            # Walk up from this file's location
            $candidate = $PSScriptRoot
            while ($candidate -and -not (Test-Path (Join-Path $candidate 'AitherZero\AitherZero.psd1'))) {
                $candidate = Split-Path $candidate -Parent
            }
            $candidate
        }
        $ScriptsDir = Join-Path $moduleRoot 'AitherZero\library\automation-scripts\01-infrastructure'
    }

    $isValidateOnly = $Scope -eq 'Validate'
    if ($isValidateOnly) { $AutoInstall = $false }

    $results = [ordered]@{}
    $rebootRequired = $false

    Write-Host "`n╔════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  AitherOS Prerequisite Resolver            ║" -ForegroundColor Cyan
    Write-Host "║  Scope: $Scope$((' ' * (35 - $Scope.Length)))║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════╝`n" -ForegroundColor Cyan

    # ── Helper: invoke installer script ──
    function Invoke-InstallerScript {
        param([string]$ScriptName, [hashtable]$ScriptParams = @{})
        $scriptPath = Join-Path $ScriptsDir $ScriptName
        if (-not (Test-Path $scriptPath)) {
            Write-Warning "  Installer script not found: $scriptPath"
            return $false
        }
        try {
            & $scriptPath @ScriptParams
            return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 200)
        }
        catch {
            Write-Warning "  Installer failed: $($_.Exception.Message)"
            return $false
        }
    }

    # ═══════════════════════════════════════════
    # 1. Administrator check (needed for all scopes)
    # ═══════════════════════════════════════════
    $isAdmin = if ($IsWindows) {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } else { (id -u) -eq 0 }

    $results['Administrator'] = $isAdmin
    if ($isAdmin) {
        Write-Host "  [OK] Administrator privileges" -ForegroundColor Green
    }
    else {
        Write-Host "  [--] Not running as Administrator (some installs may fail)" -ForegroundColor Yellow
    }

    # ═══════════════════════════════════════════
    # 2. ISO Prerequisites (ADK + DISM)
    # ═══════════════════════════════════════════
    if ($Scope -in @('All', 'ISO')) {
        # DISM check
        $dismPresent = $null -ne (Get-Command dism.exe -ErrorAction SilentlyContinue)
        $results['DISM'] = $dismPresent
        if ($dismPresent) {
            Write-Host "  [OK] DISM" -ForegroundColor Green
        }
        else {
            Write-Host "  [--] DISM not found (Windows built-in — check PATH)" -ForegroundColor Red
        }

        # oscdimg / Windows ADK
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
        $results['WindowsADK'] = $adkPresent

        if ($adkPresent) {
            Write-Host "  [OK] Windows ADK (oscdimg: $oscdimg)" -ForegroundColor Green
            $env:OSCDIMG_PATH = $oscdimg
        }
        else {
            Write-Host "  [--] Windows ADK / oscdimg.exe not found" -ForegroundColor Red
            if ($AutoInstall) {
                Write-Host "       → Installing..." -ForegroundColor Yellow
                $ok = Invoke-InstallerScript '0101_Install-WindowsADK.ps1'
                $results['WindowsADK'] = $ok
                if ($ok) { Write-Host "  [OK] Windows ADK installed" -ForegroundColor Green }
            }
        }
    }

    # ═══════════════════════════════════════════
    # 3. Deploy Prerequisites (OpenTofu + Hyper-V)
    # ═══════════════════════════════════════════
    if ($Scope -in @('All', 'Deploy')) {
        # OpenTofu / Terraform
        $tofuPresent = $null -ne (Get-Command tofu -ErrorAction SilentlyContinue) -or
                       $null -ne (Get-Command terraform -ErrorAction SilentlyContinue)
        $results['OpenTofu'] = $tofuPresent

        if ($tofuPresent) {
            $cmd = if (Get-Command tofu -ErrorAction SilentlyContinue) { 'tofu' } else { 'terraform' }
            Write-Host "  [OK] OpenTofu/Terraform ($cmd)" -ForegroundColor Green
        }
        else {
            Write-Host "  [--] OpenTofu / Terraform not found" -ForegroundColor Red
            if ($AutoInstall) {
                Write-Host "       → Installing OpenTofu..." -ForegroundColor Yellow
                $ok = Invoke-InstallerScript '0102_Install-OpenTofu.ps1' @{ IncludeHyperVProvider = $true }
                $results['OpenTofu'] = $ok
                if ($ok) { Write-Host "  [OK] OpenTofu installed" -ForegroundColor Green }
            }
        }

        # Hyper-V
        $hvPresent = $false
        if ($IsWindows) {
            try {
                $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
                $hvPresent = $hvFeature -and $hvFeature.State -eq 'Enabled'
            }
            catch {
                try {
                    $hvRole = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
                    $hvPresent = $hvRole -and $hvRole.Installed
                }
                catch { }
            }
        }
        $results['HyperV'] = $hvPresent

        if ($hvPresent) {
            Write-Host "  [OK] Hyper-V" -ForegroundColor Green
        }
        else {
            Write-Host "  [--] Hyper-V not enabled" -ForegroundColor Red
            if ($AutoInstall) {
                Write-Host "       → Enabling Hyper-V..." -ForegroundColor Yellow
                $ok = Invoke-InstallerScript '0105_Enable-HyperV.ps1'
                if ($LASTEXITCODE -eq 200) {
                    $rebootRequired = $true
                    $results['HyperV'] = 'RebootRequired'
                    Write-Host "  [!!] Hyper-V enabled — REBOOT REQUIRED before VMs can be created" -ForegroundColor Yellow
                }
                elseif ($ok) {
                    $results['HyperV'] = $true
                    Write-Host "  [OK] Hyper-V enabled" -ForegroundColor Green
                }
            }
        }
    }

    # ═══════════════════════════════════════════
    # Summary
    # ═══════════════════════════════════════════
    $missing = ($results.GetEnumerator() | Where-Object { $_.Value -eq $false }).Count

    Write-Host ""
    if ($missing -eq 0 -and -not $rebootRequired) {
        Write-Host "  ✓ All prerequisites satisfied — pipeline ready!" -ForegroundColor Green
    }
    elseif ($rebootRequired) {
        Write-Host "  ⚠ Reboot required before the pipeline can create VMs." -ForegroundColor Yellow
        Write-Host "  ISO building is still possible without reboot." -ForegroundColor Gray
    }
    else {
        Write-Host "  ✗ $missing prerequisite(s) still missing." -ForegroundColor Red
        if ($isValidateOnly) {
            Write-Host "  Run: Resolve-AitherInfraPrereqs -Scope $Scope" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    if ($PassThru) {
        return [PSCustomObject]@{
            PSTypeName     = 'AitherOS.PrereqResolverResult'
            Timestamp      = Get-Date -Format 'o'
            Scope          = $Scope
            Results        = $results
            AllSatisfied   = ($missing -eq 0 -and -not $rebootRequired)
            MissingCount   = $missing
            RebootRequired = $rebootRequired
        }
    }

    # If validate-only or missing items, don't throw — caller decides
    if ($missing -gt 0 -and -not $isValidateOnly -and -not $PassThru) {
        $missingNames = ($results.GetEnumerator() | Where-Object { $_.Value -eq $false } | ForEach-Object { $_.Key }) -join ', '
        throw "Missing infrastructure prerequisites: $missingNames. Run with -AutoInstall `$true or install manually."
    }
}
