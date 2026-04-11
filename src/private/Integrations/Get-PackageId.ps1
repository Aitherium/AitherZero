function Get-PackageId {
    <#
    .SYNOPSIS
        Gets the package ID for a software package on a specific package manager
    .PARAMETER SoftwareName
        The standard name of the software (e.g., 'git', 'nodejs', 'vscode')
    .PARAMETER PackageManagerName
        The name of the package manager (e.g., 'winget', 'chocolatey', 'apt')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SoftwareName,

        [Parameter(Mandatory)]
        [string]$PackageManagerName
    )

    $packageInfo = $script:SoftwarePackages[$SoftwareName.ToLower()]
    if (-not $packageInfo) {
        Write-Warning "No package mapping found for software: $SoftwareName"
        return $null
    }

    $packageId = $packageInfo[$PackageManagerName.ToLower()]
    if (-not $packageId) {
        Write-Warning "No package ID found for $SoftwareName on $PackageManagerName"
        return $null
    }

    return $packageId
}

