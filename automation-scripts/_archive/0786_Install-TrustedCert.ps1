<#
.SYNOPSIS
    Install AitherNet Root CA as a trusted certificate and configure local DNS.

.DESCRIPTION
    This script performs the following:
    1. Installs the AitherNet Root CA certificate to the Windows Trusted Root store
    2. Adds local DNS entries for AitherVeil and other services to hosts file
    3. Optionally issues a certificate for AitherVeil with the custom hostname
    
    After running this script, you can access AitherVeil at:
    - https://aitherveil.local:3000 (with trusted certificate)
    - https://aither.local:3000 (alias)

.PARAMETER Auto
    Fully automated mode - does everything needed without prompts.
    Will self-elevate to Admin if needed.

.PARAMETER InstallRootCA
    Install the Root CA to the Windows Trusted Root Certification Authorities store.
    Requires Administrator privileges.

.PARAMETER ConfigureHosts
    Add local DNS entries to the Windows hosts file.
    Requires Administrator privileges.

.PARAMETER IssueCert
    Issue a certificate for AitherVeil with the configured hostname.

.PARAMETER Hostname
    Primary hostname for AitherVeil. Default: aitherveil.local

.PARAMETER ShowOutput
    Display detailed output.

.EXAMPLE
    # Fully automated (self-elevates if needed)
    ./0786_Install-TrustedCert.ps1 -Auto
    
.EXAMPLE
    # Full setup (requires Admin)
    ./0786_Install-TrustedCert.ps1 -InstallRootCA -ConfigureHosts -IssueCert -ShowOutput
    
.EXAMPLE
    # Just install Root CA
    ./0786_Install-TrustedCert.ps1 -InstallRootCA -ShowOutput

.NOTES
    Author: AitherZero Automation
    Category: Security / PKI
    Script Number: 0786
    Requires: Administrator privileges for -InstallRootCA and -ConfigureHosts
#>

[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$InstallRootCA,
    [switch]$ConfigureHosts,
    [switch]$IssueCert,
    [string]$Hostname = "aitherveil.local",
    [switch]$ShowOutput,
    [switch]$Force
)

# Initialize script environment
. "$PSScriptRoot/_init.ps1"

# Paths
$RootCertPath = Join-Path $env:AITHERZERO_ROOT "AitherOS/AitherNode/data/secrets/ca/root.crt"
$SecretsPort = 8111

# Local hostnames to configure
$LocalHostnames = @(
    @{ Name = "aitherveil.local"; IP = "127.0.0.1"; Description = "AitherVeil Dashboard" },
    @{ Name = "aither.local"; IP = "127.0.0.1"; Description = "AitherVeil Alias" },
    @{ Name = "aithernode.local"; IP = "127.0.0.1"; Description = "AitherNode MCP" },
    @{ Name = "aitherpulse.local"; IP = "127.0.0.1"; Description = "AitherPulse Events" },
    @{ Name = "aitherwatch.local"; IP = "127.0.0.1"; Description = "AitherWatch Monitor" },
    @{ Name = "aithersecrets.local"; IP = "127.0.0.1"; Description = "AitherSecrets Vault" }
)

function Write-Info {
    param([string]$Message)
    if ($ShowOutput) {
        Write-Host "  $Message" -ForegroundColor Cyan
    }
}

function Write-Success {
    param([string]$Message)
    if ($ShowOutput) {
        Write-Host "✅ $Message" -ForegroundColor Green
    }
}

function Write-Warn {
    param([string]$Message)
    if ($ShowOutput) {
        Write-Host "⚠️  $Message" -ForegroundColor Yellow
    }
}

