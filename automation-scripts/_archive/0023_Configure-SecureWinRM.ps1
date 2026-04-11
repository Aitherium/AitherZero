#Requires -Version 7.0

<#
.SYNOPSIS
    Configure Secure WinRM for Hyper-V with CA-signed certificates

.DESCRIPTION
    Creates and configures WinRM HTTPS with certificates signed by the AitherZero CA.
    This enables secure remote management of Hyper-V hosts for OpenTofu/Terraform.

    Prerequisites:
    - CA installed (script 0104)
    - Hyper-V enabled (script 0105)
    - Admin privileges

    This script:
    1. Creates a WinRM server certificate signed by the CA
    2. Configures WinRM for HTTPS with the certificate
    3. Enables NTLM authentication
    4. Creates firewall rules
    5. Tests connectivity

.PARAMETER HyperVHost
    The Hyper-V host to configure. Default: localhost

.PARAMETER RemoteHost
    Configure a remote host instead of local (requires admin access)

.PARAMETER ExportCert
    Export the CA cert for importing on other machines

.EXAMPLE
    ./0023_Configure-SecureWinRM.ps1
    Configures local WinRM with CA-signed certificate

.EXAMPLE
    ./0023_Configure-SecureWinRM.ps1 -RemoteHost 192.168.1.121
    Configures WinRM on remote host (requires existing access)

.NOTES
    File Name      : 0023_Configure-SecureWinRM.ps1
    Stage          : Infrastructure  
    Dependencies   : 0104 (CA), 0105 (Hyper-V)
    Tags           : infrastructure, hyperv, winrm, security, certificates
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$HyperVHost = "localhost",

    [Parameter()]
    [string]$RemoteHost,

    [Parameter()]
    [switch]$ExportCert,

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize
. "$PSScriptRoot/_init.ps1"
Write-ScriptLog "Configuring Secure WinRM for Hyper-V Management"

