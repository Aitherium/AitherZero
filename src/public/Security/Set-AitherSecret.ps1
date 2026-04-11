#Requires -Version 7.0

<#
.SYNOPSIS
    Sets a secret in the configured secret store.

.DESCRIPTION
    Abstraction layer for secret storage. Tries to use Microsoft.PowerShell.SecretManagement
    if available. Falls back to AitherZero's internal credential store (Set-AitherCredential)
    if the module is not present.

.PARAMETER Name
    The name of the secret to set.

.PARAMETER Secret
    The secret value (String, SecureString, PSCredential, or Hashtable).

.PARAMETER Vault
    The name of the vault to store the secret in. Defaults to the configured default vault.

.EXAMPLE
    Set-AitherSecret -Name "AzurePat" -Secret "my-token-value"
#>
function Set-AitherSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$Secret,

        [string]$Vault,

        [Parameter(HelpMessage = "Show command output in console.")]
        [switch]$ShowOutput
    )

    begin {
        # Manage logging targets for this execution
        $originalLogTargets = $script:AitherLogTargets
        if ($ShowOutput) {
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
        else {
            # Ensure Console is NOT in targets if ShowOutput is not specified
            $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
        }
    }

    process {
        try {
            # 1. Try Microsoft.PowerShell.SecretManagement
            if (Get-Command Set-Secret -ErrorAction SilentlyContinue) {
                try {
                    Write-AitherLog -Message "Using Microsoft.PowerShell.SecretManagement" -Level Debug
                    $params = @{ Name = $Name; Secret = $Secret }
                    if ($Vault) { $params.Vault = $Vault }

                    Set-Secret @params -ErrorAction Stop
                    Write-AitherLog -Message "Secret '$Name' saved to vault." -Level Debug
                    return
                }
                catch {
                    Write-AitherLog -Message "Failed to save to SecretManagement vault: $_" -Level Warning
                    # Fallthrough to internal store
                }
            }

            # 2. Fallback to Internal Store
            Write-AitherLog -Message "Falling back to internal AitherZero credential store" -Level Debug
            if (Get-Command Set-AitherCredential -ErrorAction SilentlyContinue) {
                try {
                    # Convert input to appropriate format for Set-AitherCredential
                    if ($Secret -is [System.Security.SecureString]) {
                        Set-AitherCredential -Name $Name -ApiKey $Secret
                    }
                    elseif ($Secret -is [string]) {
                        $secureSecret = ConvertTo-SecureString -String $Secret -AsPlainText -Force
                        Set-AitherCredential -Name $Name -ApiKey $secureSecret
                    }
                    elseif ($Secret -is [PSCredential]) {
                        Set-AitherCredential -Name $Name -Credential $Secret
                    }
                    else {
                        throw "Unsupported secret type for internal store fallback: $($Secret.GetType().Name)"
                    }

                    Write-AitherLog -Message "Secret '$Name' saved to internal store." -Level Debug
                }
                catch {
                    Write-AitherLog -Message "Failed to save secret '$Name' to internal store: $_" -Level Error -Source 'Set-AitherSecret' -Exception $_
                    throw
                }
            }
            else {
                Write-AitherLog -Message "No secret management capability available." -Level Error -Source 'Set-AitherSecret'
                throw "No secret management capability available."
            }
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }
}

