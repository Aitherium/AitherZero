<#
.SYNOPSIS
    Register AitherOS Windows Integration Features

.DESCRIPTION
    Sets up Windows OS integrations for AitherOS:
    
    1. Registers aither:// protocol handler
    2. Installs BurntToast module (for rich notifications)
    3. Adds Explorer context menu entries
    4. Registers startup task (optional)
    5. Creates PowerShell profile integration

.PARAMETER InstallBurntToast
    Install the BurntToast module for rich notifications

.PARAMETER AddContextMenu
    Add "Ask Aither" to Windows Explorer right-click menu

.PARAMETER AddStartup
    Add AitherOS to Windows startup

.PARAMETER Force
    Overwrite existing registrations

.EXAMPLE
    .\Register-AitherOSIntegration.ps1 -InstallBurntToast -AddContextMenu
    
.EXAMPLE
    .\Register-AitherOSIntegration.ps1 -All

.NOTES
    Author: AitherOS Team
    Requires: Windows 10/11, Administrator rights for context menu
#>

[CmdletBinding()]
param(
    [switch]$InstallBurntToast,
    [switch]$AddContextMenu,
    [switch]$AddStartup,
    [switch]$Force,
    [switch]$All
)

# Apply -All
if ($All) {
    $InstallBurntToast = $true
    $AddContextMenu = $true
    $AddStartup = $true
}

$projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

Write-Host "🔧 AitherOS Windows Integration Setup" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# 1. AITHER:// PROTOCOL HANDLER
# ============================================================================

Write-Host "📝 Registering aither:// protocol handler..." -ForegroundColor Yellow

$protocolKey = "HKCU:\Software\Classes\aither"
$handlerScript = Join-Path $PSScriptRoot "Invoke-AitherProtocol.ps1"

try {
    # Create protocol registration
    if ((Test-Path $protocolKey) -and -not $Force) {
        Write-Host "   ✅ Protocol already registered" -ForegroundColor Green
    }
    else {
        New-Item -Path $protocolKey -Force | Out-Null
        Set-ItemProperty -Path $protocolKey -Name "(Default)" -Value "URL:Aither Protocol"
        Set-ItemProperty -Path $protocolKey -Name "URL Protocol" -Value ""
        
        New-Item -Path "$protocolKey\DefaultIcon" -Force | Out-Null
        Set-ItemProperty -Path "$protocolKey\DefaultIcon" -Name "(Default)" -Value "pwsh.exe,0"
        
        New-Item -Path "$protocolKey\shell\open\command" -Force | Out-Null
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $pwshPath) { $pwshPath = "powershell.exe" }
        
        Set-ItemProperty -Path "$protocolKey\shell\open\command" -Name "(Default)" -Value "`"$pwshPath`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$handlerScript`" `"%1`""
        
        Write-Host "   ✅ Protocol registered: aither://" -ForegroundColor Green
    }
}
catch {
    Write-Host "   ❌ Failed to register protocol: $_" -ForegroundColor Red
}

# ============================================================================
# 2. BURNTTOAST MODULE
# ============================================================================

if ($InstallBurntToast) {
    Write-Host ""
    Write-Host "📦 Installing BurntToast module..." -ForegroundColor Yellow
    
    if (Get-Module -ListAvailable -Name BurntToast) {
        Write-Host "   ✅ BurntToast already installed" -ForegroundColor Green
    }
    else {
        try {
            Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber
            Write-Host "   ✅ BurntToast installed successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "   ❌ Failed to install BurntToast: $_" -ForegroundColor Red
            Write-Host "   ℹ️  Try: Install-Module BurntToast -Scope CurrentUser" -ForegroundColor Gray
        }
    }
}

# ============================================================================
# 3. EXPLORER CONTEXT MENU
# ============================================================================

if ($AddContextMenu) {
    Write-Host ""
    Write-Host "📁 Adding Explorer context menu..." -ForegroundColor Yellow
    
    # Check for admin rights
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Host "   ⚠️  Administrator rights required for HKCR registration" -ForegroundColor Yellow
        Write-Host "   ℹ️  Will use HKCU fallback (current user only)" -ForegroundColor Gray
    }
    
    $menuKeyRoot = if ($isAdmin) { "HKLM:\Software\Classes" } else { "HKCU:\Software\Classes" }
    $analyzeScript = Join-Path $projectRoot "AitherZero\library\utilities\Invoke-AitherAnalyze.ps1"
    
    try {
        # For all files: "Ask Aither"
        $fileMenuKey = "$menuKeyRoot\*\shell\AitherAsk"
        New-Item -Path $fileMenuKey -Force | Out-Null
        Set-ItemProperty -Path $fileMenuKey -Name "(Default)" -Value "🔮 Ask Aither"
        Set-ItemProperty -Path $fileMenuKey -Name "Icon" -Value "pwsh.exe,0"
        
        New-Item -Path "$fileMenuKey\command" -Force | Out-Null
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source ?? "powershell.exe"
        Set-ItemProperty -Path "$fileMenuKey\command" -Name "(Default)" -Value "`"$pwshPath`" -NoProfile -ExecutionPolicy Bypass -File `"$handlerScript`" `"aither://analyze/%1`""
        
        # For directories: "Index with Aither"
        $dirMenuKey = "$menuKeyRoot\Directory\shell\AitherIndex"
        New-Item -Path $dirMenuKey -Force | Out-Null
        Set-ItemProperty -Path $dirMenuKey -Name "(Default)" -Value "🔮 Index with Aither"
        Set-ItemProperty -Path $dirMenuKey -Name "Icon" -Value "pwsh.exe,0"
        
        New-Item -Path "$dirMenuKey\command" -Force | Out-Null
        Set-ItemProperty -Path "$dirMenuKey\command" -Name "(Default)" -Value "`"$pwshPath`" -NoProfile -ExecutionPolicy Bypass -Command `"Start-Process 'aither://index/%V'`""
        
        Write-Host "   ✅ Context menu entries added" -ForegroundColor Green
        Write-Host "   ℹ️  Right-click files → '🔮 Ask Aither'" -ForegroundColor Gray
        Write-Host "   ℹ️  Right-click folders → '🔮 Index with Aither'" -ForegroundColor Gray
    }
    catch {
        Write-Host "   ❌ Failed to add context menu: $_" -ForegroundColor Red
    }
}

