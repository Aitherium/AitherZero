#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves a secret from the configured secret store.

.DESCRIPTION
    Abstraction layer for secret retrieval. Tries to use Microsoft.PowerShell.SecretManagement
    if available. Falls back to AitherZero's internal credential store (Get-AitherCredential)
    if the module is not present.

.PARAMETER Name
    The name of the secret to retrieve.

.PARAMETER Vault
    The name of the vault to search. Defaults to the configured default vault.

.PARAMETER AsPlainText
    Return the secret as plain text instead of a SecureString/PSCredential.

.EXAMPLE
    Get-AitherSecret -Name "AzurePat"
#>
function Get-AitherSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, HelpMessage="The name of the secret to retrieve.")]
        [string]$Name,

        [Parameter(HelpMessage="The name of the vault to search.")]
        [string]$Vault,

        [Parameter(HelpMessage="Return the secret as plain text.")]
        [switch]$AsPlainText,

        [switch]$ShowOutput
    )

    begin {
        # Save original log targets
        $originalLogTargets = $script:AitherLogTargets

        # Set log targets based on ShowOutput parameter
        if ($ShowOutput) {
            # Ensure Console is in the log targets
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
        else {
            # Remove Console from log targets if present (default behavior)
            if ($script:AitherLogTargets -contains 'Console') {
                $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
            }
        }
    }

    process {
        try {
            # 1. Try Microsoft.PowerShell.SecretManagement
            if (Get-Command Get-Secret -ErrorAction SilentlyContinue) {
                try {
                    Write-AitherLog -Message "Using Microsoft.PowerShell.SecretManagement" -Level Debug -Source 'Get-AitherSecret'
                    $params = @{ Name = $Name }
                    if ($Vault) { $params.Vault = $Vault }
                    if ($AsPlainText) { $params.AsPlainText = $true }

                    return (Get-Secret @params -ErrorAction Stop)
                }
                catch {
                    Write-AitherLog -Message "Secret '$Name' not found in SecretManagement vaults: $_" -Level Debug -Source 'Get-AitherSecret'
                    # Fallthrough to internal store
                }
            }

            # 2. Fallback to Internal Store
            Write-AitherLog -Message "Falling back to internal AitherZero credential store" -Level Debug -Source 'Get-AitherSecret'
            if (Get-Command Get-AitherCredential -ErrorAction SilentlyContinue) {
                try {
                    $cred = Get-AitherCredential -Name $Name -ErrorAction Stop

                    if ($AsPlainText) {
                        if ($cred -is [PSCredential]) {
                            return $cred.GetNetworkCredential().Password
                        }
                        elseif ($cred -is [System.Security.SecureString]) {
                            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred)
                            try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
                            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                        }
                        else {
                            return [string]$cred
                        }
                    }
                    return $cred
                }
                catch {
                    Write-AitherLog -Message "Secret '$Name' not found in any store." -Level Error -Source 'Get-AitherSecret' -Exception $_
                    throw "Secret '$Name' not found in any store."
                }
            }
            else {
                Write-AitherLog -Message "No secret management capability available." -Level Error -Source 'Get-AitherSecret'
                throw "No secret management capability available."
            }
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }
}

