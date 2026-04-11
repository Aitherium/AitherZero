<#
.SYNOPSIS
    Manage Private Certificate Authorities — create CAs, issue certs, verify chains.

.DESCRIPTION
    PowerShell wrapper for AitherCert that makes it easy to set up a private CA
    and issue TLS/mTLS certificates for encrypted connections that even the
    operator cannot decrypt.

    Supports both server-assisted mode (via AitherCert API at port 8113) and
    fully local/offline mode (via the Python CLI tool).

.PARAMETER Action
    What to do: QuickSetup, CreateCA, IssueCert, ListCerts, RevokeCert,
    DownloadChain, VerifyChain, Info, LocalInit, LocalIssue.

.PARAMETER Owner
    Owner identifier (your username or org name).

.PARAMETER Name
    Human-friendly CA name.

.PARAMETER CommonName
    Certificate CN (e.g., "myserver.local").

.PARAMETER SANs
    Additional DNS Subject Alternative Names (comma-separated).

.PARAMETER IPSANs
    IP Subject Alternative Names (comma-separated).

.PARAMETER CaId
    CA identifier (returned by CreateCA).

.PARAMETER Serial
    Certificate serial number (for revoke/get operations).

.PARAMETER ValidityDays
    Certificate validity in days (default: 365, max: 825).

.PARAMETER CertType
    Certificate type: server, client, or dual (default: dual).

.PARAMETER OutputDir
    Directory for output files (default: ./certs).

.PARAMETER Server
    AitherCert server URL (default: http://localhost:8113).

.PARAMETER LocalCaDir
    Path to local CA directory (for offline operations).

.EXAMPLE
    # Quick setup — one command to get a CA + cert
    .\0820_Manage-PrivateCA.ps1 -Action QuickSetup -Owner "myname" -CommonName "myserver.local"

.EXAMPLE
    # Fully offline — create CA locally, no server needed
    .\0820_Manage-PrivateCA.ps1 -Action LocalInit -Name "My Offline CA" -LocalCaDir ./my-ca

.EXAMPLE
    # Issue cert from local CA
    .\0820_Manage-PrivateCA.ps1 -Action LocalIssue -LocalCaDir ./my-ca -CommonName "api.myapp.local"

.EXAMPLE
    # Verify a certificate chain
    .\0820_Manage-PrivateCA.ps1 -Action VerifyChain -OutputDir ./certs

.NOTES
    Author:  Aitherium
    Version: 1.0.0
    Port:    8113 (AitherCert service)
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'QuickSetup', 'CreateCA', 'IssueCert', 'ListCerts', 'RevokeCert',
        'DownloadChain', 'VerifyChain', 'Info', 'LocalInit', 'LocalIssue',
        'Guide'
    )]
    [string]$Action,

    [string]$Owner = $env:USERNAME,
    [string]$Name = "Private CA",
    [string]$CommonName,
    [string]$SANs,
    [string]$IPSANs,
    [string]$CaId,
    [string]$Serial,
    [int]$ValidityDays = 365,
    [string]$CertType = "dual",
    [string]$OutputDir = "./certs",
    [string]$Server = "http://localhost:8113",
    [string]$LocalCaDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Helpers ──────────────────────────────────────────────────────────────

function Get-SecurePassphrase {
    param([switch]$Confirm)

    $pp = Read-Host -Prompt "Enter CA passphrase (min 12 chars)" -AsSecureString
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pp)
    )

    if ($plain.Length -lt 12) {
        throw "Passphrase must be at least 12 characters."
    }

    if ($Confirm) {
        $pp2 = Read-Host -Prompt "Confirm passphrase" -AsSecureString
        $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pp2)
        )
        if ($plain -ne $plain2) {
            throw "Passphrases do not match."
        }
    }

    return $plain
}

function Invoke-CertApi {
    param(
        [string]$Method = "GET",
        [string]$Path,
        [hashtable]$Body
    )

    $uri = "$Server$Path"
    $params = @{
        Uri             = $uri
        Method          = $Method
        ContentType     = "application/json"
        TimeoutSec      = 30
        UseBasicParsing = $true
    }

    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 5)
    }

    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        $err = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = [System.IO.StreamReader]::new($stream)
                $errBody = $reader.ReadToEnd() | ConvertFrom-Json
                $err = $errBody.detail
            } catch {}
        }
        Write-Error "API call failed: $err"
        return $null
    }
}

