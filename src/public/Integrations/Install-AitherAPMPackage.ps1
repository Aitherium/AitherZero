#Requires -Version 7.0

<#
.SYNOPSIS
    Installs packages from the AitherOS Package Manager (APM).

.DESCRIPTION
    Queries and installs packages from the APM registry (managed by Genesis).
    Supports listing available packages, installing by name, and checking
    installed package status.

.PARAMETER Name
    Package name to install. Supports wildcards for search.

.PARAMETER Version
    Specific version to install. Defaults to latest.

.PARAMETER List
    List available packages instead of installing.

.PARAMETER Installed
    Show only installed packages.

.PARAMETER Search
    Search packages by keyword.

.PARAMETER GenesisUrl
    URL of the Genesis service. Defaults to http://localhost:8001.

.EXAMPLE
    Install-AitherAPMPackage -List
    # List all available APM packages

.EXAMPLE
    Install-AitherAPMPackage -Name "code-review-sensor"
    # Install a specific package

.EXAMPLE
    Install-AitherAPMPackage -Search "security"
    # Search for security-related packages

.EXAMPLE
    Install-AitherAPMPackage -Installed
    # Show installed packages

.NOTES
    Category: Integrations
    Dependencies: AitherOS Genesis (port 8001), PackageManager
    Platform: Windows, Linux, macOS
#>
function Install-AitherAPMPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [Parameter()]
        [string]$Version,

        [Parameter()]
        [switch]$List,

        [Parameter()]
        [switch]$Installed,

        [Parameter()]
        [string]$Search,

        [Parameter()]
        [string]$GenesisUrl
    )

    if (-not $GenesisUrl) {
        $ctx = Get-AitherLiveContext
        $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }
    }

    try {
        # List / Search mode
        if ($List -or $Search -or $Installed) {
            $endpoint = "$GenesisUrl/api/packages"
            $queryParams = @()
            if ($Search) { $queryParams += "q=$Search" }
            if ($Installed) { $queryParams += "installed=true" }
            if ($queryParams.Count -gt 0) {
                $endpoint += "?" + ($queryParams -join '&')
            }

            $result = Invoke-RestMethod -Uri $endpoint -Method GET -TimeoutSec 15 -ErrorAction Stop
            $packages = if ($result.packages) { $result.packages } else { $result }

            Write-Host "`n  APM Packages ($($packages.Count) found)" -ForegroundColor Cyan
            Write-Host "  $('─' * 60)" -ForegroundColor DarkGray

            foreach ($pkg in $packages) {
                $installedMark = if ($pkg.installed) { " [installed]" } else { "" }
                $ver = if ($pkg.version) { "v$($pkg.version)" } else { "" }
                Write-Host "  $($pkg.name) " -NoNewline -ForegroundColor White
                Write-Host "$ver" -NoNewline -ForegroundColor DarkYellow
                Write-Host "$installedMark" -ForegroundColor Green
                if ($pkg.description) {
                    Write-Host "    $($pkg.description)" -ForegroundColor DarkGray
                }
            }

            return $packages
        }

        # Install mode
        if (-not $Name) {
            Write-Error "Package name is required. Use -List to see available packages."
            return
        }

        if (-not $PSCmdlet.ShouldProcess("APM", "Install package '$Name'")) {
            return
        }

        Write-Host "`n  Installing APM package: $Name" -ForegroundColor Cyan

        $body = @{ name = $Name }
        if ($Version) { $body.version = $Version }

        $result = Invoke-RestMethod -Uri "$GenesisUrl/api/packages/install" `
            -Method POST -Body ($body | ConvertTo-Json -Compress) `
            -ContentType 'application/json' -TimeoutSec 60 -ErrorAction Stop

        $status = if ($result.status) { $result.status } else { 'installed' }
        Write-Host "  ${Name}: $status" -ForegroundColor Green

        if ($result.files) {
            Write-Host "  Files:" -ForegroundColor DarkGray
            foreach ($f in $result.files) {
                Write-Host "    $f" -ForegroundColor DarkGray
            }
        }

        # Report to Strata
        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'apm-install' -Data @{
                package = $Name
                version = if ($Version) { $Version } else { 'latest' }
                status = $status
            }
        }

        return $result
    }
    catch {
        Write-Warning "APM operation failed: $_"
        Write-Warning "Is Genesis running at $GenesisUrl?"
        return $null
    }
}
