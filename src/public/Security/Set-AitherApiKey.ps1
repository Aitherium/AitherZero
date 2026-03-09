#Requires -Version 7.0

<#
.SYNOPSIS
    Stores an API key in the encrypted local vault with optional GitHub sync.

.DESCRIPTION
    Convenience function for storing API keys (OpenAI, Anthropic, Google, etc.)
    in the AitherZero encrypted vault. Optionally syncs to GitHub Actions secrets.
    
    This is the recommended way to manage API keys for AitherZero:
    1. Store once with Set-AitherApiKey
    2. Auto-load with Initialize-AitherSecrets
    3. Sync to GitHub with -SyncToGitHub for CI/CD

.PARAMETER Name
    The name of the API key (e.g., OPENAI_API_KEY, ANTHROPIC_API_KEY).
    Will be normalized to uppercase with underscores.

.PARAMETER Value
    The API key value. If not provided, will prompt securely.

.PARAMETER SyncToGitHub
    Also sync this secret to GitHub Actions secrets.

.PARAMETER Owner
    GitHub repository owner (for sync). Defaults to 'Aitherium'.

.PARAMETER Repo
    GitHub repository name (for sync). Defaults to 'AitherZero-Internal'.

.PARAMETER Force
    Overwrite existing key without prompting.

.EXAMPLE
    Set-AitherApiKey -Name "OPENAI_API_KEY"
    
    Prompts for the key securely and stores it.

.EXAMPLE
    Set-AitherApiKey -Name "ANTHROPIC_API_KEY" -Value "sk-ant-..." -SyncToGitHub
    
    Stores the key locally and syncs to GitHub.

.EXAMPLE
    # Bulk setup
    @("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GOOGLE_API_KEY") | ForEach-Object {
        Set-AitherApiKey -Name $_
    }
#>
function Set-AitherApiKey {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Position = 1)]
        [string]$Value,

        [Parameter()]
        [switch]$SyncToGitHub,

        [Parameter()]
        [string]$Owner = "Aitherium",

        [Parameter()]
        [string]$Repo = "AitherZero-Internal",

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$ShowOutput
    )

    process {
        try {
            # Normalize name to uppercase with underscores
            $normalizedName = $Name.ToUpper() -replace '-', '_'

            # Prompt for value if not provided
            if (-not $Value) {
                $secureValue = Read-Host -Prompt "Enter value for $normalizedName" -AsSecureString
                
                # Convert to plain text for storage (Set-AitherCredential handles encryption)
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
                try {
                    $Value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                } finally {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }

            if ([string]::IsNullOrWhiteSpace($Value)) {
                throw "API key value cannot be empty."
            }

            if ($PSCmdlet.ShouldProcess($normalizedName, "Store API key")) {
                # Store in local vault
                $secureKey = $Value | ConvertTo-SecureString -AsPlainText -Force
                
                $params = @{
                    Name = $normalizedName
                    ApiKey = $secureKey
                }
                if ($Force) { $params.Force = $true }
                if ($ShowOutput) { $params.ShowOutput = $true }

                Set-AitherCredential @params

                if ($ShowOutput) {
                    Write-AitherLog -Level Information -Message "✅ Stored locally: $normalizedName" -Source 'Set-AitherApiKey'
                }

                # Optionally sync to GitHub
                if ($SyncToGitHub) {
                    if ($ShowOutput) {
                        Write-AitherLog -Level Information -Message "🔄 Syncing to GitHub..." -Source 'Set-AitherApiKey'
                    }

                    $syncParams = @{
                        Names = @($normalizedName)
                        Owner = $Owner
                        Repo = $Repo
                        Force = $true
                    }
                    if ($ShowOutput) { $syncParams.ShowOutput = $true }

                    Sync-AitherSecretsToGitHub @syncParams
                }

                return [PSCustomObject]@{
                    Name = $normalizedName
                    StoredLocally = $true
                    SyncedToGitHub = $SyncToGitHub.IsPresent
                }
            }
        }
        catch {
            Write-AitherLog -Level Error -Message "Failed to store API key: $_" -Source 'Set-AitherApiKey' -Exception $_
            throw
        }
    }
}