function Save-CertFiles {
    param(
        [hashtable]$CertData,
        [string]$Dir
    )

    New-Item -ItemType Directory -Path $Dir -Force | Out-Null

    $cn = $CertData.certificate.info.common_name ?? $CommonName ?? "cert"
    $safeCn = $cn -replace '\*', '_wildcard_' -replace ' ', '_'

    $certPath  = Join-Path $Dir "$safeCn.crt"
    $keyPath   = Join-Path $Dir "$safeCn.key"
    $chainPath = Join-Path $Dir "$safeCn-chain.pem"

    if ($CertData.certificate.cert_pem) {
        Set-Content -Path $certPath -Value $CertData.certificate.cert_pem -NoNewline
    }
    if ($CertData.certificate.key_pem) {
        Set-Content -Path $keyPath -Value $CertData.certificate.key_pem -NoNewline
        # Restrict permissions on key file
        if ($IsLinux -or $IsMacOS) {
            chmod 600 $keyPath 2>$null
        }
    }
    if ($CertData.certificate.chain_pem ?? $CertData.trust_chain_pem) {
        $chain = $CertData.certificate.chain_pem ?? $CertData.trust_chain_pem
        Set-Content -Path $chainPath -Value $chain -NoNewline
    }

    # Save encrypted key for future operations
    if ($CertData.certificate.encrypted_key) {
        $encKeyPath = Join-Path $Dir "$safeCn.key.enc.json"
        $CertData.certificate.encrypted_key | ConvertTo-Json -Depth 3 |
            Set-Content -Path $encKeyPath
    }

    return @{
        CertPath  = $certPath
        KeyPath   = $keyPath
        ChainPath = $chainPath
    }
}

# ── Actions ──────────────────────────────────────────────────────────────

