function Install-AitherPackage {
    <#
    .SYNOPSIS
        Installs a software package using the appropriate package manager for the OS.

    .DESCRIPTION
        Abstracts package management across Windows (Chocolatey, Winget, Scoop),
        Linux (APT, YUM/DNF, APK), and macOS (Homebrew).
        Detects the available package manager and installs the requested package.

    .PARAMETER Name
        The name of the package to install.

    .PARAMETER Provider
        Optional. Force a specific provider (e.g., 'apt', 'choco').
        If not specified, auto-detects the best available provider.

    .PARAMETER Version
        Optional. Specific version to install.

    .PARAMETER Force
        Re-install even if already present.

    .PARAMETER WingetId
        Optional. Specific package ID for Winget (e.g. 'Git.Git'). Overrides Name.

    .PARAMETER ChocoId
        Optional. Specific package ID for Chocolatey. Overrides Name.

    .PARAMETER BrewName
        Optional. Specific package name for Homebrew. Overrides Name.

    .PARAMETER AptName
        Optional. Specific package name for APT. Overrides Name.

    .PARAMETER YumName
        Optional. Specific package name for YUM/DNF. Overrides Name.

    .EXAMPLE
        Install-AitherPackage -Name "git" -WingetId "Git.Git"
        # Installs "Git.Git" on Winget, but "git" on other providers.

    .EXAMPLE
        Install-AitherPackage -Name "nodejs" -Provider "choco" -Version "18.0.0"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [ValidateSet('apt', 'yum', 'dnf', 'apk', 'brew', 'choco', 'winget', 'scoop')]
        [string]$Provider,

        [Parameter(Mandatory = $false)]
        [string]$Version,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$WingetId,

        [Parameter(Mandatory = $false)]
        [string]$ChocoId,

        [Parameter(Mandatory = $false)]
        [string]$BrewName,

        [Parameter(Mandatory = $false)]
        [string]$AptName,

        [Parameter(Mandatory = $false)]
        [string]$YumName
    )

    process {
        try {
            # 1. Detect Provider if not specified
            if ([string]::IsNullOrWhiteSpace($Provider)) {
                if ($IsLinux) {
                    if (Get-Command apt-get -ErrorAction SilentlyContinue) { $Provider = 'apt' }
                    elseif (Get-Command dnf -ErrorAction SilentlyContinue) { $Provider = 'dnf' }
                    elseif (Get-Command yum -ErrorAction SilentlyContinue) { $Provider = 'yum' }
                    elseif (Get-Command apk -ErrorAction SilentlyContinue) { $Provider = 'apk' }
                }
                elseif ($IsMacOS) {
                    if (Get-Command brew -ErrorAction SilentlyContinue) { $Provider = 'brew' }
                }
                elseif ($IsWindows) {
                    # Prioritize Winget (modern), then Chocolatey
                    if (Get-Command winget -ErrorAction SilentlyContinue) { $Provider = 'winget' }
                    elseif (Get-Command choco -ErrorAction SilentlyContinue) { $Provider = 'choco' }
                }
            }

            if ([string]::IsNullOrWhiteSpace($Provider)) {
                Write-AitherLog -Level Warning -Message "No supported package manager found on this system. Skipping installation of '$Name'." -Source 'Install-AitherPackage'
                return
            }

            Write-Verbose "Using package provider: $Provider"

            # 2. Resolve Package Name
            $TargetName = $Name
            switch ($Provider) {
                'winget' { if (-not [string]::IsNullOrWhiteSpace($WingetId)) { $TargetName = $WingetId } }
                'choco'  { if (-not [string]::IsNullOrWhiteSpace($ChocoId)) { $TargetName = $ChocoId } }
                'brew'   { if (-not [string]::IsNullOrWhiteSpace($BrewName)) { $TargetName = $BrewName } }
                'apt'    { if (-not [string]::IsNullOrWhiteSpace($AptName)) { $TargetName = $AptName } }
                'yum'    { if (-not [string]::IsNullOrWhiteSpace($YumName)) { $TargetName = $YumName } }
                'dnf'    { if (-not [string]::IsNullOrWhiteSpace($YumName)) { $TargetName = $YumName } }
            }

            # 3. Construct Command
            $cmd = ""
            $args = @()

            switch ($Provider) {
                'apt' {
                    $cmd = "sudo"
                    $args = @("apt-get", "install", "-y", $TargetName)
                    if ($Version) { $args[$args.Count-1] = "$TargetName=$Version" }
                }
                'yum' { 
                    $cmd = "sudo"
                    $args = @("yum", "install", "-y", $TargetName)
                    if ($Version) { $args[$args.Count-1] = "$TargetName-$Version" }
                }
                'dnf' {
                    $cmd = "sudo"
                    $args = @("dnf", "install", "-y", $TargetName)
                }
                'apk' {
                    $cmd = "sudo"
                    $args = @("apk", "add", "--no-cache", $TargetName)
                }
                'brew' {
                    $cmd = "brew"
                    $args = @("install", $TargetName)
                }
                'choco' {
                    $cmd = "choco"
                    $args = @("install", $TargetName, "-y")
                    if ($Version) { $args += @("--version", $Version) }
                    if ($Force) { $args += "--force" }
                }
                'winget' {
                    $cmd = "winget"
                    # --id is crucial for automation to avoid ambiguity
                    $args = @("install", "-e", "--id", $TargetName, "--accept-source-agreements", "--accept-package-agreements")
                    if ($Version) { $args += @("-v", $Version) }
                }
            }

            # 4. Execute
            Write-AitherLog -Level Information -Message "Installing '$TargetName' via $Provider..." -Source 'Install-AitherPackage'
            
            if ($cmd -eq "sudo") {
                & $cmd $args
            } else {
                & $cmd $args
            }

            if ($LASTEXITCODE -eq 0) {
                Write-AitherLog -Level Information -Message "Successfully installed $TargetName." -Source 'Install-AitherPackage'
            } else {
                Write-AitherLog -Level Error -Message "Package installation failed with exit code $LASTEXITCODE" -Source 'Install-AitherPackage'
                # Don't throw by default to allow script continuation? 
                # No, usually installation failure is critical.
                throw "Failed to install $TargetName"
            }
        }
        catch {
            Write-AitherLog -Level Error -Message "Failed to install package '$Name': $_" -Source 'Install-AitherPackage' -Exception $_
            throw $_
        }
    }
}
