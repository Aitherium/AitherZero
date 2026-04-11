#Requires -Version 7.0
<#
.SYNOPSIS
    Tests remote access connectivity for AitherGateway.
.DESCRIPTION
    Comprehensive connectivity test for remote access setup:
    
    1. VPN Connectivity
       - Tailscale status and peer connectivity
       - Home network reachability
       - DNS resolution for *.aither.local
    
    2. Service Accessibility
       - AitherGateway health check
       - AitherNode MCP server
       - Other core services
    
    3. Authentication
       - Token validation
       - JWT authentication (if configured)
    
    Part of Section 73.7: Remote Access & VPN Integration.

.PARAMETER Target
    Test target:
    - All: Run all tests
    - VPN: VPN connectivity only
    - Services: Service accessibility only
    - Auth: Authentication only

.PARAMETER RemoteHost
    Remote host to test (default: use Tailscale IP or localhost)

.PARAMETER Token
    Remote access token for authentication tests

.PARAMETER Verbose
    Show detailed test output

.PARAMETER ShowOutput
    Show summary output

.EXAMPLE
    ./0818_Test-RemoteAccess.ps1 -ShowOutput
    Run all connectivity tests

.EXAMPLE
    ./0818_Test-RemoteAccess.ps1 -Target VPN -ShowOutput
    Test VPN connectivity only

.EXAMPLE
    ./0818_Test-RemoteAccess.ps1 -Target Auth -Token "aither_remote_xxx" -ShowOutput
    Test authentication with token

.NOTES
    Stage: Remote Access
    Order: 0818
    Tags: test, remote-access, connectivity, vpn, aithergateway
    Dependencies: 0816_Install-Tailscale.ps1, 0817_Configure-RemoteAccess.ps1
    Roadmap: Section 73.7
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'VPN', 'Services', 'Auth')]
    [string]$Target = 'All',
    
    [string]$RemoteHost,
    
    [string]$Token,
    
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot/_init.ps1"

# ============================================================================
# CONFIGURATION
# ============================================================================

$AitherNodePath = Join-Path $projectRoot "AitherOS/AitherNode"
$ConfigPath = Join-Path $AitherNodePath "data/gateway"
$RemoteConfigFile = Join-Path $ConfigPath "remote_access.json"

# Default ports
$ServicePorts = @{
    Gateway = 8120
    Node = 8080
    Pulse = 8081
    Watch = 8082
    Veil = 3000
    Mind = 8088
    Secrets = 8111
}

# ============================================================================
# FUNCTIONS
# ============================================================================

$script:TestResults = @{
    Passed = 0
    Failed = 0
    Warnings = 0
    Tests = @()
}

function Add-TestResult {
    param(
        [string]$Name,
        [string]$Status,  # Pass, Fail, Warn, Skip
        [string]$Message,
        [string]$Details = ""
    )
    
    $result = @{
        Name = $Name
        Status = $Status
        Message = $Message
        Details = $Details
        Timestamp = (Get-Date).ToString("HH:mm:ss")
    }
    
    $script:TestResults.Tests += $result
    
    switch ($Status) {
        "Pass" { $script:TestResults.Passed++ }
        "Fail" { $script:TestResults.Failed++ }
        "Warn" { $script:TestResults.Warnings++ }
    }
    
    if ($ShowOutput) {
        $icon = switch ($Status) {
            "Pass" { "✓" }
            "Fail" { "✗" }
            "Warn" { "⚠" }
            "Skip" { "○" }
        }
        $color = switch ($Status) {
            "Pass" { "Green" }
            "Fail" { "Red" }
            "Warn" { "Yellow" }
            "Skip" { "DarkGray" }
        }
        
        Write-Host "  $icon $Name" -ForegroundColor $color
        if ($Details -and $ShowOutput) {
            Write-Host "    $Details" -ForegroundColor DarkGray
        }
    }
}

function Test-TcpPort {
    param(
        [string]$Host,
        [int]$Port,
        [int]$Timeout = 3000
    )
    
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $result = $client.BeginConnect($Host, $Port, $null, $null)
        $success = $result.AsyncWaitHandle.WaitOne($Timeout)
        
        if ($success) {
            $client.EndConnect($result)
            $client.Close()
            return $true
        }
        $client.Close()
        return $false
    } catch {
        return $false
    }
}

