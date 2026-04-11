#Requires -Version 7.0

<#
.SYNOPSIS
    Enable the Hyper-V role and management tools on Windows.

.DESCRIPTION
    Enables the Hyper-V platform (hypervisor, management tools, PowerShell module)
    on both Windows Desktop (10/11) and Windows Server (2019/2022/2025).

    This is required for the AitherOS ISO → Deploy pipeline to create VMs
    via OpenTofu with the Taliesin Hyper-V provider.

    The script detects the Windows edition and uses the appropriate method:
      - Client: Enable-WindowsOptionalFeature (DISM)
      - Server: Install-WindowsFeature (Server Manager)

    Returns exit code 200 if a reboot is required for Hyper-V activation.

.PARAMETER IncludeManagementTools
    Also install Hyper-V management tools (GUI). Default: $true.

.PARAMETER SkipRebootCheck
    Don't prompt about reboot requirements.

.PARAMETER Force
    Re-enable even if already detected as enabled.

.EXAMPLE
    .\0105_Enable-HyperV.ps1
    Enables Hyper-V with management tools.

.EXAMPLE
    .\0105_Enable-HyperV.ps1 -SkipRebootCheck
    Enables Hyper-V and doesn't warn about reboots.

.NOTES
    Category:     infrastructure
    Dependencies: None
    Platform:     Windows (x64 with VT-x/AMD-V)
    Exit Codes:   0 = already enabled or enabled without reboot,
                  1 = failure,
                  200 = enabled but reboot required
#>

[CmdletBinding()]
param(
    [bool]$IncludeManagementTools = $true,
    [switch]$SkipRebootCheck,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
# Platform guard
# ─────────────────────────────────────────────
if (-not $IsWindows) {
    Write-Host "[SKIP] Hyper-V is only available on Windows." -ForegroundColor Yellow
    exit 0
}

# ─────────────────────────────────────────────
# Admin check
# ─────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "[!] Hyper-V enablement requires Administrator privileges." -ForegroundColor Red
    Write-Host "    Please run this script in an elevated PowerShell session." -ForegroundColor Yellow
    exit 1
}

Write-Host "`n════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Enabling Hyper-V" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════`n" -ForegroundColor Cyan

# ─────────────────────────────────────────────
# Detect current state
# ─────────────────────────────────────────────
$isServer = $false
$hvEnabled = $false
$rebootNeeded = $false

# Detect Server vs Client
try {
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $isServer = $osInfo.ProductType -ne 1  # 1 = Workstation, 2 = DC, 3 = Server
}
catch {
    # Default to client behaviour
    $isServer = $null -ne (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)
}

Write-Host "  OS Type: $(if ($isServer) { 'Windows Server' } else { 'Windows Client' })"

# Check current state
if ($isServer) {
    try {
        $hvFeature = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
        $hvEnabled = $hvFeature.Installed
        Write-Host "  Hyper-V state: $(if ($hvEnabled) { 'Installed' } else { $hvFeature.InstallState })"
    }
    catch {
        Write-Host "  Could not query Hyper-V state via Get-WindowsFeature: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
else {
    try {
        $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
        $hvEnabled = $hvFeature.State -eq 'Enabled'
        Write-Host "  Hyper-V state: $($hvFeature.State)"
    }
    catch {
        Write-Host "  Could not query Hyper-V state via DISM: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($hvEnabled -and -not $Force) {
    Write-Host "`n  [OK] Hyper-V is already enabled." -ForegroundColor Green

    # Also check Hyper-V PowerShell module
    if (Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue) {
        Write-Host "  [OK] Hyper-V PowerShell module available." -ForegroundColor Green
    }
    else {
        Write-Host "  [--] Hyper-V PowerShell module not found — installing..." -ForegroundColor Yellow
        if ($isServer) {
            Install-WindowsFeature -Name Hyper-V-PowerShell -ErrorAction SilentlyContinue | Out-Null
        }
        else {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -NoRestart -ErrorAction SilentlyContinue | Out-Null
        }
    }
    exit 0
}

