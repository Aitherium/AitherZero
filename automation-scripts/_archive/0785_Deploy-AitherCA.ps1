<#
.SYNOPSIS
    Deploy and initialize the AitherNet Certificate Authority.

.DESCRIPTION
    This script initializes the AitherCA (Certificate Authority) infrastructure
    via the AitherSecrets API. It creates a Root CA, Intermediate CA, and can
    issue service certificates for mTLS communication between AitherNet services.
    
    Certificate Hierarchy:
        Root CA (20-year validity, offline after init)
          └── Intermediate CA (5-year validity, signs service certs)
                ├── AitherNode Service Cert
                ├── AitherPulse Service Cert
                └── ... (all AitherNet services)

.PARAMETER InitRoot
    Initialize the Root CA. This should only be done ONCE.
    
.PARAMETER InitIntermediate
    Initialize the Intermediate CA (requires Root CA).
    
.PARAMETER IssueAll
    Issue certificates for all known AitherNet services.
    
.PARAMETER IssueFor
    Issue a certificate for a specific service.
    
.PARAMETER Status
    Show CA status without making changes.
    
.PARAMETER ListCerts
    List all issued certificates.
    
.PARAMETER SecretsPort
    Port where AitherSecrets is running. Default: 8111.
    
.PARAMETER ShowOutput
    Display detailed output (silent by default for pipelines).

.EXAMPLE
    # Full CA deployment (Root + Intermediate + all service certs)
    ./0785_Deploy-AitherCA.ps1 -InitRoot -InitIntermediate -IssueAll -ShowOutput
    
.EXAMPLE
    # Issue cert for a specific service
    ./0785_Deploy-AitherCA.ps1 -IssueFor "AitherMind" -ShowOutput
    
.EXAMPLE
    # Check CA status
    ./0785_Deploy-AitherCA.ps1 -Status -ShowOutput

.NOTES
    Author: AitherZero Automation
    Category: Security / PKI
    Script Number: 0785
    Dependencies: AitherSecrets must be running
#>

[CmdletBinding()]
param(
    [switch]$InitRoot,
    [switch]$InitIntermediate,
    [switch]$IssueAll,
    [string]$IssueFor,
    [switch]$Status,
    [switch]$ListCerts,
    [int]$SecretsPort = 8111,
    [switch]$ShowOutput
)

# Initialize script environment
. "$PSScriptRoot/_init.ps1"

# Configuration
$BaseUrl = "http://localhost:$SecretsPort"