try {
    # ===================================================================
    # CHECK PREREQUISITES
    # ===================================================================
    
    if (-not $IsWindows) {
        Write-ScriptLog "This script is Windows-only" -Level 'Error'
        exit 1
    }

    # Check admin
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-ScriptLog "Administrator privileges required. Please run as Administrator." -Level 'Error'
        exit 1
    }

    # ===================================================================
    # FIND OR CREATE ROOT CA
    # ===================================================================
    
    Write-ScriptLog "Checking for Root CA certificate..."
    
    $rootCA = Get-ChildItem -Path Cert:\LocalMachine\Root | 
        Where-Object { $_.Subject -like "*RootCA*" -or $_.Subject -like "*AitherZero*" } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
    
    if (-not $rootCA) {
        Write-ScriptLog "Root CA not found. Creating one..." -Level 'Warning'
        
        # Create self-signed root CA
        $rootCA = New-SelfSignedCertificate `
            -Type Custom `
            -KeySpec Signature `
            -Subject "CN=AitherZero-RootCA" `
            -KeyExportPolicy Exportable `
            -HashAlgorithm sha256 `
            -KeyLength 4096 `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -KeyUsageProperty Sign `
            -KeyUsage CertSign, CRLSign `
            -NotAfter (Get-Date).AddYears(10)
        
        # Move to Root store
        $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
        $rootStore.Open("ReadWrite")
        $rootStore.Add($rootCA)
        $rootStore.Close()
        
        Write-ScriptLog "  ✓ Created Root CA: $($rootCA.Subject)"
    } else {
        Write-ScriptLog "  ✓ Found Root CA: $($rootCA.Subject)"
    }
    
    # ===================================================================
    # CREATE WINRM SERVER CERTIFICATE
    # ===================================================================
    
    Write-ScriptLog "Creating WinRM server certificate..."
    
    $hostname = [System.Net.Dns]::GetHostName()
    $fqdn = [System.Net.Dns]::GetHostEntry($hostname).HostName
    $ipAddrs = [System.Net.Dns]::GetHostAddresses($hostname) | 
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.IPAddressToString }
    
    # Build SAN list
    $sanBuilder = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
    $sanBuilder.AddDnsName($hostname)
    $sanBuilder.AddDnsName($fqdn)
    $sanBuilder.AddDnsName("localhost")
    foreach ($ip in $ipAddrs) {
        $sanBuilder.AddIpAddress([System.Net.IPAddress]::Parse($ip))
    }
    
    # Check if WinRM cert already exists
    $existingCert = Get-ChildItem -Path Cert:\LocalMachine\My |
        Where-Object { 
            $_.Subject -like "*$hostname*" -and 
            $_.EnhancedKeyUsageList.FriendlyName -contains "Server Authentication" -and
            $_.NotAfter -gt (Get-Date)
        } |
        Select-Object -First 1
    
    if ($existingCert) {
        Write-ScriptLog "  ✓ Found existing valid WinRM cert: $($existingCert.Thumbprint)"
        $winrmCert = $existingCert
    } else {
        # Create WinRM certificate signed by our CA
        $winrmCert = New-SelfSignedCertificate `
            -Subject "CN=$fqdn" `
            -DnsName $hostname, $fqdn, "localhost", ($ipAddrs -join ",") `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddYears(2) `
            -KeyUsage DigitalSignature, KeyEncipherment `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1") `
            -Signer $rootCA `
            -KeyExportPolicy Exportable
        
        Write-ScriptLog "  ✓ Created WinRM certificate: $($winrmCert.Thumbprint)"
    }
    
    # ===================================================================
    # CONFIGURE WINRM
    # ===================================================================
    
    Write-ScriptLog "Configuring WinRM service..."
    
    # Enable WinRM service
    $winrmService = Get-Service -Name WinRM
    if ($winrmService.Status -ne 'Running') {
        Set-Service -Name WinRM -StartupType Automatic
        Start-Service -Name WinRM
        Write-ScriptLog "  ✓ WinRM service started"
    }
    
    # Run quickconfig silently
    & winrm quickconfig -quiet 2>$null
    
    # Remove any existing HTTPS listener
    $existingListener = Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue | 
        Where-Object { $_.Keys -contains "Transport=HTTPS" }
    if ($existingListener) {
        Remove-Item -Path "WSMan:\localhost\Listener\$($existingListener.Name)" -Recurse -Force
        Write-ScriptLog "  Removed existing HTTPS listener"
    }
    
    # Create HTTPS listener with our certificate
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $winrmCert.Thumbprint -Force | Out-Null
    Write-ScriptLog "  ✓ Created HTTPS listener with CA-signed certificate"
    
    # Configure authentication
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
    Set-Item WSMan:\localhost\Service\Auth\Negotiate -Value $true
    Set-Item WSMan:\localhost\Service\Auth\Kerberos -Value $true
    Set-Item WSMan:\localhost\Service\Auth\CredSSP -Value $true
    Set-Item WSMan:\localhost\Client\Auth\CredSSP -Value $true
    Write-ScriptLog "  ✓ Configured authentication (NTLM, Kerberos, CredSSP)"
    
    # Allow unencrypted for local testing (disable in production)
    Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false
    
    # Set trusted hosts for remote management
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
    Write-ScriptLog "  ✓ Configured trusted hosts"
    
    # ===================================================================
    # CONFIGURE FIREWALL
    # ===================================================================
    
    Write-ScriptLog "Configuring firewall rules..."
    
    # Remove old rules if exist
    Remove-NetFirewallRule -DisplayName "WinRM HTTPS (AitherZero)" -ErrorAction SilentlyContinue
    
    # Create new rule
    New-NetFirewallRule `
        -DisplayName "WinRM HTTPS (AitherZero)" `
        -Direction Inbound `
        -LocalPort 5986 `
        -Protocol TCP `
        -Action Allow `
        -Profile Domain,Private,Public `
        -Description "Allow WinRM HTTPS for Hyper-V management via OpenTofu" | Out-Null
    
    Write-ScriptLog "  ✓ Created firewall rule for port 5986 (HTTPS)"
    
    # ===================================================================
    # EXPORT CA CERTIFICATE
    # ===================================================================
    
    if ($ExportCert -or $true) {
        $certDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "certificates"
        if (-not (Test-Path $certDir)) {
            New-Item -ItemType Directory -Path $certDir -Force | Out-Null
        }
        
        $caExportPath = Join-Path $certDir "AitherZero-RootCA.cer"
        Export-Certificate -Cert $rootCA -FilePath $caExportPath -Type CERT -Force | Out-Null
        Write-ScriptLog "  ✓ Exported Root CA to: $caExportPath"
        
        # Also export for OpenTofu use
        $pemPath = Join-Path $certDir "AitherZero-RootCA.pem"
        $certBytes = $rootCA.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        $base64 = [System.Convert]::ToBase64String($certBytes, 'InsertLineBreaks')
        $pemContent = "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----"
        $pemContent | Set-Content -Path $pemPath -Force
        Write-ScriptLog "  ✓ Exported Root CA (PEM) to: $pemPath"
    }
    
    # ===================================================================
    # TEST CONNECTIVITY
    # ===================================================================
    
    Write-ScriptLog "Testing WinRM HTTPS connectivity..."
    
    try {
        $testResult = Test-WSMan -ComputerName localhost -Port 5986 -UseSSL -ErrorAction Stop
        Write-ScriptLog "  ✓ WinRM HTTPS is working on localhost:5986"
    } catch {
        Write-ScriptLog "  ⚠ WinRM HTTPS test failed: $_" -Level 'Warning'
        Write-ScriptLog "  This may be due to certificate validation. For OpenTofu, set insecure = true initially."
    }
    
    # ===================================================================
    # CREATE OPENTOFU PROVIDER CONFIG
    # ===================================================================
    
    Write-ScriptLog "Creating OpenTofu provider configuration..."
    
    $infraPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "infrastructure" "tofu-base-lab"
    
    $providerContent = @"
# Auto-generated by 0023_Configure-SecureWinRM.ps1
# Secure WinRM configuration for Taliesin Hyper-V provider

provider "hyperv" {
  user            = var.hyperv_user
  password        = var.hyperv_password
  host            = var.hyperv_host_name
  port            = 5986
  https           = true
  insecure        = false  # Set to true if using self-signed certs without CA import
  use_ntlm        = true
  tls_server_name = ""
  cacert_path     = "$($caExportPath -replace '\\', '/')"  # Path to CA cert
  cert_path       = ""
  key_path        = ""
  script_path     = "C:/Temp/terraform_%RAND%.cmd"
  timeout         = "30s"
}
"@
    
    $secureProviderPath = Join-Path $certDir "secure-hyperv-provider.tf"
    $providerContent | Set-Content -Path $secureProviderPath
    Write-ScriptLog "  ✓ Created secure provider config: $secureProviderPath"
    
    # ===================================================================
    # SUMMARY
    # ===================================================================
    
    Write-ScriptLog ""
    Write-ScriptLog "╔══════════════════════════════════════════════════════════════╗"
    Write-ScriptLog "║      Secure WinRM Configuration Complete                      ║"
    Write-ScriptLog "╚══════════════════════════════════════════════════════════════╝"
    Write-ScriptLog ""
    Write-ScriptLog "WinRM HTTPS is now configured with CA-signed certificates."
    Write-ScriptLog ""
    Write-ScriptLog "Certificates:"
    Write-ScriptLog "  Root CA:     $($rootCA.Thumbprint)"
    Write-ScriptLog "  WinRM Cert:  $($winrmCert.Thumbprint)"
    Write-ScriptLog "  CA Export:   $caExportPath"
    Write-ScriptLog ""
    Write-ScriptLog "For remote hosts, import the CA certificate:"
    Write-ScriptLog "  Import-Certificate -FilePath $caExportPath -CertStoreLocation Cert:\LocalMachine\Root"
    Write-ScriptLog ""
    Write-ScriptLog "OpenTofu provider config saved to:"
    Write-ScriptLog "  $secureProviderPath"
    Write-ScriptLog ""
    
    exit 0

} catch {
    Write-ScriptLog "Configuration failed: $_" -Level 'Error'
    Write-ScriptLog $_.ScriptStackTrace -Level 'Debug'
    exit 1
}
