#Requires -Version 7.0

<#
.SYNOPSIS
    List all stored credentials

.DESCRIPTION
    Returns a list of all credentials stored in the credential store.
    Shows credential names, types, and creation dates without exposing
    the actual credential values.
    
    This cmdlet is useful for:
    - Discovering what credentials are stored
    - Managing credential inventory
    - Identifying old or unused credentials
    - Auditing credential usage

.EXAMPLE
    Get-AitherCredentialList
    
    Lists all stored credentials with their types and creation dates.

.EXAMPLE
    Get-AitherCredentialList | Where-Object { $_.Type -eq 'ApiKey' }
    
    Lists only API key credentials.

.EXAMPLE
    Get-AitherCredentialList | Format-Table Name, Type, Created
    
    Displays credentials in a formatted table.

.INPUTS
    None
    This cmdlet does not accept pipeline input.

.OUTPUTS
    PSCustomObject
    Returns objects with properties:
    - Name: Credential name
    - Type: Credential type (Credential or ApiKey)
    - Created: Creation date/time
    - Path: Full path to credential file

.NOTES
    Security:
    - Does not expose credential values
    - Only shows metadata (name, type, creation date)
    - Safe to use in scripts and automation
    
    The credential store location is:
    - Windows: %USERPROFILE%\.aitherzero\credentials\
    - Linux/macOS: ~/.aitherzero/credentials/

.LINK
    Set-AitherCredential
    Get-AitherCredential
    Remove-AitherCredential
#>
function Get-AitherCredentialList {
[OutputType([PSCustomObject])]
[CmdletBinding()]
param()

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
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return @()
        }
        
        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue
        
        if (-not (Test-Path $credentialPath)) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Level Information -Message "Credential store does not exist" -Source 'Get-AitherCredentialList' -Data @{ Path = $credentialPath }
            }
            return @()
        }
        
        $credFiles = Get-ChildItem -Path $credentialPath -Filter "*.cred" -ErrorAction SilentlyContinue
        
        if ($credFiles.Count -eq 0) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Level Information -Message "No credentials found" -Source 'Get-AitherCredentialList'
            }
            return @()
        }
        
        $credentials = @()
        foreach ($file in $credFiles) {
            try {
                $credData = Import-Clixml -Path $file.FullName
                $name = $file.BaseName
                
                $credentials += [PSCustomObject]@{
                    PSTypeName = 'AitherZero.CredentialInfo'
                    Name = $name
                    Type = if ($credData.Type) { $credData.Type }
    else { 'Unknown' }
                    Created = if ($credData.Created) { [DateTime]::Parse($credData.Created) }
    else { $file.CreationTime }
                    Path = $file.FullName
                }
            }
    catch {
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Level Warning -Message "Failed to read credential file: $($file.Name)" -Source 'Get-AitherCredentialList' -Exception $_
                }
            }
        }
        
        if ($hasWriteAitherLog) {
            Write-AitherLog -Level Information -Message "Found $($credentials.Count) credential(s)" -Source 'Get-AitherCredentialList'
        }
        return $credentials | Sort-Object Name
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Listing credentials" -Parameters $PSBoundParameters -ThrowOnError
    }
}

}

