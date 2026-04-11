<#
.SYNOPSIS
    Generates or retrieves AitherZero SSH Keys.

.DESCRIPTION
    Wrapper for New-AitherSSHKey.
    Generates a new SSH key pair if it doesn't exist.
    
.PARAMETER Name
    The name/alias of the key (e.g., 'id_rsa_github').

.PARAMETER Force
    Overwrite existing key.

.EXAMPLE
    ./0602_Generate-SSHKeys.ps1 -Name "github_deploy"

.NOTES
    Script Number: 0602
    Author: AitherZero
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

try {
    Import-Module ./AitherZero/AitherZero.psd1 -Force -ErrorAction Stop

    # Construct path or let cmdlet handle it
    # Assuming cmdlet defaults to standard SSH locations or internal store
    
    Write-Host "Generating SSH Key '$Name'..." -ForegroundColor Cyan
    $key = New-AitherSSHKey -Name $Name -Force:$Force
    
    Write-Host "SSH Key generated at: $($key.PublicKeyPath)" -ForegroundColor Green
    Write-Host "Public Key Content:" -ForegroundColor Gray
    Get-Content $key.PublicKeyPath
}
catch {
    Write-Error "SSH Key generation failed: $_"
    exit 1
}
