#Requires -Version 7.0

<#
.SYNOPSIS
    Export configuration to various formats

.DESCRIPTION
    Exports configuration to JSON, YAML, XML, or PowerShell data file format.

.PARAMETER Path
    Output file path

.PARAMETER Format
    Export format: Json, Yaml, Xml, PowerShell

.PARAMETER Section
    Export only specific section

.PARAMETER Pretty
    Pretty-print output (formatted)

.EXAMPLE
    Export-AitherConfig -Path './config-backup.json' -Format Json

.EXAMPLE
    Export-AitherConfig -Section Automation -Format Yaml -Path './automation-config.yaml'

.NOTES
    Useful for backup, version control, or sharing configurations.
#>
function Export-AitherConfig {
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false)]
    [string]$Path,

    [Parameter()]
    [ValidateSet('Json', 'Yaml', 'Xml', 'PowerShell')]
    [string]$Format = 'Json',

    [Parameter()]
    [string]$Section,

    [Parameter()]
    [switch]$Pretty,

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

    # Guard against missing parameters during module load
    if (-not $Path) {
        return
    }

    $moduleRoot = Get-AitherModuleRoot
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $Path) {
            return
        }

        # Check if Get-AitherConfigs is available
        if (-not (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Get-AitherConfigs is not available. Cannot export configuration." -Source 'Export-AitherConfig'
            return
        }

        # Get configuration
        $config = if ($Section) {
            Get-AitherConfigs -Section $Section
        }
    else {
            Get-AitherConfigs
        }
        if (-not $config) {
            throw "Failed to load configuration"
        }

        # Convert to requested format
        $content = switch ($Format) {
            'Json' {
                if ($Pretty) {
                    $config | ConvertTo-Json -Depth 20
                }
    else {
                    $config | ConvertTo-Json -Depth 20 -Compress
                }
            }
            'Yaml' {
                # Simple YAML conversion (basic implementation)
                function ConvertTo-Yaml {
                    param([object]$Object, [int]$Indent = 0)
                    $spaces = '  ' * $Indent
                    $result = ''

                    if ($Object -is [hashtable]) {
                        foreach ($key in $Object.Keys) {
                            $value = $Object[$key]
                            if ($value -is [hashtable] -or $value -is [array]) {
                                $result += "$spaces$key`:`n"
                                $result += ConvertTo-Yaml -Object $value -Indent ($Indent + 1)
                            }
    else {
                                $valStr = if ($value -is [string]) { "'$value'" }
    else { $value }
                                $result += "$spaces$key`: $valStr`n"
                            }
                        }
                    }
    elseif ($Object -is [array]) {
                        foreach ($item in $Object) {
                            $result += "$spaces- $item`n"
                        }
                    }
    else {
                        $result += "$spaces$Object`n"
                    }
                    return $result
                }
                ConvertTo-Yaml -Object $config
            }
            'Xml' {
                $config | ConvertTo-Xml -Depth 20 -NoTypeInformation | Out-String
            }
            'PowerShell' {
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
                                if ($_ -is [string]) { "'$_'" }
    elseif ($_ -is [bool]) { "`$$_" }
    else { $_ }
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
                ConvertTo-PowerShellData -Hashtable $config
            }
        }

        # Save to file
        if ($PSCmdlet.ShouldProcess($Path, "Export configuration")) {
            Set-Content -Path $Path -Value $content -Encoding UTF8
            Write-AitherLog -Message "Configuration exported to: $Path" -Level Information
            Write-AitherLog -Message "Format: $Format" -Level Information
        }
    }
    catch {
        Write-AitherLog -Message "Failed to export configuration: $_" -Level Error -Source 'Export-AitherConfig' -Exception $_
        throw
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