# Known AitherNet services that should have certificates
$KnownServices = @(
    "AitherNode",
    "AitherPulse", 
    "AitherWatch",
    "AitherSecrets",
    "AitherMind",
    "AitherCouncil",
    "AitherPrism",
    "AitherTrainer",
    "AitherForge",
    "AitherVision",
    "AitherReasoning",
    "AitherParallel",
    "AitherCanvas",
    "AitherContext"
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

function Test-SecretsRunning {
    try {
        $response = Invoke-RestMethod -Uri "$BaseUrl/health" -Method Get -TimeoutSec 5
        return $response.status -eq "healthy"
    }
    catch {
        return $false
    }
}

function Get-CAStatus {
    try {
        $status = Invoke-RestMethod -Uri "$BaseUrl/ca/status" -Method Get
        return $status
    }
    catch {
        return $null
    }
}

function Initialize-RootCA {
    param(
        [string]$CommonName = "AitherNet Root CA",
        [string]$Organization = "AitherZero",
        [int]$ValidityYears = 20,
        [string]$KeyType = "rsa"
    )
    
    Write-Info "Initializing Root CA: $CommonName"
    
    $body = @{
        common_name = $CommonName
        organization = $Organization
        validity_years = $ValidityYears
        key_type = $KeyType
    } | ConvertTo-Json
    
    try {
        $result = Invoke-RestMethod -Uri "$BaseUrl/ca/init/root" -Method Post -Body $body -ContentType "application/json"
        
        if ($result.status -eq "success") {
            Write-Success "Root CA initialized successfully"
            Write-Info "  Serial: $($result.serial_number)"
            Write-Info "  Algorithm: $($result.algorithm)"
            Write-Info "  Valid until: $($result.valid_until)"
            Write-Info "  Fingerprint: $($result.fingerprint)"
            return $result
        }
        else {
            Write-Err "Failed to initialize Root CA: $($result | ConvertTo-Json)"
            return $null
        }
    }
    catch {
        $errorDetail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($errorDetail.detail -like "*already initialized*") {
            Write-Warn "Root CA already initialized"
            return @{ status = "exists" }
        }
        Write-Err "Error initializing Root CA: $_"
        return $null
    }
}

function Initialize-IntermediateCA {
    param(
        [string]$CommonName = "AitherNet Intermediate CA",
        [string]$Organization = "AitherZero",
        [int]$ValidityYears = 5,
        [string]$KeyType = "ec"
    )
    
    Write-Info "Initializing Intermediate CA: $CommonName"
    
    $body = @{
        common_name = $CommonName
        organization = $Organization
        validity_years = $ValidityYears
        key_type = $KeyType
    } | ConvertTo-Json
    
    try {
        $result = Invoke-RestMethod -Uri "$BaseUrl/ca/init/intermediate" -Method Post -Body $body -ContentType "application/json"
        
        if ($result.status -eq "success") {
            Write-Success "Intermediate CA initialized successfully"
            Write-Info "  Serial: $($result.serial_number)"
            Write-Info "  Issuer: $($result.issuer)"
            Write-Info "  Valid until: $($result.valid_until)"
            Write-Info "  Fingerprint: $($result.fingerprint)"
            return $result
        }
        else {
            Write-Err "Failed to initialize Intermediate CA"
            return $null
        }
    }
    catch {
        $errorDetail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($errorDetail.detail -like "*already exists*") {
            Write-Warn "Intermediate CA already initialized"
            return @{ status = "exists" }
        }
        if ($errorDetail.detail -like "*Root CA must*") {
            Write-Err "Root CA must be initialized first"
            return $null
        }
        Write-Err "Error initializing Intermediate CA: $_"
        return $null
    }
}

function New-ServiceCertificate {
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,
        [int]$ValidityDays = 365,
        [string]$KeyType = "ec"
    )
    
    Write-Info "Issuing certificate for: $ServiceName"
    
    $body = @{
        validity_days = $ValidityDays
        san_dns = @()
        san_ips = @("127.0.0.1")
        key_type = $KeyType
    } | ConvertTo-Json
    
    try {
        $result = Invoke-RestMethod -Uri "$BaseUrl/ca/issue/$ServiceName" -Method Post -Body $body -ContentType "application/json"
        
        if ($result.status -eq "success") {
            Write-Success "Certificate issued for $ServiceName"
            Write-Info "  Serial: $($result.serial_number)"
            Write-Info "  Valid until: $($result.valid_until)"
            Write-Info "  Cert path: $($result.cert_path)"
            Write-Info "  Key path: $($result.key_path)"
            return $result
        }
        else {
            Write-Err "Failed to issue certificate for $ServiceName"
            return $null
        }
    }
    catch {
        $errorDetail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($errorDetail.detail -like "*Intermediate CA must*") {
            Write-Err "Intermediate CA must be initialized first"
            return $null
        }
        Write-Err "Error issuing certificate: $_"
        return $null
    }
}

