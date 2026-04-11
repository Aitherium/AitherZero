<#
.SYNOPSIS
    Manages AitherZero secure secrets.

.DESCRIPTION
    Wrapper for Set-AitherSecret and Get-AitherSecret.
    Allows setting or retrieving secrets in the secure store.
    
.PARAMETER Action
    The action to perform: 'Set' or 'Get'.

.PARAMETER Name
    The key/name of the secret.

.PARAMETER Value
    (Set only) The secret value.

.PARAMETER Scope
    The scope of the secret (User, System, Process). Default: User.

.EXAMPLE
    ./0601_Manage-Secrets.ps1 -Action Set -Name "OpenAIKey" -Value "sk-..."
    ./0601_Manage-Secrets.ps1 -Action Get -Name "OpenAIKey"

.NOTES
    Script Number: 0601
    Author: AitherZero
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Set', 'Get')]
    [string]$Action,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Name,

    [Parameter(Mandatory = $false, Position = 2)]
    [string]$Value,

    [Parameter(Mandatory = $false)]
    [ValidateSet('User', 'System', 'Process')]
    [string]$Scope = 'User'
)

try {
    Import-Module ./AitherZero/AitherZero.psd1 -Force -ErrorAction Stop

    if ($Action -eq 'Set') {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            throw "Value is required for 'Set' action."
        }
        Set-AitherSecret -Name $Name -Value $Value -Scope $Scope
        Write-Host "Secret '$Name' saved successfully in scope '$Scope'." -ForegroundColor Green
    }
    elseif ($Action -eq 'Get') {
        $secret = Get-AitherSecret -Name $Name -Scope $Scope
        if ($secret) {
            Write-Host "Secret Found." -ForegroundColor Green
            # Do not output secret to host by default for security, but return object
            return $secret
        } else {
            Write-Warning "Secret '$Name' not found."
        }
    }
}
catch {
    Write-Error "Secret management failed: $_"
    exit 1
}
