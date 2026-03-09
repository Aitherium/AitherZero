#Requires -Version 7.0

<#
.SYNOPSIS
    Analyze and ingest configuration from config.psd1

.DESCRIPTION
    Analyzes the config.psd1 file and provides easy access to configuration data.
    Can return the full configuration, specific sections, or print formatted output.
    This is the primary way to access configuration in automation scripts.

    This cmdlet automatically merges configuration from multiple sources in the correct order:
    1. Base config.psd1
    2. OS-specific config (config.windows.psd1, config.linux.psd1, config.macos.psd1)
    3. Local overrides (config.local.psd1)
    4. Custom config file (if specified)

    This ensures that local and OS-specific settings override base configuration appropriately.

.PARAMETER Section
    Optional section name to retrieve (e.g., 'Automation', 'Features', 'Core').
    If specified, returns only the requested section instead of the entire configuration.

    Common sections:
    - Automation: Script execution and orchestration settings
    - Features: Feature flags and dependencies
    - Core: Core platform settings
    - Logging: Logging configuration
    - EnvironmentConfiguration: Environment setup settings

.PARAMETER Key
    Optional key within a section to retrieve. Must be used together with -Section.
    Returns only the value of the specified key within the section.

    Example: Get-AitherConfigs -Section Features -Key Node
    Returns only the Node feature configuration.

.PARAMETER ConfigFile
    Path to a custom configuration file (defaults to config.psd1 in module root).
    If specified, this file is merged on top of all other configuration sources.
    Useful for environment-specific configurations or testing.

    The path can be absolute or relative to the module root.

.PARAMETER AsObject
    Return configuration as a PowerShell object (default behavior).
    This is the default and allows you to access configuration properties directly.

.PARAMETER Print
    Print formatted configuration to console instead of returning object.
    Useful for quickly viewing configuration without assigning to a variable.
    If Section or Key is specified, prints only that portion.

.PARAMETER Path
    Return only the path to the configuration file that would be used.
    Useful for verifying which config file will be loaded or for other file operations.

.INPUTS
    System.String
    You can pipe configuration file paths to Get-AitherConfigs.

.OUTPUTS
    Hashtable
    Returns configuration as a hashtable (PowerShell object) by default.

    System.String
    Returns a string path when -Path is used.

.EXAMPLE
    $config = Get-AitherConfigs
    $config.Automation.MaxConcurrency

    Gets the full configuration and accesses the MaxConcurrency setting.

.EXAMPLE
    $automation = Get-AitherConfigs -Section Automation
    $automation.MaxConcurrency

    Gets only the Automation section and accesses MaxConcurrency.

.EXAMPLE
    Get-AitherConfigs -Section Features -Key Node

    Gets only the Node feature configuration.

.EXAMPLE
    Get-AitherConfigs -Print

    Prints the entire configuration to the console in formatted JSON.

.EXAMPLE
    # In automation script
    $config = Get-AitherConfigs
    if ($config.Features.Node.Enabled) {
        # Install Node.js
    }

    Checks if Node feature is enabled before installing.

.EXAMPLE
    Get-AitherConfigs -ConfigFile './config.test.psd1'

    Loads configuration from a custom test configuration file.

.EXAMPLE
    './config.local.psd1' | Get-AitherConfigs

    Pipes a configuration file path to Get-AitherConfigs.

.NOTES
    This function is designed to be used by automation scripts to ingest configuration.
    It handles hierarchical merging of config files automatically.

    Configuration files use PowerShell Data (.psd1) format, which is a native PowerShell format
    that supports IntelliSense in IDEs and can be easily version controlled.

.LINK
    Set-AitherConfig
    Test-AitherConfig
    Export-AitherConfig
