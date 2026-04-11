#Requires -Version 7.0

<#
.SYNOPSIS
    List and retrieve SSH key information

.DESCRIPTION
    Lists SSH keys in the .ssh directory and retrieves information about them including
    fingerprints, key types, and public key content. Useful for managing multiple SSH keys
    and verifying which keys are available.

.PARAMETER Name
    Optional name filter to find specific keys. Matches keys with this name in their filename.
    If not specified, returns all keys found in the .ssh directory.

.PARAMETER KeyPath
    Directory to search for SSH keys. Default is ~/.ssh (or $env:USERPROFILE\.ssh on Windows).

.PARAMETER PublicKeyOnly
    Return only public keys (skip private keys). Useful for listing keys you can share.

.PARAMETER IncludeContent
    Include the full public key content in the output. Useful for copying keys to remote servers.

.INPUTS
    System.String
    You can pipe key names to Get-AitherSSHKey.

.OUTPUTS
    PSCustomObject
    Returns SSH key objects with properties:
    - Name: Key name identifier
    - PrivateKeyPath: Path to private key file
    - PublicKeyPath: Path to public key file
    - KeyType: Type of key (RSA, ED25519, etc.)
    - Fingerprint: SSH key fingerprint
    - Comment: Comment embedded in key
    - PublicKeyContent: Public key content (if -IncludeContent specified)
    - Created: File creation timestamp
    - Modified: File modification timestamp

.EXAMPLE
    Get-AitherSSHKey
    
    Lists all SSH keys in the default .ssh directory.

.EXAMPLE
    Get-AitherSSHKey -Name "production"
    
    Finds SSH keys with "production" in their name.

.EXAMPLE
    Get-AitherSSHKey -IncludeContent
    
    Lists all keys and includes their public key content for easy copying.

.EXAMPLE
    Get-AitherSSHKey -PublicKeyOnly
    
    Lists only public keys (skips private keys).

.EXAMPLE
    "production", "github" | Get-AitherSSHKey
    
    Gets information for multiple keys by piping key names.

.NOTES
    This cmdlet searches for SSH key files in the .ssh directory. It recognizes common
    SSH key naming patterns and extracts information from the key files themselves.

.LINK
    New-AitherSSHKey
    Add-AitherSSHKey
    Remove-AitherSSHKey
#>
function Get-AitherSSHKey {
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [AllowEmptyString()]
    [string]$Name,
    
    [string]$KeyPath,
    
    [switch]$PublicKeyOnly,
    
    [switch]$IncludeContent
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
}

process { try {
        if (-not (Test-Path $KeyPath)) {
            Write-AitherLog -Level Warning -Message "SSH key directory not found: $KeyPath" -Source $PSCmdlet.MyInvocation.MyCommand.Name
            return @()
        }
        
        # Find SSH key files
        $keyFiles = Get-ChildItem -Path $KeyPath -File -ErrorAction SilentlyContinue | 
            Where-Object { 
                $_.Name -match '^(id_rsa|id_ed25519|id_ecdsa|id_dsa)(_[\w-]+)?(\.pub)?$' -and
                (-not $PublicKeyOnly -or $_.Extension -eq '.pub')
            }
        
        $keys = @()
        $processedKeys = @{}
        
        foreach ($file in $keyFiles) {
            # Determine if this is a public or private key
            $isPublic = $file.Extension -eq '.pub'
            $baseName = if ($isPublic) { $file.BaseName } else { $file.Name }
            
            # Extract key name (everything after the key type prefix)
            $keyName = $null
            $keyType = $null
            
            if ($baseName -match '^(id_rsa|id_ed25519|id_ecdsa|id_dsa)(?:_(.+))?$') {
                $keyType = $matches[1] -replace '^id_', ''
                $keyName = if ($matches[2]) { $matches[2] } else { 'default' }
            }
            else {
                continue
            }
            
            # Filter by name if specified
            if ($Name -and $keyName -notlike "*$Name*") {
                continue
            }
            
            # Skip if we've already processed this key pair
            $keyId = "${keyType}_${keyName}"
            if ($processedKeys.ContainsKey($keyId)) {
                continue
            }
            
            $privateKeyPath = if ($isPublic) {
                $privatePath = Join-Path $KeyPath ($baseName -replace '\.pub$', '')
                if (Test-Path $privatePath) { $privatePath } else { $null }
            }
            else {
                $file.FullName
            }
            
            $publicKeyPath = if ($isPublic) {
                $file.FullName
            }
            else {
                $publicPath = "${file.FullName}.pub"
                if (Test-Path $publicPath) { $publicPath } else { $null }
            }
            
            # Get fingerprint and comment from public key
            $fingerprint = "Unknown"
            $comment = ""
            $publicKeyContent = ""
            
            if ($publicKeyPath -and (Test-Path $publicKeyPath)) {
                $publicKeyContent = Get-Content -Path $publicKeyPath -Raw -ErrorAction SilentlyContinue
                
                if ($publicKeyContent) {
                    # Extract comment (everything after the second space)
                    if ($publicKeyContent -match '^\S+\s+\S+\s+(.+)$') {
                        $comment = $matches[1].Trim()
                    }
                    
                    # Get fingerprint
                    if (Get-Command ssh-keygen -ErrorAction SilentlyContinue) {
                        $fingerprintOutput = & ssh-keygen -lf $publicKeyPath 2>&1
                        if ($fingerprintOutput -match '^\d+\s+([a-f0-9:]+)') {
                            $fingerprint = $matches[1]
                        }
                    }
                }
            }
            
            $keyInfo = [PSCustomObject]@{
                PSTypeName = 'AitherZero.SSHKey'
                Name = $keyName
                PrivateKeyPath = $privateKeyPath
                PublicKeyPath = $publicKeyPath
                KeyType = $keyType.ToUpper()
                Fingerprint = $fingerprint
                Comment = $comment
                Created = $file.CreationTime
                Modified = $file.LastWriteTime
            }
            
            if ($IncludeContent -and $publicKeyContent) {
                $keyInfo | Add-Member -NotePropertyName 'PublicKeyContent' -NotePropertyValue $publicKeyContent.Trim()
            }
            
            $keys += $keyInfo
            $processedKeys[$keyId] = $true
        }
        
        return $keys
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Getting SSH keys" -Parameters $PSBoundParameters -ThrowOnError
    }
}


}