switch ($Action) {

    'Guide' {
        $result = Invoke-CertApi -Path "/guide"
        if ($result) {
            Write-Host "`n🔐 $($result.title)" -ForegroundColor Cyan
            Write-Host "   $($result.description)`n"

            Write-Host "Quick Start:" -ForegroundColor Yellow
            foreach ($step in $result.quick_start) {
                Write-Host "  $($step.step). $($step.action)" -ForegroundColor White
                if ($step.method) {
                    Write-Host "     $($step.method)" -ForegroundColor DarkGray
                }
            }

            Write-Host "`nEndpoints:" -ForegroundColor Yellow
            $result.endpoints.PSObject.Properties | ForEach-Object {
                Write-Host "  $($_.Name) — $($_.Value)" -ForegroundColor DarkGray
            }
            Write-Host ""
        }
    }

    'QuickSetup' {
        if (-not $CommonName) {
            throw "CommonName is required for QuickSetup. Use -CommonName 'myserver.local'"
        }

        $passphrase = Get-SecurePassphrase -Confirm

        $body = @{
            owner       = $Owner
            name        = $Name
            passphrase  = $passphrase
            common_name = $CommonName
        }

        if ($SANs) { $body.sans = $SANs -split ',' | ForEach-Object { $_.Trim() } }
        if ($IPSANs) { $body.ip_sans = $IPSANs -split ',' | ForEach-Object { $_.Trim() } }
        $body.validity_days = $ValidityDays
        $body.cert_type = $CertType

        Write-Host "`n🔐 Creating private CA and issuing first certificate..." -ForegroundColor Cyan

        $result = Invoke-CertApi -Method POST -Path "/ca/quick-setup" -Body $body
        if (-not $result) { return }

        $files = Save-CertFiles -CertData $result -Dir $OutputDir

        Write-Host "`n✅ Private CA created!" -ForegroundColor Green
        Write-Host "   CA ID:        $($result.ca_id)" -ForegroundColor White
        Write-Host "   Root FP:      $($result.root_fingerprint.Substring(0,16))..." -ForegroundColor DarkGray
        Write-Host "   Cert serial:  $($result.certificate.serial)" -ForegroundColor White
        Write-Host "   Expires:      $($result.certificate.expires_at)" -ForegroundColor White
        Write-Host "`n📁 Files saved:" -ForegroundColor Yellow
        Write-Host "   Certificate:  $($files.CertPath)"
        Write-Host "   Private key:  $($files.KeyPath)"
        Write-Host "   Trust chain:  $($files.ChainPath)"
        Write-Host "`n🔧 Test:" -ForegroundColor Yellow
        Write-Host "   openssl verify -CAfile $($files.ChainPath) $($files.CertPath)"
        Write-Host "   curl --cacert $($files.ChainPath) https://$CommonName`n"

        Write-Host "⚠️  Save your CA ID and passphrase — they're needed to issue more certs." -ForegroundColor Red
        Write-Host "   CA ID: $($result.ca_id)`n" -ForegroundColor Red
    }

    'CreateCA' {
        $passphrase = Get-SecurePassphrase -Confirm

        $body = @{
            owner              = $Owner
            name               = $Name
            passphrase         = $passphrase
            create_intermediate = $true
        }

        $result = Invoke-CertApi -Method POST -Path "/ca/create" -Body $body
        if ($result) {
            Write-Host "`n✅ CA created: $($result.ca_id)" -ForegroundColor Green
            Write-Host "   $($result.message)" -ForegroundColor Yellow
        }
    }

    'IssueCert' {
        if (-not $CaId) { throw "CaId is required. Use -CaId '<your-ca-id>'" }
        if (-not $CommonName) { throw "CommonName is required." }

        $passphrase = Get-SecurePassphrase

        $body = @{
            ca_id        = $CaId
            passphrase   = $passphrase
            common_name  = $CommonName
            validity_days = $ValidityDays
            cert_type    = $CertType
        }
        if ($SANs) { $body.sans = $SANs -split ',' | ForEach-Object { $_.Trim() } }
        if ($IPSANs) { $body.ip_sans = $IPSANs -split ',' | ForEach-Object { $_.Trim() } }

        $result = Invoke-CertApi -Method POST -Path "/ca/issue" -Body $body
        if ($result) {
            # Wrap in structure expected by Save-CertFiles
            $wrapped = @{ certificate = $result }
            $files = Save-CertFiles -CertData $wrapped -Dir $OutputDir

            Write-Host "`n✅ Certificate issued!" -ForegroundColor Green
            Write-Host "   Serial:      $($result.serial)"
            Write-Host "   Fingerprint: $($result.fingerprint.Substring(0,16))..."
            Write-Host "   Files saved to: $OutputDir`n"
        }
    }

    'ListCerts' {
        if (-not $CaId) { throw "CaId is required." }
        $result = Invoke-CertApi -Path "/ca/$CaId/certs"
        if ($result) {
            if (-not $result.certificates -or $result.certificates.Count -eq 0) {
                Write-Host "No certificates issued yet."
            } else {
                $result.certificates | Format-Table serial, common_name, cert_type, expires_at, revoked -AutoSize
            }
        }
    }

    'RevokeCert' {
        if (-not $CaId) { throw "CaId is required." }
        if (-not $Serial) { throw "Serial is required." }

        $passphrase = Get-SecurePassphrase
        $result = Invoke-CertApi -Method POST -Path "/ca/revoke" -Body @{
            ca_id      = $CaId
            passphrase = $passphrase
            serial     = $Serial
        }
        if ($result) {
            Write-Host "✓ Certificate $Serial revoked at $($result.revoked_at)" -ForegroundColor Green
        }
    }

    'DownloadChain' {
        if (-not $CaId) { throw "CaId is required." }
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

        $chainPath = Join-Path $OutputDir "chain.pem"
        $chain = Invoke-CertApi -Path "/ca/$CaId/chain"
        Set-Content -Path $chainPath -Value $chain -NoNewline
        Write-Host "✓ Trust chain saved: $chainPath" -ForegroundColor Green
    }

    'VerifyChain' {
        $certFiles = Get-ChildItem -Path $OutputDir -Filter "*.crt" -ErrorAction SilentlyContinue
        $chainFile = Get-ChildItem -Path $OutputDir -Filter "*chain.pem" -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $chainFile) {
            Write-Error "No chain.pem found in $OutputDir"
            return
        }

        foreach ($cert in $certFiles) {
            $result = & openssl verify -CAfile $chainFile.FullName $cert.FullName 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ $($cert.Name): VALID" -ForegroundColor Green
            } else {
                Write-Host "✗ $($cert.Name): INVALID — $result" -ForegroundColor Red
            }
        }
    }

    'Info' {
        if (-not $CaId) {
            # List all CAs
            $result = Invoke-CertApi -Path "/ca/list"
            if ($result -and $result.cas) {
                Write-Host "`nPrivate CAs:" -ForegroundColor Cyan
                $result.cas | Format-Table ca_id, owner, name, mode, issued_count, revoked_count -AutoSize
            } else {
                Write-Host "No CAs found."
            }
        } else {
            $result = Invoke-CertApi -Path "/ca/$CaId"
            if ($result) {
                Write-Host "`n🔐 CA: $($result.name)" -ForegroundColor Cyan
                $result | Format-List
            }
        }
    }

    'LocalInit' {
        if (-not $LocalCaDir) { throw "LocalCaDir is required for local operations." }
        $cliPath = Join-Path $PSScriptRoot "..\..\..\..\AitherOS\tools\aithercert_cli.py"
        if (-not (Test-Path $cliPath)) {
            $cliPath = Join-Path $PSScriptRoot "..\..\..\AitherOS\tools\aithercert_cli.py"
        }

        Write-Host "`n🔐 Creating local private CA (fully offline)..." -ForegroundColor Cyan
        python $cliPath init --name $Name --out $LocalCaDir --org "Private" --country "US"
    }

    'LocalIssue' {
        if (-not $LocalCaDir) { throw "LocalCaDir is required." }
        if (-not $CommonName) { throw "CommonName is required." }

        $cliPath = Join-Path $PSScriptRoot "..\..\..\..\AitherOS\tools\aithercert_cli.py"
        if (-not (Test-Path $cliPath)) {
            $cliPath = Join-Path $PSScriptRoot "..\..\..\AitherOS\tools\aithercert_cli.py"
        }

        $args = @("issue", "--ca-dir", $LocalCaDir, "--cn", $CommonName,
                  "--validity", $ValidityDays, "--type", $CertType)
        if ($SANs) { $args += "--san"; $args += $SANs }
        if ($IPSANs) { $args += "--ip-san"; $args += $IPSANs }
        if ($OutputDir) { $args += "--out-dir"; $args += $OutputDir }

        python $cliPath @args
    }
}
