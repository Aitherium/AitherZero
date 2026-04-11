#Requires -Version 7.0
<#
.SYNOPSIS
    Installs Tailscale VPN for secure remote access to AitherOS.
.DESCRIPTION
    Automates Tailscale installation and initial configuration for:
    - Zero-config NAT traversal
    - MagicDNS for easy service discovery (*.ts.net)
    - Subnet routing for home network access
    - Integration with Firewalla Gold
    
    Part of the AitherGateway remote access setup (Section 73.7).

.PARAMETER AuthKey
    Tailscale auth key for headless setup (get from admin.tailscale.com)

.PARAMETER SubnetRoutes
    Subnet CIDR to advertise (e.g., "192.168.1.0/24" for home network)

.PARAMETER ExitNode
    Enable this machine as an exit node

.PARAMETER AcceptRoutes
    Accept routes advertised by other nodes (for Firewalla subnet router)

.PARAMETER Hostname
    Custom hostname for this machine on Tailscale network

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    ./0816_Install-Tailscale.ps1 -ShowOutput
    Install Tailscale interactively

.EXAMPLE
    ./0816_Install-Tailscale.ps1 -AuthKey "tskey-xxx" -AcceptRoutes -ShowOutput
    Install with auth key and accept routes from Firewalla

.EXAMPLE
    ./0816_Install-Tailscale.ps1 -SubnetRoutes "192.168.1.0/24" -AuthKey "tskey-xxx"
    Set up as subnet router for home network

.NOTES
    Stage: Remote Access
    Order: 0816
    Tags: tailscale, vpn, remote-access, aithergateway
    Dependencies: None
    Roadmap: Section 73.7, P406-P407
#>
[CmdletBinding()]
param(
    [string]$AuthKey,
    
    [string]$SubnetRoutes,
    
    [switch]$ExitNode,
    
    [switch]$AcceptRoutes,
    
    [string]$Hostname,
    
    [switch]$ShowOutput,
    
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/_init.ps1"

# ============================================================================
# CONFIGURATION
# ============================================================================

$TailscaleInstaller = "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe"
$TailscalePath = "C:\Program Files\Tailscale"
$TailscaleExe = Join-Path $TailscalePath "tailscale.exe"
$TailscaleIPv4 = Join-Path $TailscalePath "tailscale-ipn.exe"

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Msg, [string]$Level = "Info")
    if (-not $ShowOutput) { return }
    $icon = switch ($Level) { 
        "OK" { "✓" } 
        "Err" { "✗" } 
        "Warn" { "⚠" }
        "Step" { "►" }
        default { "○" } 
    }
    $color = switch ($Level) { 
        "OK" { "Green" } 
        "Err" { "Red" } 
        "Warn" { "Yellow" }
        "Step" { "Cyan" }
        default { "White" } 
    }
    Write-Host "$icon $Msg" -ForegroundColor $color
}

function Test-TailscaleInstalled {
    return (Test-Path $TailscaleExe) -or (Get-Command "tailscale" -ErrorAction SilentlyContinue)
}

function Get-TailscaleStatus {
    try {
        $status = & tailscale status --json 2>$null | ConvertFrom-Json
        return $status
    } catch {
        return $null
    }
}

function Get-TailscaleIP {
    try {
        $ip = & tailscale ip -4 2>$null
        return $ip?.Trim()
    } catch {
        return $null
    }
}

# ============================================================================
# MAIN
# ============================================================================

if ($ShowOutput) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║              TAILSCALE VPN SETUP                                 ║" -ForegroundColor Magenta
    Write-Host "║              AitherGateway Remote Access                         ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
}

# Uninstall mode
if ($Uninstall) {
    Write-Log "Uninstalling Tailscale..." "Step"
    
    # Stop service
    Stop-Service -Name "Tailscale" -Force -ErrorAction SilentlyContinue
    
    # Run uninstaller
    $uninstaller = Join-Path $TailscalePath "Uninstall.exe"
    if (Test-Path $uninstaller) {
        Start-Process -FilePath $uninstaller -ArgumentList "/S" -Wait
        Write-Log "Tailscale uninstalled" "OK"
    } else {
        Write-Log "Uninstaller not found - may need manual removal" "Warn"
    }
    
    return @{ Success = $true; Action = "Uninstalled" }
}

