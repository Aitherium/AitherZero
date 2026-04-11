#Requires -Version 7.0

function Get-AitherProject {
    <#
    .SYNOPSIS
        List registered AitherZero projects.
    .PARAMETER Name
        Filter by project name (wildcards supported).
    #>
    [CmdletBinding()]
    param(
        [string]$Name = '*'
    )

    $registryPath = Get-AitherProjectRegistryPath

    if (-not (Test-Path $registryPath)) {
        return @()
    }

    try {
        $projects = Get-Content -Path $registryPath -Raw | ConvertFrom-Json
        if ($projects) {
            return $projects | Where-Object { $_.Name -like $Name }
        }
    }
    catch {
        Write-AitherLog -Level Warning -Message "Failed to read project registry: $_" -Source 'Get-AitherProject' -Exception $_
    }

    return @()
}