#>
function Get-AitherConfigs {
    [OutputType([Hashtable], [System.String])]
    [CmdletBinding(DefaultParameterSetName = 'Object')]
    param(
        [Parameter(ParameterSetName = 'Object')]
        [Parameter(ParameterSetName = 'Print')]
        [string]$Section,

        [Parameter(ParameterSetName = 'Object')]
        [Parameter(ParameterSetName = 'Print')]
        [string]$Key,

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$ConfigFile,

        [Parameter(ParameterSetName = 'Object')]
        [switch]$AsObject,

        [Parameter(ParameterSetName = 'Print')]
        [switch]$Print,

        [Parameter(ParameterSetName = 'Path')]
        [switch]$Path
    )

    begin {
        # Get module root first
        # Try Get-AitherModuleRoot (private function, so use try/catch instead of Get-Command)
        try {
            $moduleRoot = Get-AitherModuleRoot
        }
        catch {
            # Fallback to finding AitherZero directory
            $curr = $PSScriptRoot
            while ($curr -and -not (Test-Path (Join-Path $curr 'AitherZero.psd1'))) {
                $curr = Split-Path $curr -Parent
            }
            $moduleRoot = if ($curr) { $curr } else { $env:AITHERZERO_ROOT }
        }

        # Import-ConfigDataFile is loaded from AitherZero/Private/ during module initialization
        # No need to import aithercore modules

        if (-not $ConfigFile) {
            # Try both possible config locations (handles running from repo root or module dir)
            $possiblePaths = @(
                (Join-Path $moduleRoot 'config/config.psd1'),           # When moduleRoot is AitherZero dir
                (Join-Path $moduleRoot 'AitherZero/config/config.psd1') # When moduleRoot is repo root
            )
            $ConfigFile = $possiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $ConfigFile) {
                # Fallback to standard path if neither exists
                $ConfigFile = Join-Path $moduleRoot 'AitherZero/config/config.psd1'
            }
        }
        elseif (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
            $ConfigFile = Join-Path $moduleRoot $ConfigFile
        }

        # During module import validation, skip config loading if called with empty parameters
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $Section -and -not $Key -and -not $Print -and -not $Path) {
            return
        }
    }

    process {
        try {
            # Return path if requested
            if ($Path) {
                return $ConfigFile
            }

            # Load and merge configuration files
            # Determine base path for config files (handle both repo root and module dir)
            $configBasePath = if (Test-Path (Join-Path $moduleRoot 'config/config.psd1')) {
                $moduleRoot  # moduleRoot is the AitherZero directory
            }
            else {
                Join-Path $moduleRoot 'AitherZero'  # moduleRoot is repo root
            }

            $baseConfigPath = Join-Path $configBasePath 'config/config.psd1'
            $localConfigPath = Join-Path $configBasePath 'config/config.local.psd1'

            # Detect OS for OS-specific configuration
            $osConfigPath = $null
            if ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT') {
                $osConfigPath = Join-Path $configBasePath 'config/config.windows.psd1'
            }
            elseif ($IsLinux) {
                $osConfigPath = Join-Path $configBasePath 'config/config.linux.psd1'
            }
            elseif ($IsMacOS) {
                $osConfigPath = Join-Path $configBasePath 'config/config.macos.psd1'
            }

            # Helper function to load config file
            function Import-ConfigDataFile {
                param([string]$Path)
                if (-not (Test-Path $Path)) {
                    return $null
                }
                try {
                    $content = Get-Content -Path $Path -Raw -ErrorAction Stop
                    if ([string]::IsNullOrWhiteSpace($content)) {
                        return $null
                    }
                    $scriptBlock = [scriptblock]::Create($content)
                    $data = & $scriptBlock
                    if ($data -is [hashtable]) {
                        # Validate hashtable has valid keys (empty hashtable is valid)
                        if ($data.Keys.Count -gt 0) {
                            $hasValidKeys = $false
                            foreach ($key in $data.Keys) {
                                if (-not [string]::IsNullOrWhiteSpace($key)) {
                                    $hasValidKeys = $true
                                    break
                                }
                            }
                            if (-not $hasValidKeys) {
                                Write-AitherLog -Level Warning -Message "Config file $Path contains only empty keys. Skipping." -Source 'Get-AitherConfigs'
                                return $null
                            }
                        }
                        # Empty hashtable is valid - return it
                        return $data
                    }
                    return $null
                }
                catch {
                    Write-AitherLog -Level Warning -Message "Failed to load config file $Path : $($_.Exception.Message)" -Source 'Get-AitherConfigs' -Exception $_
                    return $null
                }
            }

            # Helper function to deep merge hashtables
            function Merge-Configuration {
                param(
                    [hashtable]$Current,
                    [hashtable]$New
                )
                if (-not $Current) { return $New }
                if (-not $New) { return $Current }

                $merged = $Current.Clone()
                foreach ($key in $New.Keys) {
                    if ($merged.ContainsKey($key)) {
                        if ($merged[$key] -is [hashtable] -and $New[$key] -is [hashtable]) {
                            $merged[$key] = Merge-Configuration -Current $merged[$key] -New $New[$key]
                        }
                        else {
                            $merged[$key] = $New[$key]
                        }
                    }
                    else {
                        # Handle dot notation keys in $New (e.g., "AI.Ollama.Enabled")
                        if ($key -match '\.') {
                            $parts = $key.Split('.')
                            $currentLevel = $merged
                            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                                $part = $parts[$i]
                                if (-not $currentLevel.ContainsKey($part) -or $currentLevel[$part] -isnot [hashtable]) {
                                    $currentLevel[$part] = @{}
                                }
                                $currentLevel = $currentLevel[$part]
                            }
                            $finalKey = $parts[-1]
                            $currentLevel[$finalKey] = $New[$key]
                        }
                        else {
                            $merged[$key] = $New[$key]
                        }
                    }
                }
                return $merged
            }

            # Start with base configuration
            $config = $null
            if (Test-Path $baseConfigPath) {
                $config = Import-ConfigDataFile -Path $baseConfigPath
            }
            else {
                throw "Base configuration file not found: $baseConfigPath"
            }

            # Merge OS-specific configuration
            if ($osConfigPath -and (Test-Path $osConfigPath)) {
                $osConfig = Import-ConfigDataFile -Path $osConfigPath
                if ($osConfig) {
                    $config = Merge-Configuration -Current $config -New $osConfig
                }
            }

            # Merge domain configurations
            $domainsPath = Join-Path $moduleRoot 'AitherZero/config/domains'
            if (Test-Path $domainsPath) {
                $domainFiles = Get-ChildItem -Path $domainsPath -Filter '*.psd1' -File
                foreach ($file in $domainFiles) {
                    $domainConfig = Import-ConfigDataFile -Path $file.FullName
                    if ($domainConfig) {
                        $config = Merge-Configuration -Current $config -New $domainConfig
                    }
                }
            }

            # Merge local overrides
            if (Test-Path $localConfigPath) {
                $localConfig = Import-ConfigDataFile -Path $localConfigPath
                if ($localConfig) {
                    $config = Merge-Configuration -Current $config -New $localConfig
                }
            }

            # Merge custom config file (highest priority)
            if ($ConfigFile -and (Test-Path $ConfigFile)) {
                $customConfig = Import-ConfigDataFile -Path $ConfigFile
                if ($customConfig) {
                    $config = Merge-Configuration -Current $config -New $customConfig
                }
            }

            # Filter by section if specified
            if ($Section) {
                if ($config.ContainsKey($Section)) {
                    $config = $config[$Section]
                }
                else {
                    Write-AitherLog -Level Warning -Message "Section '$Section' not found in configuration" -Source 'Get-AitherConfigs'
                    return $null
                }
            }

            # Filter by key if specified
            if ($Key) {
                if ($config -is [hashtable] -and $config.ContainsKey($Key)) {
                    $config = $config[$Key]
                }
                else {
                    Write-AitherLog -Level Warning -Message "Key '$Key' not found in configuration" -Source 'Get-AitherConfigs'
                    return $null
                }
            }

            # Print or return
            if ($Print) {
                if ($Section -or $Key) {
                    $config | Format-List
                }
                else {
                    $config | ConvertTo-Json -Depth 10 | ForEach-Object { Write-AitherLog -Level Information -Message $_ -Source 'Get-AitherConfigs' }
                }
            }
            else {
                return $config
            }
        }
        catch {
            Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Loading configuration" -Parameters $PSBoundParameters -ThrowOnError
        }
    }

}

