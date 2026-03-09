#Requires -Version 7.0

<#
.SYNOPSIS
    Syncs local AitherZero secrets to GitHub repository secrets.

.DESCRIPTION
    Pushes locally stored credentials to GitHub Actions secrets.
    This enables a workflow where:
    1. Store secrets locally using Set-AitherCredential (encrypted, secure)
    2. Sync to GitHub for CI/CD use
    3. Load locally using Initialize-AitherSecrets for dev work
    
    GitHub Secrets are WRITE-ONLY by design - you cannot retrieve them.
    Your local vault is the source of truth.

.PARAMETER Names
    Specific secret names to sync. If not provided, syncs all API keys.

.PARAMETER Owner
    GitHub repository owner. Defaults to 'Aitherium'.

.PARAMETER Repo
    GitHub repository name. Defaults to 'AitherZero-Internal'.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    Sync-AitherSecretsToGitHub -Names "OPENAI_API_KEY", "ANTHROPIC_API_KEY"
    
    Syncs specific API keys to GitHub.

.EXAMPLE
    Sync-AitherSecretsToGitHub -Force
    
    Syncs all stored API keys to GitHub without prompting.

.NOTES
    Requires:
    - GitHub CLI (gh) authenticated: gh auth login
    - PyNaCl or libsodium for encryption (gh handles this automatically)
#>
function Sync-AitherSecretsToGitHub {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string[]]$Names,

        [Parameter()]
        [string]$Owner = "Aitherium",

        [Parameter()]
        [string]$Repo = "AitherZero-Internal",

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$ShowOutput
    )

    begin {
        # Verify gh CLI is available and authenticated
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw "GitHub CLI (gh) is not installed. Install it from https://cli.github.com/"
        }

        $authStatus = gh auth status 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub CLI is not authenticated. Run 'gh auth login' first."
        }

        # Get credential storage path
        $credentialPath = if ($IsWindows) {
            Join-Path $env:USERPROFILE ".aitherzero" "credentials"
        } else {
            Join-Path $env:HOME ".aitherzero" "credentials"
        }
    }

    process {
        try {
            # Get all stored credentials if no specific names provided
            if (-not $Names) {
                if (-not (Test-Path $credentialPath)) {
                    Write-AitherLog -Level Warning -Message "No credentials stored. Use Set-AitherCredential first." -Source 'Sync-AitherSecretsToGitHub'
                    return
                }

                $credFiles = Get-ChildItem -Path $credentialPath -Filter "*.cred" -File
                $Names = $credFiles | ForEach-Object { $_.BaseName }
            }

            if (-not $Names -or $Names.Count -eq 0) {
                Write-AitherLog -Level Warning -Message "No secrets to sync." -Source 'Sync-AitherSecretsToGitHub'
                return
            }

            $results = @()

            foreach ($name in $Names) {
                try {
                    # Get the secret value
                    $secretValue = Get-AitherCredential -Name $name -AsPlainText -ErrorAction Stop

                    if (-not $secretValue) {
                        Write-AitherLog -Level Warning -Message "Secret '$name' is empty, skipping." -Source 'Sync-AitherSecretsToGitHub'
                        continue
                    }

                    # GitHub secret names must be uppercase with underscores
                    $ghSecretName = $name.ToUpper() -replace '-', '_'

                    if ($PSCmdlet.ShouldProcess("$Owner/$Repo", "Set secret '$ghSecretName'")) {
                        if (-not $Force) {
                            $confirm = Read-Host "Sync '$name' to GitHub as '$ghSecretName'? (y/N)"
                            if ($confirm -notmatch '^[Yy]') {
                                Write-AitherLog -Level Information -Message "Skipped: $name" -Source 'Sync-AitherSecretsToGitHub'
                                continue
                            }
                        }

                        # Use gh CLI to set the secret (handles encryption automatically)
                        $secretValue | gh secret set $ghSecretName --repo "$Owner/$Repo" 2>&1

                        if ($LASTEXITCODE -eq 0) {
                            $results += [PSCustomObject]@{
                                Name = $name
                                GitHubName = $ghSecretName
                                Status = "Synced"
                            }
                            if ($ShowOutput) {
                                Write-AitherLog -Level Information -Message "✅ Synced: $name → $ghSecretName" -Source 'Sync-AitherSecretsToGitHub'
                            }
                        } else {
                            $results += [PSCustomObject]@{
                                Name = $name
                                GitHubName = $ghSecretName
                                Status = "Failed"
                            }
                            Write-AitherLog -Level Warning -Message "Failed to sync '$name'" -Source 'Sync-AitherSecretsToGitHub'
                        }
                    }
                }
                catch {
                    Write-AitherLog -Level Warning -Message "Error syncing '$name': $_" -Source 'Sync-AitherSecretsToGitHub' -Exception $_
                    $results += [PSCustomObject]@{
                        Name = $name
                        GitHubName = ""
                        Status = "Error: $_"
                    }
                }
            }

            return $results
        }
        catch {
            Write-AitherLog -Level Error -Message "Sync failed: $_" -Source 'Sync-AitherSecretsToGitHub' -Exception $_
            throw
        }
    }
}
