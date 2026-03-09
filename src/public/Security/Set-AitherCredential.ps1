#Requires -Version 7.0

<#
.SYNOPSIS
    Securely store credentials for later use

.DESCRIPTION
    Stores credentials (username/password or API keys) in an encrypted format
    for use in automation scripts. Credentials are stored per-user and encrypted
    using Windows Data Protection API (DPAPI) on Windows or similar mechanisms on Linux/macOS.

    This cmdlet is essential for:
    - Storing credentials for remote connections (SSH, WinRM, etc.)
    - Storing API keys and tokens securely
    - Avoiding hardcoded credentials in scripts
    - Enabling credential reuse across automation scripts

.PARAMETER Name
    Unique name for the credential. This name will be used to retrieve the credential later.
    Use descriptive names like "Production-SSH", "GitHub-Token", "AWS-AccessKey".

.PARAMETER Credential
    PSCredential object containing username and password. Use Get-Credential to create one,
    or pass a pre-existing PSCredential object.

.PARAMETER ApiKey
    SecureString containing an API key or token. Use Read-Host -AsSecureString to create one.

.PARAMETER Force
    Overwrite existing credential if it already exists. Without this parameter, the cmdlet
    will throw an error if a credential with the same name already exists.

.EXAMPLE
    Set-AitherCredential -Name "Production-SSH" -Credential (Get-Credential)

    Stores a username/password credential for production SSH access. Prompts for username and password.

.EXAMPLE
    $token = Read-Host -AsSecureString -Prompt "Enter GitHub token"
    Set-AitherCredential -Name "GitHub-Token" -ApiKey $token

    Stores a GitHub API token securely.

.EXAMPLE
    Set-AitherCredential -Name "AWS-Prod" -Credential $awsCred -Force

    Overwrites an existing AWS credential.

.INPUTS
    PSCredential
    SecureString
    You can pipe PSCredential objects to Set-AitherCredential.

.OUTPUTS
    None
    This cmdlet does not produce output.

.NOTES
    Security:
    - Credentials are encrypted using Windows DPAPI (Windows) or similar mechanisms (Linux/macOS)
    - Credentials are stored per-user and cannot be accessed by other users
    - Credential files are stored in ~/.aitherzero/credentials/ (Linux/macOS) or %USERPROFILE%\.aitherzero\credentials\ (Windows)
    - File permissions are automatically set to restrict access (600 on Linux/macOS)

    Best Practices:
    - Use descriptive names that indicate the purpose and environment
    - Store API keys separately from username/password credentials
    - Regularly rotate stored credentials
    - Use -Force only when intentionally updating credentials

.LINK
    Get-AitherCredential
    Remove-AitherCredential
    Get-AitherCredentialList
#>
function Set-AitherCredential {
[OutputType()]
[CmdletBinding(DefaultParameterSetName = 'Credential', SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false, Position = 0, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter(Mandatory=$false, ParameterSetName = 'Credential', ValueFromPipeline)]
    [ValidateNotNull()]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false, ParameterSetName = 'ApiKey')]
    [ValidateNotNull()]
    [SecureString]$ApiKey,

    [Parameter()]
    [switch]$Force,

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

    $moduleRoot = Get-AitherModuleRoot

    # Determine credential storage path
    $credentialPath = if ($IsWindows) {
        Join-Path $env:USERPROFILE ".aitherzero" "credentials"
    }
    else {
        Join-Path $env:HOME ".aitherzero" "credentials"
    }
}

process {
    try {
        try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $Name) {
            return
        }

        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

        # Create directory if it doesn't exist
        if (-not (Test-Path $credentialPath)) {
            New-Item -ItemType Directory -Path $credentialPath -Force | Out-Null

            # Set restrictive permissions on Linux/macOS
            if (-not $IsWindows) {
                try {
                    chmod 700 $credentialPath 2>$null
                }
                catch {
                    if ($hasWriteAitherLog) {
                        Write-AitherLog -Level Warning -Message "Could not set permissions on credential directory: $_" -Source 'Set-AitherCredential'
                    }
                }
            }
        }

        $credFile = Join-Path $credentialPath "$Name.cred"

        # Check if credential already exists
        if ((Test-Path $credFile) -and -not $Force) {
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Credential '$Name' already exists. Use -Force to overwrite."),
                "CredentialExists",
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $Name
            )
            Invoke-AitherErrorHandler -ErrorRecord $errorRecord -Operation "Storing credential: $Name" -Parameters $PSBoundParameters -ThrowOnError
            return
        }

        if ($PSCmdlet.ShouldProcess($Name, "Store credential")) {
            try {
                if ($PSCmdlet.ParameterSetName -eq 'Credential') {
                    # Store PSCredential
                    $credData = @{
                        Type = 'Credential'
                        Username = $Credential.UserName
                        Password = $Credential.Password | ConvertFrom-SecureString
                        Created = (Get-Date).ToString('o')
                    }
                }
                else {
                    # Store API Key
                    $credData = @{
                        Type = 'ApiKey'
                        Key = $ApiKey | ConvertFrom-SecureString
                        Created = (Get-Date).ToString('o')
                    }
                }

                # Export to encrypted file
                $credData | Export-Clixml -Path $credFile -Force

                # Set restrictive permissions on Linux/macOS
                if (-not $IsWindows) {
                    try {
                        chmod 600 $credFile 2>$null
                    }
                    catch {
                        if ($hasWriteAitherLog) {
                            Write-AitherLog -Level Warning -Message "Could not set permissions on credential file: $_" -Source 'Set-AitherCredential'
                        }
                    }
                }

                if ($hasWriteAitherLog) {
                    Write-AitherLog -Level Information -Message "Credential stored successfully" -Source 'Set-AitherCredential' -Data @{
                        Name = $Name
                        Type = $credData.Type
                        Path = $credFile
                    }
                }
            }
            catch {
                Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Storing credential: $Name" -Parameters $PSBoundParameters -ThrowOnError
            }
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Setting up credential storage" -Parameters $PSBoundParameters -ThrowOnError
    }
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

