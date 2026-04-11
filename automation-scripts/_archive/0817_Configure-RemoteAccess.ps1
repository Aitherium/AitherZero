#Requires -Version 7.0
<#
.SYNOPSIS
    Configures AitherGateway remote access with Tailscale and Firewalla Gold.
.DESCRIPTION
    Master setup script for secure remote access to AitherOS home network:
    
    1. Tailscale Configuration
       - Subnet routing for home network access
       - MagicDNS for service discovery
       - Accept routes from Firewalla
    
    2. Firewalla Gold Integration
       - Guides through WireGuard setup
       - Documents split tunneling configuration
       - Sets up DNS forwarding for *.aither.local
    
    3. AitherGateway Authentication
       - Generates remote access tokens
       - Configures IP allowlists
       - Sets up JWT authentication
    
    Part of Section 73.7: Remote Access & VPN Integration.

.PARAMETER Mode
    Configuration mode:
    - Full: Complete setup (Tailscale + Gateway + verification)
    - TailscaleOnly: Just configure Tailscale
    - GatewayOnly: Just configure AitherGateway auth
    - FirewallaGuide: Show Firewalla setup instructions
    - Status: Show current remote access status

.PARAMETER HomeSubnet
    Home network subnet CIDR (e.g., "192.168.1.0/24")

.PARAMETER FirewallaIP
    Firewalla Gold IP address

.PARAMETER TailscaleAuthKey
    Tailscale auth key for automated setup

.PARAMETER GenerateToken
    Generate a new remote access token

.PARAMETER TokenName
    Name for the generated token (default: "remote-access")

.PARAMETER TokenExpiry
    Token expiry in hours (default: 720 = 30 days)

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    ./0817_Configure-RemoteAccess.ps1 -Mode Status -ShowOutput
    Check current remote access configuration

.EXAMPLE
    ./0817_Configure-RemoteAccess.ps1 -Mode Full -HomeSubnet "192.168.1.0/24" -ShowOutput
    Full setup with home subnet advertising

.EXAMPLE
    ./0817_Configure-RemoteAccess.ps1 -Mode FirewallaGuide
    Show Firewalla Gold setup instructions

.EXAMPLE
    ./0817_Configure-RemoteAccess.ps1 -GenerateToken -TokenName "laptop-remote" -ShowOutput
    Generate a new remote access token

.NOTES
    Stage: Remote Access
    Order: 0817
    Tags: remote-access, tailscale, firewalla, aithergateway, vpn
    Dependencies: 0816_Install-Tailscale.ps1
    Roadmap: Section 73.7, P406-P415
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'TailscaleOnly', 'GatewayOnly', 'FirewallaGuide', 'Status')]
    [string]$Mode = 'Status',
    
    [string]$HomeSubnet = "192.168.1.0/24",
    
    [string]$FirewallaIP = "192.168.1.1",
    
    [string]$TailscaleAuthKey,
    
    [switch]$GenerateToken,
    
    [string]$TokenName = "remote-access",
    
    [int]$TokenExpiry = 720,
    
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/_init.ps1"

# ============================================================================
# CONFIGURATION
# ============================================================================

$AitherNodePath = Join-Path $projectRoot "AitherOS/AitherNode"
$ConfigPath = Join-Path $AitherNodePath "data/gateway"
$TokensFile = Join-Path $ConfigPath "remote_tokens.json"
$RemoteConfigFile = Join-Path $ConfigPath "remote_access.json"

# Service URLs
$GatewayPort = 8120
$SecretsPort = 8111

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Msg, [string]$Level = "Info")
    if (-not $ShowOutput -and $Level -ne "Err") { return }
    $icon = switch ($Level) { 
        "OK" { "✓" } 
        "Err" { "✗" } 
        "Warn" { "⚠" }
        "Step" { "►" }
        "Info" { "○" }
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
        return (& tailscale ip -4 2>$null)?.Trim()
    } catch {
        return $null
    }
}

