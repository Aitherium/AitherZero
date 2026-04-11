#Requires -Version 7.0

<#
.SYNOPSIS
    Loads stored AitherZero secrets into environment variables for local development.

.DESCRIPTION
    Automatically loads API keys from the local encrypted vault into environment
    variables, eliminating the need to manually set .env files.
    
    This enables a seamless workflow:
    1. Store secrets once: Set-AitherCredential -Name "OPENAI_API_KEY" -ApiKey $key
    2. Initialize at session start: Initialize-AitherSecrets
    3. Use normally: $env:OPENAI_API_KEY is available
    
    Secrets are loaded from the encrypted local vault, not from GitHub.

.PARAMETER Names
    Specific secret names to load. If not provided, loads all API keys.

.PARAMETER Prefix
    Only load secrets matching this prefix (e.g., "OPENAI", "ANTHROPIC").

.PARAMETER Scope
    Environment variable scope: Process (default), User, or Machine.

.PARAMETER NoClobber
    Don't overwrite existing environment variables.

.EXAMPLE
    Initialize-AitherSecrets
    
    Loads all stored API keys into the current process environment.

.EXAMPLE
    Initialize-AitherSecrets -Names "OPENAI_API_KEY", "ANTHROPIC_API_KEY"
    
    Loads specific API keys.

.EXAMPLE
    Initialize-AitherSecrets -Prefix "GOOGLE"
    
    Loads all secrets starting with "GOOGLE" (GOOGLE_API_KEY, GOOGLE_PROJECT_ID, etc.)

.NOTES
    Call this in your PowerShell profile or at the start of scripts that need API keys.
    Add to your profile: Initialize-AitherSecrets -ShowOutput
#>
function Initialize-AitherSecrets {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$Names,

        [Parameter()]
        [string]$Prefix,

        [Parameter()]
        [ValidateSet('Process', 'User', 'Machine')]
        [string]$Scope = 'Process',

        [Parameter()]
        [switch]$NoClobber,

        [Parameter()]
        [switch]$ShowOutput
    )

    begin {
        # Get credential storage path
        $credentialPath = if ($IsWindows) {
            Join-Path $env:USERPROFILE ".aitherzero" "credentials"
        } else {
            Join-Path $env:HOME ".aitherzero" "credentials"
        }

        $loadedSecrets = @()
        $skippedSecrets = @()
    }

    process {
        try {
            if (-not (Test-Path $credentialPath)) {
                if ($ShowOutput) {
                    Write-AitherLog -Level Warning -Message "⚠️  No secrets stored yet. Use Set-AitherCredential to store API keys." -Source 'Initialize-AitherSecrets'
                }
                return
            }

            # Get credential files
            $credFiles = Get-ChildItem -Path $credentialPath -Filter "*.cred" -File

            if ($Names) {
                $credFiles = $credFiles | Where-Object { $Names -contains $_.BaseName }
            }

            if ($Prefix) {
                $credFiles = $credFiles | Where-Object { $_.BaseName -like "$Prefix*" }
            }

            foreach ($credFile in $credFiles) {
                $name = $credFile.BaseName
                
                try {
                    # Read the credential file
                    $credData = Import-Clixml -Path $credFile.FullName -ErrorAction Stop

                    # Only process API keys (not full credentials)
                    if ($credData.Type -ne 'ApiKey') {
                        continue
                    }

                    # Convert environment variable name (ensure uppercase, underscores)
                    $envName = $name.ToUpper() -replace '-', '_'

                    # Check if already set
                    $existingValue = [Environment]::GetEnvironmentVariable($envName, $Scope)
                    if ($existingValue -and $NoClobber) {
                        $skippedSecrets += $name
                        if ($ShowOutput) {
                            Write-AitherLog -Level Information -Message "⏭️  Skipped (exists): $envName" -Source 'Initialize-AitherSecrets'
                        }
                        continue
                    }

                    # Get the secret value
                    $secretValue = Get-AitherCredential -Name $name -AsPlainText -ErrorAction Stop

                    if ($secretValue) {
                        # Set the environment variable
                        [Environment]::SetEnvironmentVariable($envName, $secretValue, $Scope)
                        $loadedSecrets += $name

                        if ($ShowOutput) {
                            # Show masked value for security
                            $masked = if ($secretValue.Length -gt 8) {
                                $secretValue.Substring(0, 4) + "..." + $secretValue.Substring($secretValue.Length - 4)
                            } else {
                                "****"
                            }
                            Write-AitherLog -Level Information -Message "✅ Loaded: `$env:$envName = $masked" -Source 'Initialize-AitherSecrets'
                        }
                    }
                }
                catch {
                    Write-AitherLog -Level Warning -Message "Failed to load '$name': $_" -Source 'Initialize-AitherSecrets' -Exception $_
                }
            }

            if ($ShowOutput) {
                Write-AitherLog -Level Information -Message "📦 Loaded $($loadedSecrets.Count) secrets into environment ($Scope scope)" -Source 'Initialize-AitherSecrets'
                if ($skippedSecrets.Count -gt 0) {
                    Write-AitherLog -Level Information -Message "⏭️  Skipped $($skippedSecrets.Count) existing variables" -Source 'Initialize-AitherSecrets'
                }
            }

            return [PSCustomObject]@{
                Loaded = $loadedSecrets
                Skipped = $skippedSecrets
                Scope = $Scope
            }
        }
        catch {
            Write-AitherLog -Level Error -Message "Failed to initialize secrets: $_" -Source 'Initialize-AitherSecrets' -Exception $_
            throw
        }
    }
}
