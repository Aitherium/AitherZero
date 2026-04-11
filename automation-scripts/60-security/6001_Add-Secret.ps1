<#
.SYNOPSIS
    Adds or updates a secret in the AitherSecrets vault via API.

.DESCRIPTION
    Sends a POST request to the AitherSecrets service (port 8111) to store a secret.
    This persists the secret in the encrypted vault.

.PARAMETER Name
    The key name of the secret (e.g. OPENAI_API_KEY).

.PARAMETER Value
    The secret value.

.PARAMETER Type
    Type of secret: generic, api_key, token, password, certificate. Default: generic.

.PARAMETER Access
    Access level: internal, restricted, public, admin. Default: internal.
    'internal' means visible to all AitherOS services.

.PARAMETER Service
    The service strictly owning this secret. Default: system.

.EXAMPLE
    ./6001_Add-Secret.ps1 -Name "MY_API_KEY" -Value "sk-123456"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Name,

    [Parameter(Mandatory=$true, Position=1)]
    [string]$Value,

    [string]$Type = "generic",
    [string]$Access = "internal",
    [string]$Service = "system"
)

$ErrorActionPreference = "Stop"

# Use localhost directly or look up port if needed, but 8111 is standard
$baseUrl = "http://localhost:8111"

# Check if service is up
try {
    $null = Invoke-RestMethod -Uri "$baseUrl/health" -ErrorAction Stop
} catch {
    Write-Error "AitherSecrets service is not reachable at $baseUrl. Is the container 'aither-secrets' running?"
    exit 1
}

$body = @{
    name = $Name
    value = $Value
    secret_type = $Type
    access_level = $Access
} | ConvertTo-Json

Write-Host "Adding secret '$Name' ($Type) to vault..." -ForegroundColor Cyan

try {
    $response = Invoke-RestMethod -Uri "$baseUrl/secrets?service=$Service" `
        -Method Post `
        -Body $body `
        -ContentType "application/json"

    if ($response.success) {
        Write-Host "✅ Success! Secret '$Name' stored safely." -ForegroundColor Green
    } else {
        Write-Error "Failed to store secret. API returned success=False."
    }
} catch {
    $err = $_
    if ($err.Response) {
        $reader = New-Object System.IO.StreamReader($err.Response.GetResponseStream())
        $detail = $reader.ReadToEnd()
        Write-Error "API Error: $detail"
    } else {
        Write-Error "Network Error: $($err.Exception.Message)"
    }
    exit 1
}
