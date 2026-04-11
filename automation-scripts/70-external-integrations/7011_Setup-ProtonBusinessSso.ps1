#Requires -Version 7.0

<#
.SYNOPSIS
Bootstraps Proton Business SAML SSO against AitherIdentity.
.DESCRIPTION
Authenticates to AitherIdentity using either an admin login or an internal service
registration flow, verifies that SAML IdP mode is available, optionally generates
a signing keypair, registers Proton Business as a Service Provider, and writes a
JSON/XML handoff bundle containing the IdP metadata and Proton-facing values.

Exit Codes:
0 - Success
1 - Operation failed
2 - Execution error

.NOTES
Stage: ExternalIntegrations
Order: 7011
Dependencies: 7010
Tags: proton,saml,sso,identity,aithermail
AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AdminUsername,

    [string]$AdminPassword,

    [string]$TotpCode,

    [string]$ServiceApiKey,

    [string]$InternalSharedSecret,

    [string]$BootstrapServiceName = 'ProtonSsoBootstrap',

    [string]$IdentityUrl = 'http://localhost:8117',

    [string]$ServiceProviderEntityId,

    [string]$AssertionConsumerServiceUrl,

    [string]$MetadataUrl,

    [string]$ServiceProviderId = 'proton-business',

    [string]$ServiceProviderName = 'Proton Business',

    [string]$NameIdFormat = 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress',

    [switch]$MetadataOnly,

    [switch]$GenerateKeypair,

    [string]$CommonName = 'AitherIdentity SAML IdP',

    [int]$ValidityYears = 3,

    [string]$OutputPath,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path.TrimEnd('\')
if (-not $OutputPath) {
    $OutputPath = Join-Path $RepoRoot 'proton-business-sso.json'
}
$MetadataPath = [System.IO.Path]::ChangeExtension($OutputPath, '.xml')

function Invoke-IdentityJsonRequest {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Headers,
        $Body
    )

    $uri = "$($IdentityUrl.TrimEnd('/'))$Path"
    $invokeParams = @{
        Uri         = $uri
        Method      = $Method
        ErrorAction = 'Stop'
    }

    if ($Headers) {
        $invokeParams.Headers = $Headers
    }

    if ($null -ne $Body) {
        $invokeParams.Body = ($Body | ConvertTo-Json -Depth 10)
        $invokeParams.ContentType = 'application/json'
    }

    return Invoke-RestMethod @invokeParams
}

function Get-EnvOrDotEnvValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value) { return $value }

    $envFile = Join-Path $RepoRoot '.env'
    if (Test-Path $envFile) {
        $line = Select-String -Path $envFile -Pattern "^$Name=(.+)$" -CaseSensitive | Select-Object -First 1
        if ($line) {
            return $line.Matches[0].Groups[1].Value.Trim()
        }
    }

    return $null
}

function Get-IdentityToken {
    $loginResponse = Invoke-IdentityJsonRequest -Method Post -Path '/auth/login' -Body @{
        username = $AdminUsername
        password = $AdminPassword
    }

    if ($loginResponse.token_type -eq '2fa_challenge') {
        if (-not $TotpCode) {
            throw 'Admin account requires 2FA. Re-run with -TotpCode.'
        }

        $loginResponse = Invoke-IdentityJsonRequest -Method Post -Path '/auth/2fa/verify' -Body @{
            challenge_token = $loginResponse.access_token
            totp_code = $TotpCode
        }
    }

    if (-not $loginResponse.access_token) {
        throw 'AitherIdentity did not return an access token.'
    }

    return $loginResponse.access_token
}

function Get-IdentityAuthHeaders {
    if ($ServiceApiKey) {
        return @{ 'X-API-Key' = $ServiceApiKey }
    }

    $sharedSecret = $InternalSharedSecret
    if (-not $sharedSecret) {
        $sharedSecret = Get-EnvOrDotEnvValue -Name 'AITHER_INTERNAL_SECRET'
    }

    if ($sharedSecret) {
        $registration = Invoke-IdentityJsonRequest -Method Post -Path '/auth/service-register' -Body @{
            service_name = $BootstrapServiceName
            shared_secret = $sharedSecret
            roles = @('admin')
            display_name = 'Proton Business SSO Bootstrap'
        }

        if (-not $registration.api_key) {
            throw 'Service registration did not return an API key.'
        }

        return @{ 'X-API-Key' = $registration.api_key }
    }

    if (-not $AdminUsername -or -not $AdminPassword) {
        throw 'Provide either -ServiceApiKey, -InternalSharedSecret, or -AdminUsername plus -AdminPassword.'
    }

    $token = Get-IdentityToken
    return @{ Authorization = "Bearer $token" }
}

function Resolve-ServiceProviderConfig {
    if ($MetadataOnly) {
        return $null
    }

    if ($MetadataUrl) {
        $metadataResponse = Invoke-WebRequest -Uri $MetadataUrl -Method Get -ErrorAction Stop
        [xml]$metadataXml = $metadataResponse.Content

        $entityNode = $metadataXml.SelectSingleNode("//*[local-name()='EntityDescriptor']")
        if (-not $entityNode -or -not $entityNode.entityID) {
            throw "Could not parse entityID from metadata URL: $MetadataUrl"
        }

        $acsNode = $metadataXml.SelectSingleNode("//*[local-name()='AssertionConsumerService']")
        if (-not $acsNode) {
            throw "Could not parse AssertionConsumerService from metadata URL: $MetadataUrl"
        }

        return @{
            entity_id = [string]$entityNode.entityID
            acs_url = [string]$acsNode.Location
            metadata_url = $MetadataUrl
        }
    }

    if (-not $ServiceProviderEntityId -or -not $AssertionConsumerServiceUrl) {
        throw 'Provide either -MetadataUrl or both -ServiceProviderEntityId and -AssertionConsumerServiceUrl.'
    }

    return @{
        entity_id = $ServiceProviderEntityId
        acs_url = $AssertionConsumerServiceUrl
        metadata_url = $null
    }
}

