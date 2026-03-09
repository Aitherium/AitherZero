#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieve a securely stored credential

.DESCRIPTION
    Retrieves a credential previously stored with Set-AitherCredential.
    Decrypts and returns the credential in the requested format.
    
    This cmdlet is essential for:
    - Retrieving credentials for remote connections
    - Getting API keys for API calls
    - Accessing stored credentials in automation scripts
    - Avoiding hardcoded credentials

.PARAMETER Name
    Name of the stored credential. This is the name used when storing the credential
    with Set-AitherCredential.

.PARAMETER AsPlainText
    Return API key as plain text string instead of SecureString.
    WARNING: Use with caution as this exposes the credential in memory as plain text.
    Only use when absolutely necessary (e.g., for API headers that require plain text).

.EXAMPLE
    $cred = Get-AitherCredential -Name "Production-SSH"
    New-AitherPSSession -ComputerName "server01" -Credential $cred
    
    Retrieves a stored credential and uses it to create a PSSession.

.EXAMPLE
    $apiKey = Get-AitherCredential -Name "GitHub-Token" -AsPlainText
    $headers = @{ Authorization = "Bearer $apiKey" }
    Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $headers
    
    Retrieves a GitHub token as plain text for use in API headers.

.EXAMPLE
    $sshCred = Get-AitherCredential -Name "SSH-Server1"
    Test-AitherSSHConnection -Target "server.com" -Credential $sshCred
    
    Uses stored credential for SSH connection testing.

.INPUTS
    System.String
    You can pipe credential names to Get-AitherCredential.

.OUTPUTS
    PSCredential
    Returns PSCredential object for stored username/password credentials.
    
    SecureString
    Returns SecureString for stored API keys (default).
    
    System.String
    Returns plain text string for API keys when -AsPlainText is used.

.NOTES
    Security:
    - Credentials are decrypted in memory only
    - Use SecureString format when possible
    - Avoid -AsPlainText unless absolutely necessary
    - Credentials are user-specific and cannot be accessed by other users
    - Credential files are encrypted and stored securely
    
    Error Handling:
    - Throws an error if credential is not found
    - Use Set-AitherCredential to store credentials before retrieving them

.LINK
    Set-AitherCredential
    Remove-AitherCredential
    Get-AitherCredentialList
#>
function Get-AitherCredential {
[OutputType([PSCredential], [SecureString], [System.String])]
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,
    
    [Parameter()]
    [switch]$AsPlainText
)

begin {
    $moduleRoot = Get-AitherModuleRoot
    
    # Determine credential storage path
    $credentialPath = if ($IsWindows) {
        Join-Path $env:USERPROFILE ".aitherzero" "credentials"
    }
    else {
        Join-Path $env:HOME ".aitherzero" "credentials"
    }
}

process { try {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            # During module validation, Name may be empty - skip validation
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
                return
            }
            throw "Name parameter is required"
        }
        
        $credFile = Join-Path $credentialPath "$Name.cred"
        
        if (-not (Test-Path $credFile)) {
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Credential '$Name' not found. Use Set-AitherCredential to store it first."),
                "CredentialNotFound",
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $Name
            )
            Invoke-AitherErrorHandler -ErrorRecord $errorRecord -Operation "Retrieving credential: $Name" -Parameters $PSBoundParameters -ThrowOnError
            return
        }
        
        try {
            $credData = Import-Clixml -Path $credFile
            
            if ($credData.Type -eq 'Credential') {
                # Return PSCredential
                if ($credData.Password) {
                    # Check if it's already a SecureString or needs conversion
                    if ($credData.Password -is [SecureString]) {
                        $password = $credData.Password
                    }
                    elseif ($credData.Password -is [string] -and $credData.Password.Length -gt 0) {
                        $password = $credData.Password | ConvertTo-SecureString -AsPlainText
                    }
                    else {
                        throw "Credential password is empty or invalid"
                    }
                    return [PSCredential]::new($credData.Username, $password)
                }
                else {
                    throw "Credential password is empty or invalid"
                }
            }
            elseif ($credData.Type -eq 'ApiKey') {
                # Return API Key
                if ($credData.Key) {
                    if ($credData.Key -is [SecureString]) {
                        $secureKey = $credData.Key
                    }
                    elseif ($credData.Key -is [string] -and $credData.Key.Length -gt 0) {
                        $secureKey = $credData.Key | ConvertTo-SecureString -AsPlainText
                    }
                    else {
                        throw "API key is empty or invalid"
                    }
                }
                else {
                    throw "API key is empty or invalid"
                }
                
                if ($AsPlainText) {
                    # Use helper function for secure conversion
                    if (Get-Command ConvertFrom-SecureStringSecurely -ErrorAction SilentlyContinue) {
                        return ConvertFrom-SecureStringSecurely -SecureString $secureKey
                    }
                    else {
                        # Fallback - less secure but functional
                        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
                        try {
                            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                        }
                        finally {
                            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                        }
                    }
                }
                else {
                    return $secureKey
                }
            }
            else {
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Unknown credential type: $($credData.Type)"),
                    "InvalidCredentialType",
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $credData.Type
                )
                Invoke-AitherErrorHandler -ErrorRecord $errorRecord -Operation "Retrieving credential: $Name" -Parameters $PSBoundParameters -ThrowOnError
            }
        }
    catch {
            Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Decrypting credential: $Name" -Parameters $PSBoundParameters -ThrowOnError
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Retrieving credential: $Name" -Parameters $PSBoundParameters -ThrowOnError
    }
}

}

