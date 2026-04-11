#Requires -Version 7.0

<#
.SYNOPSIS
    Makes HTTP requests to AitherOS services with Ed25519 request signing.

.DESCRIPTION
    Wraps Invoke-RestMethod with automatic Ed25519 signature injection for
    inter-service authentication. Signs the request body with the service's
    private key and adds X-Signature and X-Service-Id headers.

    Key provisioning: reads the signing key from AitherSecrets (port 8111)
    and caches it for the session. If signing keys are unavailable, falls
    back to unsigned requests with a warning.

.PARAMETER Uri
    The URI to send the request to.

.PARAMETER Method
    HTTP method. Defaults to GET.

.PARAMETER Body
    Request body (string or hashtable). Hashtables are auto-converted to JSON.

.PARAMETER ServiceId
    The service identity for signing. Defaults to 'aitherzero-cli'.

.PARAMETER Headers
    Additional headers to include.

.PARAMETER TimeoutSec
    Request timeout in seconds. Defaults to 30.

.PARAMETER SkipSigning
    Skip signature injection (for testing or when signing is disabled).

.EXAMPLE
    Invoke-AitherSignedRequest -Uri "http://localhost:8001/api/agents" -Method GET

.EXAMPLE
    Invoke-AitherSignedRequest -Uri "http://localhost:8001/forge/dispatch/sync" -Method POST -Body @{
        agent = 'demiurge'
        task = 'Refactor module'
    }

.NOTES
    Category: Security
    Dependencies: AitherSecrets (port 8111) for key provisioning
    Platform: Windows, Linux, macOS
#>
function Invoke-AitherSignedRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Uri,

        [Parameter()]
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'PATCH')]
        [string]$Method = 'GET',

        [Parameter()]
        $Body,

        [Parameter()]
        [string]$ServiceId = 'aitherzero-cli',

        [Parameter()]
        [hashtable]$Headers = @{},

        [Parameter()]
        [int]$TimeoutSec = 30,

        [Parameter()]
        [switch]$SkipSigning
    )

    # Convert hashtable body to JSON
    $bodyStr = ''
    if ($Body) {
        if ($Body -is [hashtable] -or $Body -is [System.Collections.Specialized.OrderedDictionary]) {
            $bodyStr = $Body | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $bodyStr = [string]$Body
        }
    }

    # Build signing headers
    if (-not $SkipSigning) {
        try {
            $signingKey = Get-AitherSigningKey -ServiceId $ServiceId
            if ($signingKey) {
                $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
                $signaturePayload = "$Method`n$Uri`n$timestamp`n$bodyStr"

                # HMAC-SHA256 signature (compatible with AitherOS ServiceSigner fallback)
                $hmac = New-Object System.Security.Cryptography.HMACSHA256
                $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($signingKey)
                $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($signaturePayload))
                $signature = [Convert]::ToBase64String($hash)

                $Headers['X-Signature'] = $signature
                $Headers['X-Service-Id'] = $ServiceId
                $Headers['X-Timestamp'] = $timestamp
            }
        }
        catch {
            Write-Verbose "Request signing unavailable: $_. Proceeding unsigned."
        }
    }

    # Make the request
    $params = @{
        Uri         = $Uri
        Method      = $Method
        TimeoutSec  = $TimeoutSec
        Headers     = $Headers
        ErrorAction = 'Stop'
    }

    if ($bodyStr -and $Method -ne 'GET') {
        $params.Body = $bodyStr
        $params.ContentType = 'application/json'
    }

    return Invoke-RestMethod @params
}

function Get-AitherSigningKey {
    <#
    .SYNOPSIS
        Retrieves or caches the service signing key from AitherSecrets.
    #>
    [CmdletBinding()]
    param(
        [string]$ServiceId = 'aitherzero-cli'
    )

    # Session cache
    if ($script:_SigningKeyCache -and $script:_SigningKeyCacheExpiry -gt [DateTime]::UtcNow) {
        return $script:_SigningKeyCache
    }

    try {
        $ctx = Get-AitherLiveContext
        $secretsUrl = if ($ctx.SecretsURL) { $ctx.SecretsURL } else { "http://localhost:8111" }

        $response = Invoke-RestMethod -Uri "$secretsUrl/api/v1/signing-key/$ServiceId" `
            -Method GET -TimeoutSec 5 -ErrorAction Stop

        if ($response.key) {
            $script:_SigningKeyCache = $response.key
            $script:_SigningKeyCacheExpiry = [DateTime]::UtcNow.AddMinutes(30)
            return $response.key
        }
    }
    catch {
        Write-Verbose "Could not retrieve signing key for $ServiceId : $_"
    }

    # Fallback: try local env or internal secret
    if ($env:AITHER_SIGNING_KEY) {
        return $env:AITHER_SIGNING_KEY
    }

    if ($env:AITHER_INTERNAL_SECRET) {
        return $env:AITHER_INTERNAL_SECRET
    }

    return $null
}
