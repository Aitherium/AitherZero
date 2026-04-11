<#
.SYNOPSIS
    Sets a GitHub Actions secret for the repository.

.DESCRIPTION
    This script automates the process of setting a GitHub Actions secret.
    It uses the AitherFlow service (port 8090) to handle encryption and upload.
    This ensures secrets are encrypted client-side before being sent to GitHub.

.PARAMETER Name
    The name of the secret (e.g., 'OPENAI_API_KEY').

.PARAMETER Value
    The value of the secret. If not provided, you will be prompted securely.

.EXAMPLE
    ./0706_Set-GitHubSecret.ps1 -Name "OPENAI_API_KEY" -Value "sk-..."
    Sets the OPENAI_API_KEY secret.

.EXAMPLE
    ./0706_Set-GitHubSecret.ps1 -Name "DB_PASSWORD"
    Prompts for the password securely and sets it.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [string]$Value
)

. "$PSScriptRoot/_init.ps1"

Write-ScriptLog -Message "Starting GitHub Secret update for '$Name'..." -Level Information

# Check if AitherFlow is running
$port = 8090
$isListening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue

if (-not $isListening) {
    Write-ScriptLog -Message "AitherFlow service is not running on port $port." -Level Error
    Write-ScriptLog -Message "Please start AitherFlow first (usually part of AitherNode)." -Level Information
    exit 1
}

# Prompt for value if not provided
if ([string]::IsNullOrWhiteSpace($Value)) {
    $secureString = Read-Host -Prompt "Enter value for secret '$Name'" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    $Value = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}

# Call AitherFlow API
$url = "http://localhost:$port/secrets/$Name"
$body = @{
    secret_name = $Name
    secret_value = $Value
} | ConvertTo-Json

try {
    $response = Invoke-RestMethod -Uri $url -Method Put -Body $body -ContentType "application/json" -ErrorAction Stop
    Write-ScriptLog -Message "Successfully updated secret '$Name'." -Level Success
    if ($PSBoundParameters['ShowOutput']) {
        $response | Format-List
    }
}
catch {
    Write-ScriptLog -Message "Failed to update secret: $_" -Level Error
    exit 1
}
