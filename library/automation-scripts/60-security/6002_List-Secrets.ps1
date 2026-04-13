<#
.SYNOPSIS
    Lists all secrets currently in the AitherSecrets vault.

.DESCRIPTION
    Retrieves metadata for all secrets. Does NOT show values.

.EXAMPLE
    ./6002_List-Secrets.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$baseUrl = "http://localhost:8111"

try {
    $null = Invoke-RestMethod -Uri "$baseUrl/health" -ErrorAction Stop
} catch {
    Write-Error "AitherSecrets service is not reachable at $baseUrl."
    exit 1
}

Write-Host "Fetching secret list..." -ForegroundColor Cyan

try {
    $secrets = Invoke-RestMethod -Uri "$baseUrl/secrets" -Method Get
    
    if ($secrets) {
        $secrets | Format-Table -Property name, secret_type, access_level, updated_at -AutoSize
    } else {
        Write-Warning "No secrets found in vault."
    }
} catch {
    Write-Error "Failed to list secrets: $_"
}