# ============================================================================
# 4. STARTUP TASK
# ============================================================================

if ($AddStartup) {
    Write-Host ""
    Write-Host "🚀 Adding startup registration..." -ForegroundColor Yellow
    
    $startupKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $startupScript = Join-Path $projectRoot "start_genesis.ps1"
    
    if (-not (Test-Path $startupScript)) {
        Write-Host "   ⚠️  Start script not found: $startupScript" -ForegroundColor Yellow
    }
    else {
        try {
            $existingValue = Get-ItemProperty -Path $startupKey -Name "AitherOS" -ErrorAction SilentlyContinue
            if ($existingValue -and -not $Force) {
                Write-Host "   ✅ Startup already registered" -ForegroundColor Green
            }
            else {
                $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source ?? "powershell.exe"
                Set-ItemProperty -Path $startupKey -Name "AitherOS" -Value "`"$pwshPath`" -NoProfile -WindowStyle Hidden -File `"$startupScript`""
                Write-Host "   ✅ Startup registration added" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "   ❌ Failed to add startup: $_" -ForegroundColor Red
        }
    }
}

# ============================================================================
# 5. TEST NOTIFICATION
# ============================================================================

Write-Host ""
Write-Host "🔔 Testing notification system..." -ForegroundColor Yellow

$notifyScript = Join-Path $PSScriptRoot "Send-AitherNotification.ps1"
if (Test-Path $notifyScript) {
    try {
        & $notifyScript -Title "AitherOS Installed" -Message "Windows integration is ready!" -Severity Info -Actions @(
            @{ Label = "Open Dashboard"; Action = "http://localhost:3000" }
            @{ Label = "Test Protocol"; Action = "aither://status" }
        )
        Write-Host "   ✅ Test notification sent" -ForegroundColor Green
    }
    catch {
        Write-Host "   ⚠️  Notification test failed: $_" -ForegroundColor Yellow
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "✅ Setup Complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Available aither:// commands:" -ForegroundColor White
Write-Host "  aither://restart/{service}  - Restart a service" -ForegroundColor Gray
Write-Host "  aither://logs/{service}     - View service logs" -ForegroundColor Gray
Write-Host "  aither://open/{page}        - Open dashboard page" -ForegroundColor Gray
Write-Host "  aither://run/{routine}      - Trigger routine" -ForegroundColor Gray
Write-Host "  aither://status             - Show service status" -ForegroundColor Gray
Write-Host ""
Write-Host "Try it: Start-Process 'aither://status'" -ForegroundColor Cyan
