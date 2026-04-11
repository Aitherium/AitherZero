#Requires -Version 7.0

<#
.SYNOPSIS
    Set configuration values in AitherZero configuration files

.DESCRIPTION
    Updates configuration values in config.psd1 or creates local overrides in config.local.psd1.
    This cmdlet allows you to modify configuration settings programmatically without manually
    editing configuration files.

    By default, changes are saved to config.local.psd1 (local overrides) which is gitignored
    and takes precedence over the main config.psd1. This prevents modifying version-controlled
    configuration files.

.PARAMETER Section
    Configuration section name. This parameter is REQUIRED and identifies which section
    of the configuration to modify.

    Common sections:
    - Core: Core platform settings (Environment, Profile, etc.)
    - Automation: Script execution and orchestration settings
    - Features: Feature flags and component settings
    - Logging: Logging configuration
    - SSHKeyManagement: SSH key management settings
    - PSSessionManagement: PSSession management settings

    Examples:
    - "Core"
    - "Automation"
    - "Features"

.PARAMETER Key
    Key within the section to set. This parameter is REQUIRED and can be a simple key
    or a nested key path using dot notation.

    Examples:
    - "Environment" - Simple key in Core section
    - "MaxConcurrency" - Simple key in Automation section
    - "Node.Enabled" - Nested key (Node feature's Enabled property)
    - "DefaultPort.WinRM" - Nested key in PSSessionManagement section

    For nested keys, use dot notation: "Section.Subsection.Key"

.PARAMETER Value
    Value to set for the configuration key. Can be any PowerShell object type:
    - Strings: "Production", "Development"
    - Booleans: $true, $false
    - Numbers: 8, 30, 3600
    - Arrays: @("Item1", "Item2")
    - Hashtables: @{ Key = "Value" }

    If not specified, the key will be removed from the configuration.

.PARAMETER Path
    Path to a specific configuration file. If not specified, defaults to config.local.psd1
    (for local overrides) or config.psd1 (if -Global is specified).

    Can be:
    - Relative path: "config.test.psd1"
    - Absolute path: "C:\Configs\custom.psd1"

    Use this to save to a custom configuration file for testing or environment-specific configs.

.PARAMETER Local
    Save to config.local.psd1 (default behavior). This is the recommended approach as
    config.local.psd1 is gitignored and won't affect version control.

    Local overrides take precedence over the main config.psd1, so your changes will
    be applied when configuration is loaded.

.PARAMETER Global
    Save to main config.psd1. Use with caution as this modifies version-controlled files.
    Only use this when you want to make permanent changes to the base configuration.

    Warning: Changes to config.psd1 will affect all users and environments unless overridden.

.INPUTS
    System.String
    You can pipe configuration section names to Set-AitherConfig.

.OUTPUTS
    PSCustomObject
    Returns the updated configuration section or key with the new value.

.EXAMPLE
    Set-AitherConfig -Section Core -Key Environment -Value 'Production'

    Sets the Environment setting in the Core section to 'Production' in config.local.psd1.

.EXAMPLE
    Set-AitherConfig -Section Automation -Key MaxConcurrency -Value 8

    Sets MaxConcurrency to 8 in the Automation section.

.EXAMPLE
    Set-AitherConfig -Section Features -Key Node -Key Enabled -Value $true

    Sets the Node feature's Enabled property to $true. Note: This example shows nested keys
    but the actual syntax uses dot notation in the Key parameter.

.EXAMPLE
    Set-AitherConfig -Section PSSessionManagement -Key "DefaultPort.WinRM" -Value 5985

    Sets a nested configuration value using dot notation.

.EXAMPLE
    "Core", "Automation" | Set-AitherConfig -Key "Verbose" -Value $true

    Sets the Verbose key in multiple sections by piping section names.

.EXAMPLE
    Set-AitherConfig -Section Logging -Key RetentionDays -Value 60 -Global

    Sets retention days in the main config.psd1 (use with caution).

.NOTES
    By default, saves to config.local.psd1 to avoid modifying version-controlled files.
    Local overrides are automatically merged when configuration is loaded via Get-AitherConfigs.

    Configuration precedence (highest to lowest):
    1. Command-line parameters
    2. Environment variables (AITHERZERO_*)
    3. config.local.psd1 (local overrides)
    4. config.psd1 (base configuration)

    Changes take effect immediately for new operations. Existing processes may need to
    reload configuration.

.LINK
    Get-AitherConfigs
    Test-AitherConfig
    Export-AitherConfig
    Compare-AitherConfig
#>
function Set-AitherConfig {
[OutputType([PSCustomObject])]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage="Configuration section name (e.g., Core, Automation).")]
    [AllowEmptyString()]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        if (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue) {
            $config = Get-AitherConfigs
            $config.Keys |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_,
                        $_,
                        [System.Management.Automation.CompletionResultType]::ParameterValue,
                        "Configuration Section"
                    )
                }
        }
    })]
    [string]$Section,

    [Parameter(Mandatory=$false, Position = 1, HelpMessage="Key within the section to set (dot notation supported).")]
    [AllowEmptyString()]
    [string]$Key,

    [Parameter(HelpMessage="Value to set for the configuration key.")]
    [object]$Value,

    [Parameter()]
    [string]$Path,

    [Parameter()]
    [switch]$Local,

    [Parameter()]
    [switch]$Global,

    [Parameter(HelpMessage = "Show command output in console.")]
    [switch]$ShowOutput
)

