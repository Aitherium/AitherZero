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

    .PARAMETER Command
        Optional. The executable the package provides (e.g. 'git', 'node').
        If it already resolves on PATH and -Force is not set, the install is
        skipped. This is what makes a playbook re-runnable: without it, winget
        exits non-zero for an already-installed package and the step throws.

    .EXAMPLE
        Install-AitherPackage -Name "git" -WingetId "Git.Git" -Command git
        # Installs "Git.Git" on Winget, but "git" on other providers.
        # No-op if `git` is already on PATH.

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
        [string]$YumName,

        [Parameter(Mandatory = $false)]
        [string]$Command
    )

    process {
        try {
            # 0. Already present? Skip unless forced. Checked BEFORE provider
            #    detection so a machine with no package manager but the tool
            #    already installed still passes.
            if ($Command -and -not $Force) {
                $existing = Get-Command $Command -ErrorAction SilentlyContinue
                if ($existing) {
                    Write-AitherLog -Level Information -Message "'$Command' already installed ($($existing.Source)); skipping '$Name'. Use -Force to reinstall." -Source 'Install-AitherPackage'
                    return
                }
            }

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

            # winget reports "already installed, no applicable upgrade" as
            # 0x8A15002B (APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED),
            # which is -1978335189 as a signed int. That is success for our
            # purposes — the package is there.
            $alreadyInstalledCodes = @(-1978335189)
            if ($LASTEXITCODE -eq 0 -or ($Provider -eq 'winget' -and $LASTEXITCODE -in $alreadyInstalledCodes)) {
                Write-AitherLog -Level Information -Message "Successfully installed $TargetName." -Source 'Install-AitherPackage'
            } else {
                Write-AitherLog -Level Error -Message "Package installation failed with exit code $LASTEXITCODE" -Source 'Install-AitherPackage'
                # Don't throw by default to allow script continuation?
                # No, usually installation failure is critical.
                throw "Failed to install $TargetName"
            }

            # The installer wrote its bin dir to the persisted PATH; this
            # process still has the old one. Refresh so the caller's verify
            # step (`Get-Command node`) sees what was just installed.
            Update-AitherSessionPath

            if ($Command -and -not (Get-Command $Command -ErrorAction SilentlyContinue)) {
                Write-AitherLog -Level Warning -Message "'$TargetName' installed but '$Command' is still not on PATH in this session. A new terminal may be required." -Source 'Install-AitherPackage'
            }
        }
        catch {
            Write-AitherLog -Level Error -Message "Failed to install package '$Name': $_" -Source 'Install-AitherPackage' -Exception $_
            throw $_
        }
    }
}
