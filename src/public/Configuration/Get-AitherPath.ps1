#Requires -Version 7.0

<#
.SYNOPSIS
    Resolve installation or data paths from AitherZero configuration.

.DESCRIPTION
    Get-AitherPath resolves paths from the Paths section of AitherZero configuration
    with proper precedence:

    1. Environment variable (AITHERZERO_<PATH_KEY>)
    2. config.local.psd1 override
    3. config.psd1 default
    4. Fallback default parameter

    Supports cross-platform path placeholders:
    - {InstallRoot} - Resolves to platform-specific installation root
    - {DataRoot} - Resolves to platform-specific data storage root

    This function ensures all automation scripts use consistent, configurable paths
    instead of hardcoding installation directories.

.PARAMETER PathKey
    The path key to resolve, using dot notation relative to the Paths section.
    Examples:
    - 'InstallRoot' -> Paths.InstallRoot
    - 'Applications.Docker.InstallPath' -> Paths.Applications.Docker.InstallPath
    - 'Data.Models' -> Paths.Data.Models

.PARAMETER Default
    Fallback value if path is not configured. Required.

.PARAMETER CreateIfMissing
    If specified, create the directory if it doesn't exist.

.PARAMETER Configuration
    Optional pre-loaded configuration hashtable. If not provided,
    calls Get-AitherConfigs.

.EXAMPLE
    # Get Docker install path
    $dockerPath = Get-AitherPath -PathKey 'Applications.Docker.InstallPath' -Default '{InstallRoot}Docker'

.EXAMPLE
    # Get models directory and ensure it exists
    $modelsPath = Get-AitherPath -PathKey 'Data.Models' -Default '{DataRoot}/models' -CreateIfMissing

.EXAMPLE
    # Override via environment variable
    $env:AITHERZERO_APPLICATIONS_DOCKER_INSTALLPATH = 'D:\MyDocker'
    $path = Get-AitherPath -PathKey 'Applications.Docker.InstallPath' -Default '{InstallRoot}Docker'
    # Returns: D:\MyDocker

.NOTES
    All automation scripts should use this function instead of hardcoding paths.
    Users can customize paths in config.local.psd1 or via environment variables.

    Path placeholders work cross-platform:
    - Windows: {InstallRoot} defaults to D:\ (or secondary drive)
    - Linux/macOS: {InstallRoot} defaults to $HOME/aitherzero
    - CI: {InstallRoot} defaults to $GITHUB_WORKSPACE/aitherzero
#>

function Get-AitherPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$PathKey,

        [Parameter(Mandatory, Position = 1)]
        [string]$Default,

        [Parameter()]
        [switch]$CreateIfMissing,

        [Parameter()]
        [hashtable]$Configuration
    )

    # Load configuration if not provided
    if (-not $Configuration) {
        $Configuration = Get-AitherConfigs -ErrorAction SilentlyContinue
    }

    $resolvedPath = $null

    # 1. Check environment variable (highest priority)
    # Convert path key to env var name: Applications.Docker.InstallPath -> AITHERZERO_APPLICATIONS_DOCKER_INSTALLPATH
    $envVarName = "AITHERZERO_$($PathKey -replace '\.', '_')".ToUpper()
    $envValue = [Environment]::GetEnvironmentVariable($envVarName)

    if (-not [string]::IsNullOrEmpty($envValue)) {
        $resolvedPath = $envValue
        Write-Verbose "Path '$PathKey' resolved from environment variable $envVarName"
    }

    # 2. Check configuration (config.local.psd1 overrides config.psd1)
    if (-not $resolvedPath -and $Configuration -and $Configuration.Paths) {
        $pathParts = $PathKey -split '\.'
        $value = $Configuration.Paths

        foreach ($part in $pathParts) {
            if ($value -is [hashtable] -and $value.ContainsKey($part)) {
                $value = $value[$part]
            }
            else {
                $value = $null
                break
            }
        }

        if (-not [string]::IsNullOrEmpty($value) -and $value -is [string]) {
            $resolvedPath = $value
            Write-Verbose "Path '$PathKey' resolved from configuration"
        }
    }

    # 3. Use default
    if (-not $resolvedPath) {
        $resolvedPath = $Default
        Write-Verbose "Path '$PathKey' using default: $Default"
    }

    # Resolve {InstallRoot} and {DataRoot} placeholders
    $resolvedPath = Resolve-AitherPathPlaceholders -Path $resolvedPath -Configuration $Configuration

    # Expand environment variables in path
    $resolvedPath = [Environment]::ExpandEnvironmentVariables($resolvedPath)

    # Normalize path separators for current platform
    if ($IsWindows) {
        $resolvedPath = $resolvedPath -replace '/', '\'
    } else {
        $resolvedPath = $resolvedPath -replace '\\', '/'
    }

    # Create directory if requested
    if ($CreateIfMissing -and -not (Test-Path $resolvedPath)) {
        try {
            New-Item -ItemType Directory -Path $resolvedPath -Force | Out-Null
            Write-Verbose "Created directory: $resolvedPath"
        }
        catch {
            Write-AitherLog -Level Warning -Message "Failed to create directory '$resolvedPath': $_" -Source 'Get-AitherPath' -Exception $_
        }
    }

    return $resolvedPath
}

