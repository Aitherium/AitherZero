#Requires -Version 7.0
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Set up code signing for AitherOS/AitherZero scripts and executables.
.DESCRIPTION
    Creates a self-signed code signing certificate for development, or imports
    an existing certificate for production. Signs all PowerShell scripts and
    optionally signs all PowerShell scripts in the repository.
    
    This eliminates "Unknown Publisher" UAC prompts by establishing trust.
    
    Modes:
    - Development: Creates self-signed certificate (trusted on this machine)
    - Production: Uses a purchased code signing certificate
    
    After running this script:
    - All .ps1 files will be signed
    - All PowerShell scripts can be signed with -SignAll
    - UAC prompts will show "Aitherium" as the publisher

.PARAMETER Mode
    'Development' creates a self-signed cert (free, local trust only)
    'Production' uses an existing certificate from the store

.PARAMETER CertPath
    Path to .pfx certificate file (for importing existing cert)

.PARAMETER CertPassword
    Password for the .pfx file (will prompt if not provided)

.PARAMETER SignAll
    If set, signs all .ps1 files in the repository

.NOTES
    Stage: Security
    Order: 0610
    
.EXAMPLE
    ./0610_Setup-CodeSigning.ps1 -Mode Development -SignAll
    
.EXAMPLE
    ./0610_Setup-CodeSigning.ps1 -Mode Production -CertPath "C:\certs\aitherium.pfx"
#>

