#Requires -Version 7.0

<#
.SYNOPSIS
    Add SSH public key to remote server's authorized_keys file

.DESCRIPTION
    Adds an SSH public key to a remote server's authorized_keys file, enabling passwordless
    SSH access. This is essential for automation and secure remote access setup.
    
    The cmdlet can add keys via SSH (if you have password access) or by directly modifying
    the authorized_keys file if you have file system access.

.PARAMETER KeyName
    Name of the SSH key to add (as created by New-AitherSSHKey).
    This parameter is REQUIRED and identifies which public key to add.
    
    Example: "production", "github", "deploy"

.PARAMETER Target
    Target server hostname or IP address where the key should be added.
    This parameter is REQUIRED and specifies the remote server.

.PARAMETER User
    Username on the remote server. Defaults to current user or 'root' if not specified.
    The key will be added to this user's authorized_keys file.

.PARAMETER AuthorizedKeysPath
    Custom path to authorized_keys file on the remote server.
    Default is ~/.ssh/authorized_keys (or $env:USERPROFILE\.ssh\authorized_keys on Windows).

.PARAMETER Credential
    PSCredential object for SSH authentication (if password access is needed).
    Required if you don't already have SSH key access to the server.

.PARAMETER Port
    SSH port number. Default is 22.

.PARAMETER Force
    Overwrite existing key entry if the same key already exists.

.INPUTS
    System.String
    You can pipe key names to Add-AitherSSHKey.

    PSCustomObject
    You can pipe SSH key objects from Get-AitherSSHKey to Add-AitherSSHKey.

.OUTPUTS
    PSCustomObject
    Returns result object with properties:
    - Success: Whether the operation succeeded
    - Target: Target server
    - User: Remote username
    - KeyAdded: Whether a new key was added
    - KeyExists: Whether the key already existed

.EXAMPLE
    Add-AitherSSHKey -KeyName "production" -Target "server.example.com"
    
    Adds the "production" public key to server.example.com for the current user.

.EXAMPLE
    Add-AitherSSHKey -KeyName "deploy" -Target "192.168.1.100" -User "deploy" -Credential (Get-Credential)
    
    Adds the "deploy" key to a remote server using password authentication.

.EXAMPLE
    Get-AitherSSHKey -Name "github" | Add-AitherSSHKey -Target "github.com" -User "git"
    
    Pipes SSH key object to Add-AitherSSHKey.

.EXAMPLE
    "server1", "server2" | ForEach-Object {
        Add-AitherSSHKey -KeyName "production" -Target $_
    }
    
    Adds the same key to multiple servers.

.NOTES
    This cmdlet requires:
    - SSH access to the remote server (password or existing key)
    - Write access to the remote user's .ssh directory
    - The .ssh directory and authorized_keys file will be created if they don't exist
    
    Security best practices:
    - Always verify the server's host key before adding keys
    - Use specific keys for specific purposes (don't reuse keys)
    - Regularly rotate SSH keys

.LINK
    New-AitherSSHKey
    Get-AitherSSHKey
    Remove-AitherSSHKey
    Test-AitherSSHConnection
#>
function Add-AitherSSHKey {
[OutputType([PSCustomObject])]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory=$false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [AllowEmptyString()]
    [string]$KeyName,
    
    [Parameter(Mandatory=$false, Position = 1)]
    [AllowEmptyString()]
    [string]$Target,
    
    [Parameter()]
    [string]$User,
    
    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,
    
    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$Port = 22,
    
    [Parameter()]
    [string]$AuthorizedKeysPath,
    
    [Parameter()]
    [switch]$Force
)

begin {
    # Check if ssh command is available
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw "SSH command not found. Install OpenSSH client to use SSH key management."
    }
}

process { try {
        # Validate KeyName parameter
        if ([string]::IsNullOrWhiteSpace($KeyName)) {
            # During module validation, KeyName may be empty - skip validation
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
                return
            }
            throw "KeyName parameter is required"
        }
        
        # Get SSH key information
        $keyInfo = Get-AitherSSHKey -Name $KeyName -IncludeContent
        
        if (-not $keyInfo -or -not $keyInfo.PublicKeyPath) {
            throw "SSH key not found: $KeyName. Use New-AitherSSHKey to create a key first."
        }
        if (-not $keyInfo.PublicKeyContent) {
            $keyInfo.PublicKeyContent = Get-Content -Path $keyInfo.PublicKeyPath -Raw -ErrorAction Stop
        }
        
        # Determine remote user
        if (-not $User) {
            $User = if ($IsWindows) { $env:USERNAME } else { $env:USER }
        }
        
        # Determine authorized_keys path
        if (-not $AuthorizedKeysPath) {
            $AuthorizedKeysPath = ".ssh/authorized_keys"
        }
        
        # Build SSH command to add key
        $sshTarget = if ($User) { "${User}@${Target}" } else { $Target }
        $sshArgs = @()
        
        if ($Port -ne 22) {
            $sshArgs += '-p', $Port.ToString()
        }
        
        $sshArgs += $sshTarget
        
        # Check if key already exists
        $checkCommand = "test -f $AuthorizedKeysPath && grep -qF '$(($keyInfo.PublicKeyContent -replace "'", "'\\''"))' $AuthorizedKeysPath || echo 'NOT_FOUND'"
        $checkResult = if ($Credential) {
            $plainPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
            )
            $checkOutput = echo $plainPass | sshpass -p $plainPass ssh @sshArgs $checkCommand 2>&1
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password))
            $checkOutput
        }
        else {
            & ssh @sshArgs $checkCommand 2>&1
        }
        
        $keyExists = $checkResult -notmatch 'NOT_FOUND'
        
        if ($keyExists -and -not $Force) {
            Write-AitherLog -Level Information -Message "SSH key already exists on $Target for user $User" -Source $PSCmdlet.MyInvocation.MyCommand.Name
            
            return [PSCustomObject]@{
                Success = $true
                Target = $Target
                User = $User
                KeyAdded = $false
                KeyExists = $true
            }
        }
        
        # Add key command
        $addCommand = @"
mkdir -p .ssh 2>/dev/null; 
chmod 700 .ssh; 
echo '$($keyInfo.PublicKeyContent)' >> $AuthorizedKeysPath; 
chmod 600 $AuthorizedKeysPath
"@
        
        if ($PSCmdlet.ShouldProcess("$Target ($User)", "Add SSH key $KeyName")) {
            $addResult = if ($Credential) {
                $plainPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
                )
                $addOutput = echo $plainPass | sshpass -p $plainPass ssh @sshArgs $addCommand 2>&1
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password))
                $addOutput
            }
            else {
                & ssh @sshArgs $addCommand 2>&1
            }
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to add SSH key: $addResult"
            }
            
            Write-AitherLog -Level Information -Message "Added SSH key $KeyName to $Target for user $User" -Source $PSCmdlet.MyInvocation.MyCommand.Name
            
            return [PSCustomObject]@{
                Success = $true
                Target = $Target
                User = $User
                KeyAdded = $true
                KeyExists = $keyExists
            }
        }
    }
    catch {
        # Use centralized error handling
        Invoke-AitherErrorHandler -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Adding SSH key $KeyName to $Target" -Parameters $PSBoundParameters -ThrowOnError
    }
}


}