function Show-CAStatus {
    $caStatus = Get-CAStatus
    
    if (-not $caStatus) {
        Write-Err "Could not retrieve CA status"
        return
    }
    
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║              AITHER CA STATUS                              ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    # Root CA
    if ($caStatus.root_ca.exists) {
        Write-Host "  🔐 Root CA:        " -NoNewline
        Write-Host "INITIALIZED" -ForegroundColor Green
    }
    else {
        Write-Host "  🔐 Root CA:        " -NoNewline
        Write-Host "NOT INITIALIZED" -ForegroundColor Yellow
    }
    
    # Intermediate CA
    if ($caStatus.intermediate_ca.exists) {
        Write-Host "  🔑 Intermediate CA:" -NoNewline
        Write-Host " INITIALIZED" -ForegroundColor Green
    }
    else {
        Write-Host "  🔑 Intermediate CA:" -NoNewline
        Write-Host " NOT INITIALIZED" -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "  📊 Certificates:" -ForegroundColor White
    Write-Host "     Total:   $($caStatus.certificates.total)"
    Write-Host "     Active:  $($caStatus.certificates.active)"
    Write-Host "     Revoked: $($caStatus.certificates.revoked)"
    Write-Host "     Services: $($caStatus.certificates.services)"
    
    if ($caStatus.crl.exists) {
        Write-Host ""
        Write-Host "  📜 CRL: Available" -ForegroundColor White
    }
    
    Write-Host ""
}

function Show-Certificates {
    try {
        $certs = Invoke-RestMethod -Uri "$BaseUrl/ca/certificates?include_revoked=true" -Method Get
        
        Write-Host ""
        Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║              ISSUED CERTIFICATES                           ║" -ForegroundColor Cyan
        Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
        
        if ($certs.Count -eq 0) {
            Write-Host "  No certificates issued yet." -ForegroundColor Yellow
            return
        }
        
        foreach ($cert in $certs) {
            $statusIcon = if ($cert.revoked) { "❌" } elseif ($cert.expired) { "⚠️" } else { "✅" }
            $typeIcon = if ($cert.is_ca) { "🔐" } else { "📄" }
            
            Write-Host "  $typeIcon $statusIcon $($cert.subject)" -ForegroundColor $(if ($cert.revoked) { "Red" } elseif ($cert.expired) { "Yellow" } else { "White" })
            Write-Host "       Serial: $($cert.serial_number)"
            Write-Host "       Issuer: $($cert.issuer)"
            Write-Host "       Expires: $($cert.not_after)"
            
            if ($cert.revoked) {
                Write-Host "       REVOKED: $($cert.revoked_at)" -ForegroundColor Red
            }
            Write-Host ""
        }
    }
    catch {
        Write-Err "Error listing certificates: $_"
    }
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║           AITHER CA DEPLOYMENT                            ║" -ForegroundColor Magenta
Write-Host "║     Certificate Authority for mTLS                        ║" -ForegroundColor Magenta
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# Check if AitherSecrets is running
if (-not (Test-SecretsRunning)) {
    Write-Err "AitherSecrets is not running on port $SecretsPort"
    Write-Info "Start it with: ./0784_Start-AitherSecrets.ps1"
    exit 1
}

Write-Success "AitherSecrets is running on port $SecretsPort"
Write-Host ""

# Handle different operations
$exitCode = 0

if ($Status) {
    Show-CAStatus
}

if ($ListCerts) {
    Show-Certificates
}

if ($InitRoot) {
    $result = Initialize-RootCA
    if (-not $result) { $exitCode = 1 }
}

if ($InitIntermediate) {
    $result = Initialize-IntermediateCA
    if (-not $result) { $exitCode = 1 }
}

if ($IssueFor) {
    $result = New-ServiceCertificate -ServiceName $IssueFor
    if (-not $result) { $exitCode = 1 }
}

if ($IssueAll) {
    $caStatus = Get-CAStatus
    if (-not $caStatus.has_intermediate) {
        Write-Err "Intermediate CA must be initialized before issuing certificates"
        exit 1
    }
    
    Write-Info "Issuing certificates for all known services..."
    Write-Host ""
    
    $issued = 0
    $failed = 0
    
    foreach ($service in $KnownServices) {
        $result = New-ServiceCertificate -ServiceName $service
        if ($result) {
            $issued++
        }
        else {
            $failed++
        }
    }
    
    Write-Host ""
    Write-Success "Issued $issued certificates, $failed failed"
}

# Show final status if any modifications were made
if ($InitRoot -or $InitIntermediate -or $IssueFor -or $IssueAll) {
    Write-Host ""
    Show-CAStatus
}

# If no operation specified, show help
if (-not ($Status -or $ListCerts -or $InitRoot -or $InitIntermediate -or $IssueFor -or $IssueAll)) {
    Write-Host "Usage:" -ForegroundColor White
    Write-Host "  -Status           Show CA status"
    Write-Host "  -ListCerts        List all issued certificates"
    Write-Host "  -InitRoot         Initialize Root CA (one-time)"
    Write-Host "  -InitIntermediate Initialize Intermediate CA"
    Write-Host "  -IssueFor <name>  Issue cert for a specific service"
    Write-Host "  -IssueAll         Issue certs for all known services"
    Write-Host ""
    Write-Host "Example - Full deployment:" -ForegroundColor Yellow
    Write-Host "  ./0785_Deploy-AitherCA.ps1 -InitRoot -InitIntermediate -IssueAll -ShowOutput"
    Write-Host ""
}

exit $exitCode