[CmdletBinding()]
param(
    [ValidateSet('Development', 'Production')]
    [string]$Mode = 'Development',
    
    [string]$CertPath,
    
    [SecureString]$CertPassword,

    [switch]$SignAll,
    
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"

# ============================================================================
# CONFIGURATION
# ============================================================================

$CertSubject = "CN=Aitherium, O=Aitherium, L=Brisbane, S=Queensland, C=AU"
$CertFriendlyName = "Aitherium Code Signing Certificate"
$CertStore = "Cert:\CurrentUser\My"
$TrustedPublisherStore = "Cert:\LocalMachine\TrustedPublisher"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Step {
    param([string]$Message, [string]$Status = "Info")
    
    $icon = switch ($Status) {
        "Pass" { "✅" }
        "Fail" { "❌" }
        "Warn" { "⚠️" }
        "Info" { "ℹ️" }
        default { "→" }
    }
    
    $color = switch ($Status) {
        "Pass" { "Green" }
        "Fail" { "Red" }
        "Warn" { "Yellow" }
        default { "Cyan" }
    }
    
    Write-Host "  $icon $Message" -ForegroundColor $color
}

function Get-ExistingCert {
    """Find existing Aitherium code signing certificate."""
    Get-ChildItem $CertStore -CodeSigningCert | Where-Object {
        $_.Subject -like "*Aitherium*" -or $_.FriendlyName -eq $CertFriendlyName
    } | Select-Object -First 1
}

function New-DevelopmentCert {
    """Create a self-signed code signing certificate for development."""
    Write-Host ""
    Write-Host "🔐 Creating Development Code Signing Certificate" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    
    # Check if cert already exists
    $existing = Get-ExistingCert
    if ($existing) {
        Write-Step "Certificate already exists: $($existing.Thumbprint)" "Pass"
        return $existing
    }
    
    # Create the certificate
    Write-Step "Generating self-signed code signing certificate..." "Info"
    
    try {
        $cert = New-SelfSignedCertificate `
            -Subject $CertSubject `
            -Type CodeSigningCert `
            -CertStoreLocation $CertStore `
            -FriendlyName $CertFriendlyName `
            -NotAfter (Get-Date).AddYears(5) `
            -KeyUsage DigitalSignature `
            -KeySpec Signature `
            -KeyLength 4096 `
            -HashAlgorithm SHA256
        
        Write-Step "Certificate created: $($cert.Thumbprint)" "Pass"
        
        # Add to trusted publishers for this machine
        Write-Step "Adding to Trusted Publishers (requires elevation)..." "Info"
        
        try {
            # Export cert (public key only)
            $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $tempCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
            
            # Import to TrustedPublisher store
            $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
                [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher,
                [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
            )
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $store.Add($tempCert)
            $store.Close()
            
            Write-Step "Added to Trusted Publishers store" "Pass"
        }
        catch {
            Write-Step "Could not add to Trusted Publishers: $($_.Exception.Message)" "Warn"
            Write-Step "Scripts will show publisher warning until manually trusted" "Warn"
        }
        
        return $cert
    }
    catch {
        Write-Step "Failed to create certificate: $($_.Exception.Message)" "Fail"
        return $null
    }
}

function Import-ProductionCert {
    """Import a production code signing certificate."""
    Write-Host ""
    Write-Host "🔐 Importing Production Code Signing Certificate" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    
    if (-not $CertPath -or -not (Test-Path $CertPath)) {
        Write-Step "Certificate file not found: $CertPath" "Fail"
        return $null
    }
    
    # Get password if not provided
    if (-not $CertPassword) {
        $CertPassword = Read-Host -AsSecureString -Prompt "Enter certificate password"
    }
    
    try {
        Write-Step "Importing certificate from $CertPath..." "Info"
        
        $cert = Import-PfxCertificate `
            -FilePath $CertPath `
            -CertStoreLocation $CertStore `
            -Password $CertPassword `
            -Exportable
        
        Write-Step "Certificate imported: $($cert.Thumbprint)" "Pass"
        return $cert
    }
    catch {
        Write-Step "Failed to import certificate: $($_.Exception.Message)" "Fail"
        return $null
    }
}

function Sign-File {
    param(
        [string]$FilePath,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )
    
    try {
        $result = Set-AuthenticodeSignature `
            -FilePath $FilePath `
            -Certificate $Certificate `
            -TimestampServer "http://timestamp.digicert.com" `
            -HashAlgorithm SHA256
        
        if ($result.Status -eq 'Valid') {
            return $true
        }
        else {
            Write-Verbose "Sign failed for $FilePath : $($result.StatusMessage)"
            return $false
        }
    }
    catch {
        Write-Verbose "Error signing $FilePath : $($_.Exception.Message)"
        return $false
    }
}

function Sign-AllScripts {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )
    
    Write-Host ""
    Write-Host "📝 Signing PowerShell Scripts" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    
    $scripts = Get-ChildItem $projectRoot -Recurse -Include "*.ps1" | Where-Object {
        # Skip node_modules, .venv, etc.
        $_.FullName -notmatch '(node_modules|\.venv|\.git|vendor)'
    }
    
    $total = $scripts.Count
    $signed = 0
    $skipped = 0
    $failed = 0
    
    Write-Step "Found $total PowerShell scripts to sign" "Info"
    
    foreach ($script in $scripts) {
        # Check if already signed with our cert
        $existing = Get-AuthenticodeSignature $script.FullName
        if ($existing.Status -eq 'Valid' -and $existing.SignerCertificate.Thumbprint -eq $Certificate.Thumbprint) {
            $skipped++
            continue
        }
        
        if (Sign-File -FilePath $script.FullName -Certificate $Certificate) {
            $signed++
            if ($ShowOutput) {
                Write-Host "    ✓ $($script.Name)" -ForegroundColor DarkGray
            }
        }
        else {
            $failed++
            Write-Host "    ✗ $($script.Name)" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    Write-Step "Signed: $signed, Skipped: $skipped, Failed: $failed" $(if ($failed -eq 0) { "Pass" } else { "Warn" })
}

# Sign-NSSM function removed - NSSM is deprecated, using Servy now

# ============================================================================
# MAIN
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║          🔐 AITHER CODE SIGNING SETUP 🔐                      ║" -ForegroundColor Magenta
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Mode: $Mode" -ForegroundColor Cyan

# Get or create certificate
$cert = switch ($Mode) {
    'Development' { New-DevelopmentCert }
    'Production'  { Import-ProductionCert }
}

if (-not $cert) {
    Write-Host ""
    Write-Host "❌ Failed to obtain code signing certificate" -ForegroundColor Red
    exit 1
}

# Display certificate info
Write-Host ""
Write-Host "📜 Certificate Details" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Step "Subject: $($cert.Subject)" "Info"
Write-Step "Thumbprint: $($cert.Thumbprint)" "Info"
Write-Step "Expires: $($cert.NotAfter.ToString('yyyy-MM-dd'))" "Info"

# Sign scripts if requested
if ($SignAll) {
    Sign-AllScripts -Certificate $cert
}

# Summary
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host "✅ Code signing setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Run with -SignAll to sign all scripts"
Write-Host "  2. For production, purchase a code signing certificate from DigiCert/Sectigo"
Write-Host ""