try {
    $spConfig = Resolve-ServiceProviderConfig

    Write-Host "`n==> Authenticating to AitherIdentity..." -ForegroundColor Cyan
    $authHeaders = Get-IdentityAuthHeaders
    Write-Host '    [OK] Admin-capable auth acquired.' -ForegroundColor Green

    Write-Host "`n==> Checking SAML IdP status..." -ForegroundColor Cyan
    $status = Invoke-IdentityJsonRequest -Method Get -Path '/admin/idp/saml/status' -Headers $authHeaders
    if (-not $status.available) {
        $missing = @($status.missing_deps) -join ', '
        throw "SAML IdP is not available. Missing dependencies: $missing"
    }
    Write-Host "    [OK] SAML IdP available: $($status.entity_id)" -ForegroundColor Green

    if ($GenerateKeypair) {
        Write-Host "`n==> Generating fresh IdP signing keypair..." -ForegroundColor Cyan
        $null = Invoke-IdentityJsonRequest -Method Post -Path '/admin/idp/saml/keypair' -Headers $authHeaders -Body @{
            common_name = $CommonName
            validity_years = $ValidityYears
        }
        Write-Host '    [OK] New signing keypair generated.' -ForegroundColor Green
    }

    if ($spConfig) {
        $spBody = @{
            sp_id = $ServiceProviderId
            entity_id = $spConfig.entity_id
            acs_url = $spConfig.acs_url
            name = $ServiceProviderName
            name_id_format = $NameIdFormat
            attributes = @{
                email = 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'
                name = 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'
                groups = 'http://schemas.xmlsoap.org/claims/Group'
            }
        }

        if ($PSCmdlet.ShouldProcess($ServiceProviderId, 'Register Proton Business service provider')) {
            Write-Host "`n==> Registering Proton Business service provider..." -ForegroundColor Cyan
            $registration = Invoke-IdentityJsonRequest -Method Post -Path '/admin/idp/saml/sp' -Headers $authHeaders -Body $spBody
            Write-Host "    [OK] $($registration.message)" -ForegroundColor Green
        }
    }
    else {
        Write-Host "`n==> Skipping Proton SP registration (metadata-only mode)." -ForegroundColor Yellow
    }

    $status = Invoke-IdentityJsonRequest -Method Get -Path '/admin/idp/saml/status' -Headers $authHeaders
    $metadataFetchUrl = "$($IdentityUrl.TrimEnd('/'))/idp/saml/metadata"
    $metadataUrl = if ($status.entity_id) { [string]$status.entity_id } else { $metadataFetchUrl }
    $metadataXml = (Invoke-WebRequest -Uri $metadataFetchUrl -Method Get -ErrorAction Stop).Content

    $bundle = [ordered]@{
        generated_at = (Get-Date).ToString('o')
        identity = [ordered]@{
            admin_url = $IdentityUrl
            sign_on_url = $status.sso_url
            issuer = $status.entity_id
            metadata_url = $metadataUrl
            certificate = $status.certificate
        }
        proton = [ordered]@{
            service_provider_id = $ServiceProviderId
            display_name = $ServiceProviderName
            entity_id = if ($spConfig) { $spConfig.entity_id } else { $null }
            acs_url = if ($spConfig) { $spConfig.acs_url } else { $null }
            service_provider_metadata_url = if ($spConfig) { $spConfig.metadata_url } else { $null }
            name_id_format = $NameIdFormat
            registration_mode = if ($spConfig) { 'registered' } else { 'metadata-only' }
        }
        instructions = @(
            '1. Open Proton Business admin and create/update the SAML SSO application for mail login.',
            "2. Set Sign-on URL to: $($status.sso_url)",
            "3. Set Issuer / Entity ID to: $($status.entity_id)",
            "4. Upload the certificate from: $MetadataPath or use the certificate block in this JSON bundle.",
            $(if ($spConfig) { "5. Confirm Proton uses ACS URL: $($spConfig.acs_url)" } else { '5. After Proton creates the SAML app, copy its ACS URL or metadata URL and rerun this script without -MetadataOnly.' }),
            $(if ($spConfig) { "6. Confirm Proton SP Entity ID: $($spConfig.entity_id)" } else { '6. Re-run with -MetadataUrl or both -ServiceProviderEntityId and -AssertionConsumerServiceUrl to finalize SP registration.' }),
            '7. Test with a non-owner mailbox before enforcing SSO org-wide.'
        )
    }

    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $bundle | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
    $metadataXml | Set-Content -Path $MetadataPath -Encoding UTF8

    Write-Host "`n==> Proton Business SSO bundle written." -ForegroundColor Cyan
    Write-Host "    JSON: $OutputPath" -ForegroundColor Green
    Write-Host "    XML : $MetadataPath" -ForegroundColor Green

    if ($PassThru) {
        $bundle
    }

    exit 0
}
catch {
    Write-Error $_
    exit 1
}