<#
.SYNOPSIS
    Resolve {InstallRoot} and {DataRoot} placeholders in paths.

.DESCRIPTION
    Internal helper function to resolve path placeholders to platform-specific
    values from configuration or defaults.
#>
function Resolve-AitherPathPlaceholders {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [hashtable]$Configuration
    )

    # Determine current platform
    $platform = if ($env:CI -or $env:GITHUB_ACTIONS) {
        'CI'
    } elseif ($IsWindows -or (-not $PSVersionTable.Platform) -or $PSVersionTable.Platform -eq 'Win32NT') {
        'Windows'
    } elseif ($IsMacOS) {
        'macOS'
    } else {
        'Linux'
    }

    # Resolve {InstallRoot}
    if ($Path -match '\{InstallRoot\}') {
        $installRoot = $null

        # Check environment variable first
        if ($env:AITHERZERO_INSTALL_ROOT) {
            $installRoot = $env:AITHERZERO_INSTALL_ROOT
        }
        # Check config.local.psd1 override (non-env-var value)
        elseif ($Configuration -and 
                $Configuration.Paths -and 
                $Configuration.Paths.InstallRoot -and 
                $Configuration.Paths.InstallRoot -notmatch '^\$env:') {
            $installRoot = $Configuration.Paths.InstallRoot
        }
        # Use platform-specific default from config
        elseif ($Configuration -and 
                $Configuration.Paths -and 
                $Configuration.Paths.InstallRootDefault -and
                $Configuration.Paths.InstallRootDefault[$platform]) {
            $installRoot = $Configuration.Paths.InstallRootDefault[$platform]
        }
        # Fallback defaults
        else {
            $installRoot = switch ($platform) {
                'Windows' { 'D:\' }
                'CI'      { Join-Path $env:GITHUB_WORKSPACE 'aitherzero' }
                default   { Join-Path $HOME 'aitherzero' }
            }
        }

        # Expand $HOME if present (for Linux/macOS defaults)
        if ($installRoot -match '^\$HOME') {
            $installRoot = $installRoot -replace '^\$HOME', $HOME
        }

        # Ensure trailing separator for consistency
        $sep = [IO.Path]::DirectorySeparatorChar
        if (-not $installRoot.EndsWith($sep) -and 
            -not $installRoot.EndsWith('/') -and 
            -not $installRoot.EndsWith('\')) {
            $installRoot += $sep
        }

        $Path = $Path -replace '\{InstallRoot\}', $installRoot
        Write-Verbose "Resolved {InstallRoot} to: $installRoot"
    }

    # Resolve {DataRoot}
    if ($Path -match '\{DataRoot\}') {
        $dataRoot = $null

        # Check environment variable first
        if ($env:AITHERZERO_DATA_ROOT) {
            $dataRoot = $env:AITHERZERO_DATA_ROOT
        }
        # Check config.local.psd1 override (non-env-var value)
        elseif ($Configuration -and 
                $Configuration.Paths -and 
                $Configuration.Paths.DataRoot -and 
                $Configuration.Paths.DataRoot -notmatch '^\$env:') {
            $dataRoot = $Configuration.Paths.DataRoot
        }
        # Use platform-specific default from config
        elseif ($Configuration -and 
                $Configuration.Paths -and 
                $Configuration.Paths.DataRootDefault -and
                $Configuration.Paths.DataRootDefault[$platform]) {
            $dataRoot = $Configuration.Paths.DataRootDefault[$platform]
            # DataRootDefault might contain {InstallRoot}, resolve recursively
            if ($dataRoot -match '\{InstallRoot\}') {
                $dataRoot = Resolve-AitherPathPlaceholders -Path $dataRoot -Configuration $Configuration
            }
        }
        # Fallback defaults
        else {
            $dataRoot = switch ($platform) {
                'Windows' { 'D:\AitherData' }
                'CI'      { Join-Path $env:GITHUB_WORKSPACE 'aitherzero-data' }
                default   { Join-Path $HOME 'aitherzero-data' }
            }
        }

        # Expand $HOME if present
        if ($dataRoot -match '^\$HOME') {
            $dataRoot = $dataRoot -replace '^\$HOME', $HOME
        }

        $Path = $Path -replace '\{DataRoot\}', $dataRoot
        Write-Verbose "Resolved {DataRoot} to: $dataRoot"
    }

    return $Path
}

# Export handled by build.ps1