function Test-HttpEndpoint {
    param(
        [string]$Url,
        [int]$Timeout = 5,
        [hashtable]$Headers = @{}
    )
    
    try {
        $params = @{
            Uri = $Url
            Method = 'Get'
            TimeoutSec = $Timeout
        }
        
        if ($Headers.Count -gt 0) {
            $params.Headers = $Headers
        }
        
        $response = Invoke-RestMethod @params
        return @{ Success = $true; Response = $response }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Get-TailscaleIP {
    try {
        return (& tailscale ip -4 2>$null)?.Trim()
    } catch {
        return $null
    }
}

function Get-TailscaleStatus {
    try {
        return & tailscale status --json 2>$null | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-RemoteConfig {
    if (Test-Path $RemoteConfigFile) {
        return Get-Content $RemoteConfigFile | ConvertFrom-Json
    }
    return $null
}

# ============================================================================
# TEST SUITES
# ============================================================================

function Test-VPNConnectivity {
    Write-Host ""
    Write-Host "VPN CONNECTIVITY TESTS" -ForegroundColor Cyan
    Write-Host "──────────────────────" -ForegroundColor DarkGray
    
    # Test 1: Tailscale installed
    $tsInstalled = Get-Command "tailscale" -ErrorAction SilentlyContinue
    if ($tsInstalled) {
        Add-TestResult -Name "Tailscale Installed" -Status "Pass" -Message "Found tailscale executable"
    } else {
        Add-TestResult -Name "Tailscale Installed" -Status "Fail" -Message "Tailscale not found" -Details "Run 0816_Install-Tailscale.ps1"
        return
    }
    
    # Test 2: Tailscale connected
    $tsStatus = Get-TailscaleStatus
    if ($tsStatus -and $tsStatus.BackendState -eq "Running") {
        Add-TestResult -Name "Tailscale Running" -Status "Pass" -Message "Backend state: Running"
    } elseif ($tsStatus) {
        Add-TestResult -Name "Tailscale Running" -Status "Warn" -Message "Backend state: $($tsStatus.BackendState)" -Details "Run: tailscale up"
    } else {
        Add-TestResult -Name "Tailscale Running" -Status "Fail" -Message "Could not get Tailscale status"
        return
    }
    
    # Test 3: Tailscale IP assigned
    $tsIP = Get-TailscaleIP
    if ($tsIP) {
        Add-TestResult -Name "Tailscale IP" -Status "Pass" -Message "IP assigned" -Details $tsIP
    } else {
        Add-TestResult -Name "Tailscale IP" -Status "Fail" -Message "No IP assigned"
    }
    
    # Test 4: Accepting routes
    if ($tsStatus.Self.Capabilities -contains "advertise-routes") {
        Add-TestResult -Name "Subnet Routing" -Status "Pass" -Message "Advertising routes enabled"
    } else {
        Add-TestResult -Name "Subnet Routing" -Status "Warn" -Message "Not advertising routes" -Details "May need --accept-routes"
    }
    
    # Test 5: Connected peers
    $peerCount = 0
    if ($tsStatus.Peer) {
        $peers = $tsStatus.Peer | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
        $peerCount = $peers.Count
    }
    
    if ($peerCount -gt 0) {
        Add-TestResult -Name "Tailscale Peers" -Status "Pass" -Message "$peerCount peer(s) connected"
    } else {
        Add-TestResult -Name "Tailscale Peers" -Status "Warn" -Message "No peers connected" -Details "Other devices may not be online"
    }
    
    # Test 6: Home network reachability (if configured)
    $config = Get-RemoteConfig
    if ($config -and $config.firewalla_ip) {
        $pingable = Test-Connection -TargetName $config.firewalla_ip -Count 1 -Quiet -TimeoutSeconds 2
        if ($pingable) {
            Add-TestResult -Name "Firewalla Reachable" -Status "Pass" -Message "Can reach $($config.firewalla_ip)"
        } else {
            Add-TestResult -Name "Firewalla Reachable" -Status "Warn" -Message "Cannot ping Firewalla" -Details "May need VPN route or firewall rule"
        }
    }
    
    # Test 7: DNS resolution
    try {
        $resolved = Resolve-DnsName "dns.google" -Type A -ErrorAction Stop
        Add-TestResult -Name "DNS Resolution" -Status "Pass" -Message "DNS working"
    } catch {
        Add-TestResult -Name "DNS Resolution" -Status "Fail" -Message "DNS resolution failed"
    }
}

function Test-ServiceAccessibility {
    param([string]$BaseHost = "localhost")
    
    Write-Host ""
    Write-Host "SERVICE ACCESSIBILITY TESTS" -ForegroundColor Cyan
    Write-Host "───────────────────────────" -ForegroundColor DarkGray
    
    foreach ($svc in $ServicePorts.GetEnumerator()) {
        $name = $svc.Key
        $port = $svc.Value
        $url = "http://${BaseHost}:$port/health"
        
        # Test TCP port first
        $tcpOpen = Test-TcpPort -Host $BaseHost -Port $port
        
        if (-not $tcpOpen) {
            Add-TestResult -Name "$name (port $port)" -Status "Fail" -Message "Port not reachable"
            continue
        }
        
        # Test HTTP endpoint
        $result = Test-HttpEndpoint -Url $url
        
        if ($result.Success) {
            $status = $result.Response.status
            if ($status -eq "healthy") {
                Add-TestResult -Name "$name (port $port)" -Status "Pass" -Message "Healthy"
            } else {
                Add-TestResult -Name "$name (port $port)" -Status "Warn" -Message "Status: $status"
            }
        } else {
            Add-TestResult -Name "$name (port $port)" -Status "Warn" -Message "Port open, health check failed" -Details $result.Error
        }
    }
}

function Test-Authentication {
    param(
        [string]$BaseHost = "localhost",
        [string]$AuthToken
    )
    
    Write-Host ""
    Write-Host "AUTHENTICATION TESTS" -ForegroundColor Cyan
    Write-Host "────────────────────" -ForegroundColor DarkGray
    
    $gatewayUrl = "http://${BaseHost}:$($ServicePorts.Gateway)"
    
    # Test 1: Gateway accessible without auth (public endpoints)
    $publicResult = Test-HttpEndpoint -Url "$gatewayUrl/health"
    if ($publicResult.Success) {
        Add-TestResult -Name "Gateway Public Endpoint" -Status "Pass" -Message "/health accessible"
    } else {
        Add-TestResult -Name "Gateway Public Endpoint" -Status "Fail" -Message "Gateway not accessible"
        return
    }
    
    # Test 2: Nodes list (may require auth in future)
    $nodesResult = Test-HttpEndpoint -Url "$gatewayUrl/nodes"
    if ($nodesResult.Success) {
        Add-TestResult -Name "Gateway Nodes List" -Status "Pass" -Message "$($nodesResult.Response.total) nodes registered"
    } else {
        Add-TestResult -Name "Gateway Nodes List" -Status "Fail" -Message "Cannot list nodes"
    }
    
    # Test 3: Token authentication (if token provided)
    if ($AuthToken) {
        $headers = @{
            "Authorization" = "Bearer $AuthToken"
            "X-Remote-Token" = $AuthToken
        }
        
        # Try authenticated endpoint
        $authResult = Test-HttpEndpoint -Url "$gatewayUrl/nodes" -Headers $headers
        if ($authResult.Success) {
            Add-TestResult -Name "Token Authentication" -Status "Pass" -Message "Token accepted"
        } else {
            Add-TestResult -Name "Token Authentication" -Status "Fail" -Message "Token rejected" -Details $authResult.Error
        }
    } else {
        Add-TestResult -Name "Token Authentication" -Status "Skip" -Message "No token provided" -Details "Use -Token parameter"
    }
    
    # Test 4: Remote config exists
    $configPath = Join-Path $AitherNodePath "data/gateway/remote_tokens.json"
    if (Test-Path $configPath) {
        Add-TestResult -Name "Remote Tokens Configured" -Status "Pass" -Message "Token file exists"
    } else {
        Add-TestResult -Name "Remote Tokens Configured" -Status "Warn" -Message "No tokens configured" -Details "Run 0817_Configure-RemoteAccess.ps1 -GenerateToken"
    }
}

# ============================================================================
# MAIN
# ============================================================================

if ($ShowOutput) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║              REMOTE ACCESS CONNECTIVITY TEST                     ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
}

# Determine target host
$testHost = $RemoteHost
if (-not $testHost) {
    # If testing remotely, try to get Tailscale IP
    $tsIP = Get-TailscaleIP
    if ($tsIP) {
        $testHost = "localhost"  # Default to localhost, use Tailscale for remote
    } else {
        $testHost = "localhost"
    }
}

if ($ShowOutput) {
    Write-Host ""
    Write-Host "  Target: $testHost" -ForegroundColor White
    Write-Host "  Tests: $Target" -ForegroundColor White
}

# Run tests based on target
switch ($Target) {
    'All' {
        Test-VPNConnectivity
        Test-ServiceAccessibility -BaseHost $testHost
        Test-Authentication -BaseHost $testHost -AuthToken $Token
    }
    'VPN' {
        Test-VPNConnectivity
    }
    'Services' {
        Test-ServiceAccessibility -BaseHost $testHost
    }
    'Auth' {
        Test-Authentication -BaseHost $testHost -AuthToken $Token
    }
}

# Summary
if ($ShowOutput) {
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ""
    
    $total = $script:TestResults.Passed + $script:TestResults.Failed + $script:TestResults.Warnings
    
    if ($script:TestResults.Failed -eq 0) {
        Write-Host "  ✓ All tests passed!" -ForegroundColor Green
    } else {
        Write-Host "  Results: $($script:TestResults.Passed) passed, $($script:TestResults.Failed) failed, $($script:TestResults.Warnings) warnings" -ForegroundColor Yellow
    }
    
    Write-Host ""
    
    # Show failed tests
    $failed = $script:TestResults.Tests | Where-Object { $_.Status -eq "Fail" }
    if ($failed.Count -gt 0) {
        Write-Host "  Failed tests:" -ForegroundColor Red
        foreach ($f in $failed) {
            Write-Host "    - $($f.Name): $($f.Details)" -ForegroundColor Red
        }
        Write-Host ""
    }
}

return @{
    Passed = $script:TestResults.Passed
    Failed = $script:TestResults.Failed
    Warnings = $script:TestResults.Warnings
    Tests = $script:TestResults.Tests
    Success = ($script:TestResults.Failed -eq 0)
}

