function Install-AitherPackage {
    <#
    .SYNOPSIS
        Installs a software package using the best available package manager
    .PARAMETER SoftwareName
        The standard name of the software to install (e.g. 'git', 'nodejs', 'python')
    .PARAMETER PreferredPackageManager
        Optional preferred package manager name
    .PARAMETER Force
        Force installation even if package appears to be installed
    .PARAMETER WhatIf
        Show what would be done without actually installing
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SoftwareName,

        [string]$PreferredPackageManager,

        [switch]$Force
    )

    Write-Verbose "Starting installation of $SoftwareName"

    # Get available package managers in priority order
    $packageManagers = Get-AvailablePackageManagers
        if ($packageManagers.Count -eq 0) {
            throw "No package managers found on this system"
        }

        # If preferred package manager specified, try it first
        if ($PreferredPackageManager) {
            $preferred = $packageManagers | Where-Object { $_.Name -eq $PreferredPackageManager }
            if ($preferred) {
                $packageManagers = @($preferred) + ($packageManagers | Where-Object { $_.Name -ne $PreferredPackageManager })
            } else {
                Write-AitherLog -Level Warning -Message "Preferred package manager '$PreferredPackageManager' not available" -Source 'Install-AitherPackage'
            }
        }

    # Check if already installed (unless Force is specified)
    if (-not $Force) {
        foreach ($pm in $packageManagers) {
            if (Test-AitherPackageInstalled -SoftwareName $SoftwareName -PackageManager $pm) {
                Write-Verbose "$SoftwareName is already installed via $($pm.Name)"
                return @{ Success = $true; PackageManager = $pm.Name; Status = 'Already Installed' }
            }
        }
    }

    # Try installing with each package manager until one succeeds
    foreach ($pm in $packageManagers) {
        $packageId = Get-PackageId -SoftwareName $SoftwareName -PackageManagerName $pm.Name
        if (-not $packageId) {
            Write-Verbose "Skipping $($pm.Name) - no package mapping for $SoftwareName"
            continue
        }

        Write-Verbose "Attempting to install $SoftwareName ($packageId) via $($pm.Name)"

        try {
            # Handle special cases (e.g., brew cask)
            $installArgs = $pm.Config.InstallArgs
            if ($pm.Name -eq 'brew' -and $script:SoftwarePackages[$SoftwareName.ToLower()].brew_cask) {
                $installArgs = $pm.Config.CaskArgs
            }

            $args = $installArgs | ForEach-Object { $_ -f $packageId }

            if ($PSCmdlet.ShouldProcess("$SoftwareName via $($pm.Name)", "Install Package")) {
                # Update package manager cache for Linux systems
                if ($pm.Platform -eq 'Linux' -and $pm.Config.UpdateArgs -and $pm.Name -eq 'apt') {
                    Write-Verbose "Updating package cache for $($pm.Name)"
                    & sudo $pm.Config.Command @($pm.Config.UpdateArgs) 2>&1 | Out-Null
                }

                # Run installation
                $output = & $pm.Config.Command @args 2>&1

                if ($LASTEXITCODE -eq 0) {
                    Write-Verbose "$SoftwareName installed successfully via $($pm.Name)"

                    # Verify installation
                    Start-Sleep -Seconds 2
                    if (Test-AitherPackageInstalled -SoftwareName $SoftwareName -PackageManager $pm) {
                        return @{ Success = $true; PackageManager = $pm.Name; Status = 'Installed' }
                    } else {
                        Write-AitherLog -Level Warning -Message "Installation appeared successful but verification failed" -Source 'Install-AitherPackage'
                    }
                } else {
                    Write-AitherLog -Level Warning -Message "Installation failed via $($pm.Name): $output" -Source 'Install-AitherPackage'
                }
            }
        } catch {
            Write-AitherLog -Level Warning -Message "Error installing $SoftwareName via $($pm.Name): $_" -Source 'Install-AitherPackage' -Exception $_
        }
    }

    throw "Failed to install $SoftwareName with any available package manager"
}