# Check if already installed
if (Test-TailscaleInstalled) {
    Write-Log "Tailscale already installed" "OK"
    
    $status = Get-TailscaleStatus
    $ip = Get-TailscaleIP
    
    if ($status -and $ip) {
        Write-Log "  Tailscale IP: $ip" "Info"
        Write-Log "  Status: $($status.BackendState)" "Info"
    }
    
    # If auth key provided, connect/reconfigure
    if ($AuthKey -or $SubnetRoutes -or $ExitNode -or $AcceptRoutes -or $Hostname) {
        Write-Log "Configuring Tailscale..." "Step"
        
        $upArgs = @()
        
        if ($AuthKey) {
            $upArgs += "--authkey=$AuthKey"
        }
        
        if ($SubnetRoutes) {
            $upArgs += "--advertise-routes=$SubnetRoutes"
        }
        
        if ($ExitNode) {
            $upArgs += "--advertise-exit-node"
        }
        
        if ($AcceptRoutes) {
            $upArgs += "--accept-routes"
        }
        
        if ($Hostname) {
            $upArgs += "--hostname=$Hostname"
        }
        
        $upArgs += "--reset"
        
        Write-Log "Running: tailscale up $($upArgs -join ' ')" "Info"
        & tailscale up @upArgs
        
        Start-Sleep -Seconds 3
        
        $newIP = Get-TailscaleIP
        if ($newIP) {
            Write-Log "Connected! Tailscale IP: $newIP" "OK"
        }
    }
    
    return @{
        Success = $true
        Action = "AlreadyInstalled"
        TailscaleIP = $ip
        Status = $status?.BackendState
    }
}

# Download and install
Write-Log "Downloading Tailscale installer..." "Step"

$installerPath = Join-Path $env:TEMP "tailscale-setup.exe"
try {
    Invoke-WebRequest -Uri $TailscaleInstaller -OutFile $installerPath -UseBasicParsing
    Write-Log "Downloaded successfully" "OK"
} catch {
    Write-Log "Failed to download: $_" "Err"
    return @{ Success = $false; Error = $_.Exception.Message }
}

# Install silently
Write-Log "Installing Tailscale..." "Step"
try {
    $process = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru
    
    if ($process.ExitCode -ne 0) {
        Write-Log "Installer returned exit code $($process.ExitCode)" "Warn"
    }
    
    # Wait for service to be available
    Start-Sleep -Seconds 5
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    
    Write-Log "Tailscale installed" "OK"
} catch {
    Write-Log "Installation failed: $_" "Err"
    return @{ Success = $false; Error = $_.Exception.Message }
}

# Clean up
Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

# Connect with provided options
Write-Log "Connecting to Tailscale..." "Step"

$upArgs = @()

if ($AuthKey) {
    $upArgs += "--authkey=$AuthKey"
}

if ($SubnetRoutes) {
    $upArgs += "--advertise-routes=$SubnetRoutes"
}

if ($ExitNode) {
    $upArgs += "--advertise-exit-node"
}

if ($AcceptRoutes) {
    $upArgs += "--accept-routes"
}

if ($Hostname) {
    $upArgs += "--hostname=$Hostname"
} else {
    $upArgs += "--hostname=aither-$($env:COMPUTERNAME.ToLower())"
}

try {
    if ($upArgs.Count -gt 0) {
        Write-Log "Running: tailscale up $($upArgs -join ' ')" "Info"
        & tailscale up @upArgs
    } else {
        Write-Log "Running: tailscale up (interactive login)" "Info"
        & tailscale up
    }
    
    Start-Sleep -Seconds 5
    
    $ip = Get-TailscaleIP
    if ($ip) {
        Write-Log "Connected! Tailscale IP: $ip" "OK"
    } else {
        Write-Log "Check browser for login if not using auth key" "Warn"
    }
} catch {
    Write-Log "Connection failed (may need interactive login): $_" "Warn"
}

# Summary
if ($ShowOutput) {
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    1. Verify connection: " -NoNewline; Write-Host "tailscale status" -ForegroundColor Cyan
    Write-Host "    2. Enable MagicDNS in admin console: " -NoNewline; Write-Host "https://login.tailscale.com/admin/dns" -ForegroundColor Cyan
    Write-Host "    3. Accept routes from Firewalla: " -NoNewline; Write-Host "tailscale up --accept-routes" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  For Firewalla Gold setup, run:" -ForegroundColor White
    Write-Host "    ./0817_Configure-RemoteAccess.ps1 -ShowOutput" -ForegroundColor Cyan
    Write-Host ""
}

return @{
    Success = $true
    Action = "Installed"
    TailscaleIP = (Get-TailscaleIP)
}

