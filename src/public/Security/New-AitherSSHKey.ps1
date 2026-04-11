#Requires -Version 7.0

<#
.SYNOPSIS
    Generate SSH key pairs for secure remote access

.DESCRIPTION
    Creates SSH key pairs (RSA or ED25519) for secure authentication to remote systems.
    Keys are generated using OpenSSH and stored securely in the user's .ssh directory.
    
    This cmdlet is essential for setting up passwordless SSH access to servers, which is
    more secure and convenient than password authentication. Generated keys can be added
    to remote servers using Add-AitherSSHKey.

.PARAMETER Name
    Name identifier for the key pair. This is REQUIRED and helps you identify which key
    to use later. The key files will be named based on this (e.g., id_rsa_<Name>).
    
    Examples:
    - "production" - Creates keys for production servers
    - "github" - Creates keys for GitHub access
    - "deploy" - Creates keys for deployment automation

.PARAMETER KeyType
    Type of SSH key to generate. RSA keys are more widely compatible, while ED25519 keys
    are more secure and faster. Default is ED25519 for new keys.
    
    - RSA: Traditional key type, widely supported (2048, 3072, or 4096 bits)
    - ED25519: Modern, secure, and fast (recommended for new keys)

.PARAMETER KeySize
    Key size in bits (only for RSA keys). Larger keys are more secure but slower.
    Valid values: 2048, 3072, 4096. Default is 4096 for RSA keys.
    
    Note: ED25519 keys have a fixed size and this parameter is ignored for ED25519.

.PARAMETER KeyPath
    Directory where keys should be stored. Default is ~/.ssh (or $env:USERPROFILE\.ssh on Windows).
    The directory will be created if it doesn't exist.

.PARAMETER Passphrase
    Optional passphrase to encrypt the private key. If not provided, the key will be
    unencrypted (less secure but more convenient for automation).
    
    For automation scenarios, you may want to leave this empty, but for personal keys,
    always use a passphrase.

.PARAMETER Comment
    Comment to embed in the public key (usually email or description).
    Default is "AitherZero-generated key for <Name>".

.PARAMETER Force
    Overwrite existing key pair if it already exists. Use with caution as this cannot be undone.

.INPUTS
    System.String
    You can pipe key names to New-AitherSSHKey.

.OUTPUTS
    PSCustomObject
    Returns an object with properties:
    - Name: Key name identifier
    - PrivateKeyPath: Path to private key file
    - PublicKeyPath: Path to public key file
    - KeyType: Type of key generated
    - Fingerprint: SSH key fingerprint
    - Created: Timestamp when key was created

.EXAMPLE
    New-AitherSSHKey -Name "production"
    
    Creates a new ED25519 key pair named "production" in ~/.ssh directory.

.EXAMPLE
    New-AitherSSHKey -Name "github" -KeyType RSA -KeySize 4096
    
    Creates a 4096-bit RSA key pair for GitHub access.

.EXAMPLE
    New-AitherSSHKey -Name "deploy" -Passphrase (Read-Host -AsSecureString "Enter passphrase")
    
    Creates a key pair with a passphrase for deployment automation.

.EXAMPLE
    "server1", "server2" | New-AitherSSHKey
    
    Creates multiple key pairs by piping key names.

.EXAMPLE
    New-AitherSSHKey -Name "test" -KeyPath "C:\Keys" -Comment "test@example.com"
    
    Creates a key pair in a custom location with a specific comment.

.NOTES
    SSH keys are stored in:
    - Linux/macOS: ~/.ssh/
    - Windows: $env:USERPROFILE\.ssh\
    
    The private key should NEVER be shared or committed to version control.
    Only the public key (.pub file) should be distributed to remote servers.
    
    For automation scenarios, consider using an SSH agent to manage keys securely.

.LINK
    Get-AitherSSHKey
    Add-AitherSSHKey
    Remove-AitherSSHKey
    Test-AitherSSHConnection
#>
function New-AitherSSHKey {
[OutputType([PSCustomObject])]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,
    
    [ValidateSet('RSA', 'ED25519')]
    [string]$KeyType = 'ED25519',
    
    [ValidateSet(2048, 3072, 4096)]
    [int]$KeySize = 4096,
    
    [string]$KeyPath,
    
    [System.Security.SecureString]$Passphrase,
    
    [string]$Comment,
    
    [switch]$Force
)