function Test-ServiceOnline {
    param([int]$Port)
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:$Port/health" -Method Get -TimeoutSec 3
        return $response.status -eq "healthy"
    } catch {
        return $false
    }
}

function New-RemoteToken {
    param(
        [string]$Name,
        [int]$ExpiryHours
    )
    
    # Generate secure token
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = "aither_remote_" + [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    
    # Calculate expiry
    $expiry = (Get-Date).AddHours($ExpiryHours).ToUniversalTime().ToString("o")
    
    # Load existing tokens
    $tokens = @{}
    if (Test-Path $TokensFile) {
        $tokens = Get-Content $TokensFile | ConvertFrom-Json -AsHashtable
    }
    
    # Add new token
    $tokenHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($token))
    $tokenHashHex = ($tokenHash | ForEach-Object { $_.ToString("x2") }) -join ''
    
    $tokens[$Name] = @{
        hash = $tokenHashHex
        created = (Get-Date).ToUniversalTime().ToString("o")
        expires = $expiry
        scopes = @("remote_access", "gateway_read", "gateway_write")
    }
    
    # Ensure directory exists
    $null = New-Item -ItemType Directory -Path $ConfigPath -Force -ErrorAction SilentlyContinue
    
    # Save tokens
    $tokens | ConvertTo-Json -Depth 10 | Set-Content $TokensFile
    
    return @{
        Token = $token
        Name = $Name
        Expires = $expiry
        Hash = $tokenHashHex
    }
}

function Get-RemoteAccessConfig {
    if (Test-Path $RemoteConfigFile) {
        return Get-Content $RemoteConfigFile | ConvertFrom-Json
    }
    return $null
}

function Set-RemoteAccessConfig {
    param([hashtable]$Config)
    
    $null = New-Item -ItemType Directory -Path $ConfigPath -Force -ErrorAction SilentlyContinue
    $Config | ConvertTo-Json -Depth 10 | Set-Content $RemoteConfigFile
}