# ─────────────────────────────────────────────
# Hardware virtualization check
# ─────────────────────────────────────────────
Write-Host "`n  Checking hardware virtualization support..." -ForegroundColor Gray
try {
    $cpuInfo = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    $vtSupport = $cpuInfo.VirtualizationFirmwareEnabled
    if ($null -eq $vtSupport) {
        Write-Host "  [?] Cannot determine VT-x/AMD-V state (may need BIOS check)" -ForegroundColor Yellow
    }
    elseif ($vtSupport) {
        Write-Host "  [OK] Hardware virtualization enabled" -ForegroundColor Green
    }
    else {
        Write-Host "  [!] Hardware virtualization appears DISABLED in BIOS/UEFI." -ForegroundColor Red
        Write-Host "      Enable VT-x (Intel) or AMD-V in BIOS before Hyper-V can function." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  [?] Could not check hardware virtualization: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ─────────────────────────────────────────────
# Enable Hyper-V
# ─────────────────────────────────────────────
Write-Host "`n  Enabling Hyper-V features..." -ForegroundColor Yellow

if ($isServer) {
    # Windows Server: use Install-WindowsFeature
    $features = @('Hyper-V')
    if ($IncludeManagementTools) {
        $features += 'Hyper-V-Tools'
        $features += 'Hyper-V-PowerShell'
    }

    try {
        $result = Install-WindowsFeature -Name $features -IncludeAllSubFeature -ErrorAction Stop
        $rebootNeeded = $result.RestartNeeded -eq 'Yes'

        if ($result.Success) {
            Write-Host "  [OK] Hyper-V features installed on Server" -ForegroundColor Green
            foreach ($f in $result.FeatureResult) {
                Write-Host "    + $($f.Name): $($f.Message)" -ForegroundColor Gray
            }
        }
        else {
            Write-Host "  [FAIL] Install-WindowsFeature did not succeed." -ForegroundColor Red
            exit 1
        }
    }
    catch {
        Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
else {
    # Windows Client: use Enable-WindowsOptionalFeature
    $features = @(
        'Microsoft-Hyper-V-All'             # Umbrella feature
        'Microsoft-Hyper-V'                 # Hypervisor
        'Microsoft-Hyper-V-Management-PowerShell'  # PS module
    )
    if ($IncludeManagementTools) {
        $features += 'Microsoft-Hyper-V-Management-Clients'  # GUI tools
    }

    foreach ($feature in $features) {
        try {
            Write-Host "    Enabling $feature..." -ForegroundColor Gray
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -All -ErrorAction SilentlyContinue
            if ($result -and $result.RestartNeeded) {
                $rebootNeeded = $true
            }
        }
        catch {
            # Some sub-features may already be enabled or not applicable
            Write-Host "    $feature — $($_.Exception.Message)" -ForegroundColor Gray
        }
    }
    Write-Host "  [OK] Hyper-V features enabled on Client" -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Reboot handling
# ─────────────────────────────────────────────
if ($rebootNeeded) {
    Write-Host "`n  ╔═══════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║  REBOOT REQUIRED                          ║" -ForegroundColor Yellow
    Write-Host "  ║  Hyper-V is enabled but requires a        ║" -ForegroundColor Yellow
    Write-Host "  ║  system restart to activate the hypervisor.║" -ForegroundColor Yellow
    Write-Host "  ╚═══════════════════════════════════════════╝" -ForegroundColor Yellow

    if (-not $SkipRebootCheck) {
        Write-Host "`n  After reboot, re-run the ISO pipeline:" -ForegroundColor Cyan
        Write-Host "    New-AitherWindowsISO -SourceISO 'C:\ISOs\Server2025.iso'" -ForegroundColor Cyan
    }
    exit 200
}
else {
    Write-Host "`n  [OK] Hyper-V is ready — no reboot required." -ForegroundColor Green
    exit 0
}