begin {
    # Determine default key path
    if (-not $KeyPath) {
        if ($IsWindows) {
            $KeyPath = Join-Path $env:USERPROFILE '.ssh'
        }
    else {
            $KeyPath = Join-Path $env:HOME '.ssh'
        }
    }
    
    # Ensure key directory exists
    if (-not (Test-Path $KeyPath)) {
        New-Item -Path $KeyPath -ItemType Directory -Force | Out-Null
    }
    
    # Set proper permissions on Unix
    if ($IsLinux -or $IsMacOS) {
        # Ensure .ssh directory has correct permissions
        $currentPerms = (Get-Item $KeyPath).Mode
        if ($currentPerms -notmatch '^d[rwx-]{2}[r-][wx-][rx-]$') {
            chmod 700 $KeyPath
        }
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $Name) {
            return $null
        }
        
        # Check if ssh-keygen is available
        if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
            throw "ssh-keygen command not found. Install OpenSSH client to generate SSH keys."
        }
        
        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue
        
        # Generate key file names
        $keyPrefix = if ($KeyType -eq 'RSA') { "id_rsa" } else { "id_ed25519" }
        $privateKeyPath = Join-Path $KeyPath "${keyPrefix}_${Name}"
        $publicKeyPath = "${privateKeyPath}.pub"
        
        # Check if keys already exist
        if ((Test-Path $privateKeyPath) -or (Test-Path $publicKeyPath)) {
            if (-not $Force) {
                $errorObject = [PSCustomObject]@{
                    PSTypeName = 'AitherZero.Error'
                    Success = $false
                    ErrorId = [System.Guid]::NewGuid().ToString()
                    Cmdlet = $PSCmdlet.MyInvocation.MyCommand.Name
                    Operation = "Generating SSH key: $Name"
                    Error = "Key pair already exists: $privateKeyPath. Use -Force to overwrite."
                    Timestamp = Get-Date
                }
                Write-Output $errorObject
                
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Level Warning -Message "Key pair already exists: $privateKeyPath" -Source $PSCmdlet.MyInvocation.MyCommand.Name
                }
                return
            }
        }
        
        # Build ssh-keygen command
        $keygenArgs = @()
        
        if ($KeyType -eq 'RSA') {
            $keygenArgs += '-t', 'rsa'
            $keygenArgs += '-b', $KeySize.ToString()
        }
        else {
            $keygenArgs += '-t', 'ed25519'
        }
        
        $keygenArgs += '-f', $privateKeyPath
        
        if ($Passphrase) {
            # Convert SecureString to plain text for ssh-keygen
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase)
            try {
                $plainPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $keygenArgs += '-N', $plainPass
            }
            finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
        else {
            $keygenArgs += '-N', ''
        }
        
        # Add comment
        if (-not $Comment) {
            $Comment = "AitherZero-generated key for $Name"
        }
        $keygenArgs += '-C', $Comment
        
        # Generate key
        if ($PSCmdlet.ShouldProcess($privateKeyPath, "Generate SSH key pair")) {
            $keygenProcess = Start-Process -FilePath 'ssh-keygen' -ArgumentList $keygenArgs -Wait -PassThru -NoNewWindow
            
            if ($keygenProcess.ExitCode -ne 0) {
                throw "ssh-keygen failed with exit code $($keygenProcess.ExitCode)"
            }
            
            # Set proper permissions on Unix
            if ($IsLinux -or $IsMacOS) {
                chmod 600 $privateKeyPath
                chmod 644 $publicKeyPath
            }
            
            # Get fingerprint
            $fingerprintOutput = & ssh-keygen -lf $publicKeyPath 2>&1
            $fingerprint = if ($fingerprintOutput -match '^\d+\s+([a-f0-9:]+)') {
                $matches[1]
            }
            else {
                "Unknown"
            }
            
            $result = [PSCustomObject]@{
                PSTypeName = 'AitherZero.SSHKey'
                Name = $Name
                PrivateKeyPath = $privateKeyPath
                PublicKeyPath = $publicKeyPath
                KeyType = $KeyType
                KeySize = if ($KeyType -eq 'RSA') { $KeySize } else { 256 }
                Fingerprint = $fingerprint
                Comment = $Comment
                Created = Get-Date
            }
            
            if ($hasWriteAitherLog) {
                Write-AitherLog -Level Information -Message "Generated SSH key pair: $Name" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Data @{
                    KeyType = $KeyType
                    KeySize = if ($KeyType -eq 'RSA') { $KeySize } else { 256 }
                    Fingerprint = $fingerprint
                }
            }
            return $result
        }
    }
    catch {
        # Use centralized error handling
        $errorScript = Join-Path $PSScriptRoot '..' 'Private' 'Write-AitherError.ps1'
        if (Test-Path $errorScript) {
            . $errorScript -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Generating SSH key: $Name" -Parameters $PSBoundParameters -ThrowOnError
        }
        else {
            # Fallback error handling
            $hasWriteAitherLogFallback = Get-Command Write-AitherLog -ErrorAction SilentlyContinue
            $errorObject = [PSCustomObject]@{
                PSTypeName = 'AitherZero.Error'
                Success = $false
                ErrorId = [System.Guid]::NewGuid().ToString()
                Cmdlet = $PSCmdlet.MyInvocation.MyCommand.Name
                Operation = "Generating SSH key: $Name"
                Error = $_.Exception.Message
                Timestamp = Get-Date
            }
            Write-Output $errorObject
            
            if ($hasWriteAitherLogFallback) {
                Write-AitherLog -Level Error -Message "Failed to generate SSH key $Name : $($_.Exception.Message)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Exception $_
            } else {
                Write-AitherLog -Level Error -Message "Failed to generate SSH key $Name : $($_.Exception.Message)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Exception $_
            }
        }
        throw
    }
}

}