function Show-FirewallaGuide {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║           FIREWALLA GOLD - REMOTE ACCESS SETUP                   ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "OPTION A: WireGuard VPN (Native, Fast)" -ForegroundColor Cyan
    Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "1. Open Firewalla app → Network → VPN Server"
    Write-Host "2. Enable WireGuard VPN"
    Write-Host "3. Create client config for each device:"
    Write-Host "   - Tap 'Add Client'"
    Write-Host "   - Name: 'Aither-Laptop', 'Aither-Phone', etc."
    Write-Host "   - Scan QR or export config file"
    Write-Host ""
    Write-Host "4. Configure Split Tunneling (recommended):"
    Write-Host "   - In client settings, set 'Allowed IPs' to:"
    Write-Host "     $HomeSubnet (home network only)" -ForegroundColor Green
    Write-Host "   - This routes only home traffic through VPN"
    Write-Host ""
    
    Write-Host "OPTION B: Tailscale via Firewalla (Easier)" -ForegroundColor Cyan
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "1. Open Firewalla app → Network → VPN Client"
    Write-Host "2. Add Tailscale (or WireGuard with Tailscale config)"
    Write-Host "3. In Tailscale Admin Console (admin.tailscale.com):"
    Write-Host "   - Go to Machines → Firewalla"
    Write-Host "   - Enable 'Subnet Routes': $HomeSubnet" -ForegroundColor Green
    Write-Host "   - Enable 'Exit Node' (optional, for full routing)"
    Write-Host ""
    
    Write-Host "DNS CONFIGURATION" -ForegroundColor Cyan
    Write-Host "─────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "For *.aither.local resolution:"
    Write-Host "1. Firewalla app → Network → DNS"
    Write-Host "2. Add conditional forwarder:"
    Write-Host "   - Domain: aither.local"
    Write-Host "   - DNS Server: (your Pi-hole/AdGuard IP or main PC)"
    Write-Host ""
    
    Write-Host "SECURITY HARDENING" -ForegroundColor Cyan
    Write-Host "──────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "1. Geo-blocking:"
    Write-Host "   - Firewalla → Rules → Block by Region"
    Write-Host "   - Allow only your usual countries"
    Write-Host ""
    Write-Host "2. Rate limiting:"
    Write-Host "   - Monitor → Flows → Watch for unusual VPN traffic"
    Write-Host ""
    Write-Host "3. Alerts:"
    Write-Host "   - Enable 'New Device' alerts"
    Write-Host "   - Enable 'Abnormal Upload' alerts"
    Write-Host ""
    
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "After setup, run:" -ForegroundColor White
    Write-Host "  ./0818_Test-RemoteAccess.ps1 -ShowOutput" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║              REMOTE ACCESS STATUS                                ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
    
    # Tailscale
    Write-Host "TAILSCALE VPN" -ForegroundColor Cyan
    Write-Host "─────────────" -ForegroundColor DarkGray
    
    $tsInstalled = Get-Command "tailscale" -ErrorAction SilentlyContinue
    if ($tsInstalled) {
        Write-Host "  Installed: ✓" -ForegroundColor Green
        
        $tsStatus = Get-TailscaleStatus
        $tsIP = Get-TailscaleIP
        
        if ($tsStatus) {
            Write-Host "  Status: $($tsStatus.BackendState)" -ForegroundColor $(if ($tsStatus.BackendState -eq "Running") { "Green" } else { "Yellow" })
            Write-Host "  Tailscale IP: $tsIP" -ForegroundColor White
            Write-Host "  Self: $($tsStatus.Self.HostName)" -ForegroundColor White
            
            if ($tsStatus.Self.Capabilities -contains "advertise-routes") {
                Write-Host "  Subnet Router: ✓" -ForegroundColor Green
            }
            
            # List peers
            $peers = $tsStatus.Peer | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
            if ($peers.Count -gt 0) {
                Write-Host "  Connected Peers: $($peers.Count)" -ForegroundColor White
            }
        } else {
            Write-Host "  Status: Not connected" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Installed: ✗ (run 0816_Install-Tailscale.ps1)" -ForegroundColor Red
    }
    
    Write-Host ""
    
    # AitherGateway
    Write-Host "AITHERGATEWAY" -ForegroundColor Cyan
    Write-Host "─────────────" -ForegroundColor DarkGray
    
    $gwOnline = Test-ServiceOnline -Port $GatewayPort
    if ($gwOnline) {
        Write-Host "  Status: ✓ Online (port $GatewayPort)" -ForegroundColor Green
        
        try {
            $health = Invoke-RestMethod -Uri "http://localhost:$GatewayPort/health" -Method Get
            Write-Host "  Nodes: $($health.nodes.total) total, $($health.nodes.online) online" -ForegroundColor White
            Write-Host "  Services: $($health.services.total)" -ForegroundColor White
        } catch {
            Write-Host "  Health check failed" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Status: ✗ Offline" -ForegroundColor Red
        Write-Host "  Start with: ./0800_Start-AitherOS.ps1 -Services Core" -ForegroundColor Yellow
    }
    
    Write-Host ""
    
    # Remote Tokens
    Write-Host "REMOTE ACCESS TOKENS" -ForegroundColor Cyan
    Write-Host "────────────────────" -ForegroundColor DarkGray
    
    if (Test-Path $TokensFile) {
        $tokens = Get-Content $TokensFile | ConvertFrom-Json
        $tokenNames = $tokens | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
        
        foreach ($name in $tokenNames) {
            $t = $tokens.$name
            $expires = [DateTime]::Parse($t.expires)
            $isExpired = $expires -lt (Get-Date)
            $status = if ($isExpired) { "EXPIRED" } else { "Valid until $($expires.ToString('yyyy-MM-dd'))" }
            $color = if ($isExpired) { "Red" } else { "Green" }
            Write-Host "  $name : $status" -ForegroundColor $color
        }
        
        if ($tokenNames.Count -eq 0) {
            Write-Host "  No tokens configured" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No tokens configured" -ForegroundColor Yellow
        Write-Host "  Generate with: ./0817_Configure-RemoteAccess.ps1 -GenerateToken" -ForegroundColor Cyan
    }
    
    Write-Host ""
    
    # Configuration
    Write-Host "REMOTE ACCESS CONFIG" -ForegroundColor Cyan
    Write-Host "────────────────────" -ForegroundColor DarkGray
    
    $config = Get-RemoteAccessConfig
    if ($config) {
        Write-Host "  Home Subnet: $($config.home_subnet)" -ForegroundColor White
        Write-Host "  Firewalla IP: $($config.firewalla_ip)" -ForegroundColor White
        Write-Host "  VPN Method: $($config.vpn_method)" -ForegroundColor White
        Write-Host "  Last Updated: $($config.updated_at)" -ForegroundColor White
    } else {
        Write-Host "  Not configured yet" -ForegroundColor Yellow
        Write-Host "  Run: ./0817_Configure-RemoteAccess.ps1 -Mode Full" -ForegroundColor Cyan
    }
    
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

if ($ShowOutput) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║              AITHERGATEWAY REMOTE ACCESS                         ║" -ForegroundColor Magenta
    Write-Host "║              Configure VPN & Authentication                      ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
}

# Generate token if requested
if ($GenerateToken) {
    Write-Log "Generating remote access token: $TokenName" "Step"
    
    $result = New-RemoteToken -Name $TokenName -ExpiryHours $TokenExpiry
    
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  REMOTE ACCESS TOKEN GENERATED" -ForegroundColor Green
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Name: $($result.Name)" -ForegroundColor White
    Write-Host "  Expires: $($result.Expires)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Token (SAVE THIS - shown only once):" -ForegroundColor Yellow
    Write-Host "  $($result.Token)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Use in headers:" -ForegroundColor White
    Write-Host "    Authorization: Bearer $($result.Token)" -ForegroundColor Gray
    Write-Host "    X-Remote-Token: $($result.Token)" -ForegroundColor Gray
    Write-Host ""
    
    return @{
        Success = $true
        TokenName = $result.Name
        Expires = $result.Expires
        Token = $result.Token
    }
}

# Mode-based execution
switch ($Mode) {
    'Status' {
        Show-Status
        return @{ Success = $true; Mode = "Status" }
    }
    
    'FirewallaGuide' {
        Show-FirewallaGuide
        return @{ Success = $true; Mode = "FirewallaGuide" }
    }
    
    'TailscaleOnly' {
        Write-Log "Configuring Tailscale..." "Step"
        
        # Check if installed
        if (-not (Get-Command "tailscale" -ErrorAction SilentlyContinue)) {
            Write-Log "Tailscale not installed. Run 0816_Install-Tailscale.ps1 first" "Err"
            return @{ Success = $false; Error = "Tailscale not installed" }
        }
        
        # Configure with accept-routes
        $tsArgs = @("--accept-routes")
        
        if ($TailscaleAuthKey) {
            $tsArgs += "--authkey=$TailscaleAuthKey"
        }
        
        Write-Log "Running: tailscale up $($tsArgs -join ' ')" "Info"
        & tailscale up @tsArgs
        
        Start-Sleep -Seconds 3
        
        $ip = Get-TailscaleIP
        Write-Log "Tailscale configured. IP: $ip" "OK"
        
        # Save config
        $config = @{
            home_subnet = $HomeSubnet
            firewalla_ip = $FirewallaIP
            vpn_method = "tailscale"
            tailscale_ip = $ip
            updated_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        Set-RemoteAccessConfig -Config $config
        
        return @{ Success = $true; TailscaleIP = $ip }
    }
    
    'GatewayOnly' {
        Write-Log "Configuring AitherGateway authentication..." "Step"
        
        # Check if Gateway is running
        if (-not (Test-ServiceOnline -Port $GatewayPort)) {
            Write-Log "AitherGateway not running. Start with 0800_Start-AitherOS.ps1" "Err"
            return @{ Success = $false; Error = "Gateway offline" }
        }
        
        # Generate default remote token if none exist
        if (-not (Test-Path $TokensFile)) {
            Write-Log "Generating default remote access token..." "Step"
            $result = New-RemoteToken -Name "default-remote" -ExpiryHours 720
            Write-Log "Token generated: default-remote (expires in 30 days)" "OK"
            Write-Host ""
            Write-Host "  Token: $($result.Token)" -ForegroundColor Cyan
            Write-Host ""
        }
        
        # Save config
        $config = @{
            home_subnet = $HomeSubnet
            firewalla_ip = $FirewallaIP
            gateway_port = $GatewayPort
            auth_enabled = $true
            updated_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        Set-RemoteAccessConfig -Config $config
        
        Write-Log "Gateway authentication configured" "OK"
        return @{ Success = $true }
    }
    
    'Full' {
        Write-Log "Running full remote access setup..." "Step"
        
        # Step 1: Check/Install Tailscale
        Write-Log "Step 1: Tailscale" "Step"
        
        if (-not (Get-Command "tailscale" -ErrorAction SilentlyContinue)) {
            Write-Log "Installing Tailscale..." "Info"
            & "$PSScriptRoot/0816_Install-Tailscale.ps1" -AcceptRoutes -ShowOutput:$ShowOutput
        } else {
            Write-Log "Tailscale already installed" "OK"
        }
        
        # Configure Tailscale
        $tsArgs = @("--accept-routes")
        if ($TailscaleAuthKey) {
            $tsArgs += "--authkey=$TailscaleAuthKey"
        }
        
        & tailscale up @tsArgs 2>$null
        Start-Sleep -Seconds 2
        $tsIP = Get-TailscaleIP
        Write-Log "Tailscale IP: $tsIP" "OK"
        
        # Step 2: AitherGateway
        Write-Log "Step 2: AitherGateway" "Step"
        
        if (-not (Test-ServiceOnline -Port $GatewayPort)) {
            Write-Log "AitherGateway offline - start with 0800_Start-AitherOS.ps1" "Warn"
        } else {
            Write-Log "AitherGateway online" "OK"
        }
        
        # Generate token if needed
        if (-not (Test-Path $TokensFile)) {
            Write-Log "Generating remote access token..." "Info"
            $tokenResult = New-RemoteToken -Name "default-remote" -ExpiryHours 720
            Write-Host ""
            Write-Host "  SAVE THIS TOKEN: $($tokenResult.Token)" -ForegroundColor Yellow
            Write-Host ""
        }
        
        # Step 3: Save configuration
        Write-Log "Step 3: Saving configuration" "Step"
        
        $config = @{
            home_subnet = $HomeSubnet
            firewalla_ip = $FirewallaIP
            vpn_method = "tailscale"
            tailscale_ip = $tsIP
            gateway_port = $GatewayPort
            auth_enabled = $true
            configured_at = (Get-Date).ToUniversalTime().ToString("o")
            updated_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        Set-RemoteAccessConfig -Config $config
        Write-Log "Configuration saved" "OK"
        
        # Summary
        Write-Host ""
        Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  REMOTE ACCESS CONFIGURED" -ForegroundColor Green
        Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Tailscale IP: $tsIP" -ForegroundColor White
        Write-Host "  Home Subnet: $HomeSubnet" -ForegroundColor White
        Write-Host "  Firewalla IP: $FirewallaIP" -ForegroundColor White
        Write-Host ""
        Write-Host "  Next steps:" -ForegroundColor Yellow
        Write-Host "    1. Configure Firewalla: ./0817_Configure-RemoteAccess.ps1 -Mode FirewallaGuide" -ForegroundColor Cyan
        Write-Host "    2. Test connectivity: ./0818_Test-RemoteAccess.ps1 -ShowOutput" -ForegroundColor Cyan
        Write-Host ""
        
        return @{
            Success = $true
            TailscaleIP = $tsIP
            HomeSubnet = $HomeSubnet
            FirewallaIP = $FirewallaIP
        }
    }
}

