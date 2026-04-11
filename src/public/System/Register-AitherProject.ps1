#Requires -Version 7.0

function Register-AitherProject {
    <#
    .SYNOPSIS
        Register a project in the AitherZero registry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Language = 'PowerShell',
        [string]$Template = 'Standard'
    )

    $registryPath = Get-AitherProjectRegistryPath
    $projects = @()

    # Load existing
    if (Test-Path $registryPath) {
        try {
            $content = Get-Content -Path $registryPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($content)) {
                $projects = @($content | ConvertFrom-Json)
            }
        }
        catch {
            Write-AitherLog -Level Warning -Message "Corrupt registry file found. Creating new one." -Source 'Register-AitherProject' -Exception $_
        }
    }

    # Remove existing entry if any (update)
    $projects = @($projects | Where-Object { $_.Path -ne $Path -and $_.Name -ne $Name })

    # Add new entry
    $newProject = [PSCustomObject]@{
        Name         = $Name
        Path         = $Path
        Language     = $Language
        Template     = $Template
        Created      = (Get-Date).ToString("o")
        LastAccessed = (Get-Date).ToString("o")
    }

    $projects += $newProject

    # Save
    $projects | ConvertTo-Json -Depth 5 | Set-Content -Path $registryPath
    Write-Verbose "Registered project '$Name' at '$Path'"
}