function Write-Err {
    param([string]$Message)
    if ($ShowOutput) {
        Write-Host "❌ $Message" -ForegroundColor Red
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-RootCertificate {
    Write-Info "Installing AitherNet Root CA to Trusted Root store..."
    
    if (-not (Test-Path $RootCertPath)) {
        Write-Err "Root CA certificate not found at: $RootCertPath"
        Write-Err "Run 0785_Deploy-AitherCA.ps1 -InitRoot first"
        return $false
    }
    
    if (-not (Test-Administrator)) {
        Write-Err "Administrator privileges required to install certificates"
        Write-Warn "Re-run this script as Administrator"
        return $false
    }
    
    try {
        # Import the certificate
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($RootCertPath)
        
        # Check if already installed
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
        $store.Open("ReadOnly")
        $existing = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        $store.Close()
        
        if ($existing -and -not $Force) {
            Write-Success "Root CA already installed (Thumbprint: $($cert.Thumbprint.Substring(0,16))...)"
            return $true
        }
        
        # Install to Trusted Root store
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
        $store.Open("ReadWrite")
        $store.Add($cert)
        $store.Close()
        
        Write-Success "Root CA installed successfully"
        Write-Info "  Subject: $($cert.Subject)"
        Write-Info "  Thumbprint: $($cert.Thumbprint)"
        Write-Info "  Valid until: $($cert.NotAfter)"
        
        return $true
    }
    catch {
        Write-Err "Failed to install certificate: $_"
        return $false
    }
}

function Add-HostsEntries {
    Write-Info "Configuring local DNS entries in hosts file..."
    
    if (-not (Test-Administrator)) {
        Write-Err "Administrator privileges required to modify hosts file"
        Write-Warn "Re-run this script as Administrator"
        return $false
    }
    
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsPath -Raw
    
    $added = 0
    $skipped = 0
    
    foreach ($entry in $LocalHostnames) {
        $pattern = "(?m)^\s*[\d\.]+\s+$([regex]::Escape($entry.Name))\s*$"
        
        if ($hostsContent -match $pattern) {
            Write-Info "  Skipping $($entry.Name) - already exists"
            $skipped++
        }
        else {
            # Add entry with comment
            $newEntry = "`n$($entry.IP)`t$($entry.Name)`t# $($entry.Description)"
            Add-Content -Path $hostsPath -Value $newEntry -Encoding UTF8
            Write-Success "Added: $($entry.IP) $($entry.Name)"
            $added++
        }
    }
    
    # Flush DNS cache
    if ($added -gt 0) {
        ipconfig /flushdns | Out-Null
        Write-Success "DNS cache flushed"
    }
    
    Write-Success "Hosts configuration complete: $added added, $skipped skipped"
    return $true
}

function New-AitherVeilCertificate {
    param([string]$Hostname)
    
    Write-Info "Issuing certificate for AitherVeil ($Hostname)..."
    
    # Check if AitherSecrets is running
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:$SecretsPort/health" -TimeoutSec 5
        if ($health.status -ne "healthy") {
            Write-Err "AitherSecrets is not healthy"
            return $false
        }
    }
    catch {
        Write-Err "AitherSecrets is not running on port $SecretsPort"
        Write-Warn "Start it with: ./0784_Start-AitherSecrets.ps1"
        return $false
    }
    
    # Issue certificate with custom SANs
    $body = @{
        validity_days = 365
        san_dns = @($Hostname, "aither.local", "localhost")
        san_ips = @("127.0.0.1")
        key_type = "ec"
    } | ConvertTo-Json
    
    try {
        $result = Invoke-RestMethod -Uri "http://localhost:$SecretsPort/ca/issue/AitherVeil" -Method Post -Body $body -ContentType "application/json"
        
        if ($result.status -eq "success") {
            Write-Success "Certificate issued for AitherVeil"
            Write-Info "  Serial: $($result.serial_number)"
            Write-Info "  Valid until: $($result.valid_until)"
            Write-Info "  Cert path: $($result.cert_path)"
            Write-Info "  Key path: $($result.key_path)"
            
            # Output the certificate paths for Next.js configuration
            Write-Host ""
            Write-Host "To enable HTTPS in AitherVeil, add to .env.local:" -ForegroundColor Yellow
            Write-Host "  HTTPS=true"
            Write-Host "  SSL_CRT_FILE=$($result.cert_path)"
            Write-Host "  SSL_KEY_FILE=$($result.key_path)"
            
            return $true
        }
        else {
            Write-Err "Failed to issue certificate"
            return $false
        }
    }
    catch {
        Write-Err "Error issuing certificate: $_"
        return $false
    }
}

function Show-Status {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║           AITHERNET PKI STATUS                            ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    # Check Root CA in store
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $store.Open("ReadOnly")
    $aithercerts = $store.Certificates | Where-Object { $_.Subject -like "*AitherNet*" -or $_.Subject -like "*AitherZero*" }
    $store.Close()
    
    if ($aithercerts) {
        Write-Host "  🔐 Root CA in Windows Store: " -NoNewline
        Write-Host "INSTALLED" -ForegroundColor Green
        foreach ($cert in $aithercerts) {
            Write-Host "       Subject: $($cert.Subject)"
            Write-Host "       Expires: $($cert.NotAfter)"
        }
    }
    else {
        Write-Host "  🔐 Root CA in Windows Store: " -NoNewline
        Write-Host "NOT INSTALLED" -ForegroundColor Yellow
    }
    
    Write-Host ""
    
    # Check hosts file
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsPath -Raw
    
    Write-Host "  📋 Local DNS Entries:" -ForegroundColor White
    foreach ($entry in $LocalHostnames) {
        $pattern = "(?m)^\s*[\d\.]+\s+$([regex]::Escape($entry.Name))"
        if ($hostsContent -match $pattern) {
            Write-Host "       ✅ $($entry.Name)" -ForegroundColor Green
        }
        else {
            Write-Host "       ❌ $($entry.Name)" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    
    # Check AitherVeil cert (cert data still in AitherNode secrets)
    $veilCertPath = Join-Path $env:AITHERZERO_ROOT "AitherOS/AitherNode/data/secrets/ca/issued/aitherveil.crt"
    if (Test-Path $veilCertPath) {
        Write-Host "  📜 AitherVeil Certificate: " -NoNewline
        Write-Host "ISSUED" -ForegroundColor Green
    }
    else {
        Write-Host "  📜 AitherVeil Certificate: " -NoNewline
        Write-Host "NOT ISSUED" -ForegroundColor Yellow
    }
    
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║           AITHERNET PKI SETUP                             ║" -ForegroundColor Magenta
Write-Host "║     Trusted Certificates & Local DNS                      ║" -ForegroundColor Magenta
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

$exitCode = 0

# Show current status first
Show-Status

if ($InstallRootCA) {
    Write-Host ""
    $result = Install-RootCertificate
    if (-not $result) { $exitCode = 1 }
}

if ($ConfigureHosts) {
    Write-Host ""
    $result = Add-HostsEntries
    if (-not $result) { $exitCode = 1 }
}

if ($IssueCert) {
    Write-Host ""
    $result = New-AitherVeilCertificate -Hostname $Hostname
    if (-not $result) { $exitCode = 1 }
}

# Show final status if any changes made
if ($InstallRootCA -or $ConfigureHosts -or $IssueCert) {
    Write-Host ""
    Show-Status
}

# If no operation specified, show help
if (-not ($InstallRootCA -or $ConfigureHosts -or $IssueCert)) {
    Write-Host "Usage:" -ForegroundColor White
    Write-Host "  -InstallRootCA    Install Root CA to Windows Trusted Root store (Admin required)"
    Write-Host "  -ConfigureHosts   Add local DNS entries to hosts file (Admin required)"
    Write-Host "  -IssueCert        Issue certificate for AitherVeil"
    Write-Host "  -Hostname <name>  Custom hostname (default: aitherveil.local)"
    Write-Host "  -Force            Overwrite existing certificate/entries"
    Write-Host ""
    Write-Host "Example - Full setup (run as Admin):" -ForegroundColor Yellow
    Write-Host "  ./0786_Install-TrustedCert.ps1 -InstallRootCA -ConfigureHosts -IssueCert -ShowOutput"
    Write-Host ""
}

exit $exitCode