begin {
    # Manage logging targets for this execution
    $originalLogTargets = $script:AitherLogTargets
    if ($ShowOutput) {
        if ($script:AitherLogTargets -notcontains 'Console') {
            $script:AitherLogTargets += 'Console'
        }
    }
    else {
        # Ensure Console is NOT in targets if ShowOutput is not specified
        $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
    }

    $moduleRoot = Get-AitherModuleRoot

    if (-not $Path) {
        if ($Global) {
            $Path = Join-Path $moduleRoot 'AitherZero/config/config.psd1'
        }
        else {
            $Path = Join-Path $moduleRoot 'AitherZero/config/config.local.psd1'
        }
    }
    elseif (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path $moduleRoot $Path
    }
}

process { try {
        # During module validation, parameters may be empty - skip validation
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and ([string]::IsNullOrWhiteSpace($Section) -or [string]::IsNullOrWhiteSpace($Key))) {
            return
        }

        # Validate required parameters
        if ([string]::IsNullOrWhiteSpace($Section)) {
            throw "Section parameter is required"
        }
        if ([string]::IsNullOrWhiteSpace($Key)) {
            throw "Key parameter is required"
        }

        # Load existing config or create new
        $config = @{}
        if (Test-Path $Path) {
            try {
                $content = Get-Content -Path $Path -Raw
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    $scriptBlock = [scriptblock]::Create($content)
                    $config = & $scriptBlock
                    if (-not ($config -is [hashtable])) {
                        $config = @{}
                    }
                    # Validate config has valid keys
                    $hasValidKeys = $false
                    foreach ($k in $config.Keys) {
                        if (-not [string]::IsNullOrWhiteSpace($k)) {
                            $hasValidKeys = $true
                            break
                        }
                    }
                    if (-not $hasValidKeys) {
                        $config = @{}
                    }
                }
            }
            catch {
                Write-AitherLog -Level Warning -Message "Failed to load existing config, creating new: $_" -Source 'Set-AitherConfig' -Exception $_
                $config = @{}
            }
        }

        # Ensure section exists
        if (-not $config.ContainsKey($Section)) {
            $config[$Section] = @{}
        }

        # Set value
        if ($config[$Section] -isnot [hashtable]) {
            $config[$Section] = @{}
        }

        # Handle nested keys (dot notation)
        $current = $config[$Section]
        $keyParts = $Key.Split('.')

        for ($i = 0; $i -lt $keyParts.Count - 1; $i++) {
            $part = $keyParts[$i]
            if (-not $current.ContainsKey($part) -or $current[$part] -isnot [hashtable]) {
                $current[$part] = @{}
            }
            $current = $current[$part]
        }

        $finalKey = $keyParts[-1]
        $current[$finalKey] = $Value

        # Convert to PowerShell data file format
        function ConvertTo-PowerShellData {
            param([hashtable]$Hashtable, [int]$Depth = 0)

            $indent = '    ' * $Depth
            $result = "@{`n"

            foreach ($key in $Hashtable.Keys | Sort-Object) {
                $value = $Hashtable[$key]

                if ($value -is [hashtable]) {
                    $result += "$indent    $key = $(ConvertTo-PowerShellData -Hashtable $value -Depth ($Depth + 1))`n"
                }
                elseif ($value -is [array]) {
                    $arrayStr = $value | ForEach-Object {
                        if ($_ -is [string]) {
                            "'$_'"
                        }
                        elseif ($_ -is [bool]) {
                            "`$$_"
                        }
                        else {
                            $_
                        }
                    }
                    $result += "$indent    $key = @($($arrayStr -join ', '))`n"
                }
                elseif ($value -is [string]) {
                    $result += "$indent    $key = '$value'`n"
                }
                elseif ($value -is [bool]) {
                    $result += "$indent    $key = `$$value`n"
                }
                else {
                    $result += "$indent    $key = $value`n"
                }
            }

            $result += "$indent}"
            return $result
        }

        # Save config
        $content = ConvertTo-PowerShellData -Hashtable $config

        if ($PSCmdlet.ShouldProcess($Path, "Update configuration")) {
            Set-Content -Path $Path -Value $content -Encoding UTF8
            Write-AitherLog -Message "Configuration updated: $Section.$Key = $Value" -Level Information -Source 'Set-AitherConfig'
            Write-AitherLog -Message "Saved to: $Path" -Level Information -Source 'Set-AitherConfig'
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Setting configuration: $Section.$Key" -Parameters $PSBoundParameters -ThrowOnError
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

