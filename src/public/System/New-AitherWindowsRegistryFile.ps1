#Requires -Version 7.0

<#
.SYNOPSIS
    Generate Windows registry import file (.reg)

.DESCRIPTION
    Creates a .reg file with registry settings from config.windows.psd1.

.PARAMETER ConfigPath
    Path to Windows configuration file

.PARAMETER OutputPath
    Output directory for generated file

.EXAMPLE
    New-AitherWindowsRegistryFile -ConfigPath ./config.windows.psd1

    Generate registry file from Windows configuration

.OUTPUTS
    String - Path to generated file, or null if generation is disabled

.NOTES
    Requires config.windows.psd1 with Windows.Registry section.
    Generation can be disabled in configuration.

.LINK
    New-AitherDeploymentArtifact
    New-AitherWindowsUnattendXml
#>
function New-AitherWindowsRegistryFile {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,

    [string]$OutputPath = './artifacts/windows',

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

    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $moduleRoot = Get-AitherModuleRoot
        $OutputPath = Join-Path $moduleRoot $OutputPath
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return $null
        }

        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generating Windows registry file from $ConfigPath" -Level Information -Source 'New-AitherWindowsRegistryFile'
        }

        # Load configuration
        if (-not (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Get-AitherConfigs is not available. Cannot generate registry file." -Source 'New-AitherWindowsRegistryFile'
            return $null
        }

        $config = Get-AitherConfigs -ConfigFile $ConfigPath

        if (-not $config.Windows.DeploymentArtifacts.RegistryExport.Generate) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "Registry export is disabled in configuration" -Level Warning -Source 'New-AitherWindowsRegistryFile'
            } else {
                Write-AitherLog -Level Warning -Message "Registry export is disabled in configuration" -Source 'New-AitherWindowsRegistryFile'
            }
                return $null
        }

        $registryConfig = $config.Windows.Registry
        $outputFileName = $config.Windows.DeploymentArtifacts.RegistryExport.FileName

        # Start registry file content
        $regContent = @('Windows Registry Editor Version 5.00', '')

        # Process all registry categories
        foreach ($category in $registryConfig.Keys | Where-Object { $_ -ne 'AutoApply' -and $_ -ne 'BackupBeforeChanges' }) {
            $regContent += ""; $regContent += "; $category Settings"

            foreach ($settingKey in $registryConfig[$category].Keys) {
                $setting = $registryConfig[$category][$settingKey]

                if ($setting.Enabled -and $setting.Path -and $setting.Name) {
                    # Convert PowerShell path to registry path
                    $regPath = $setting.Path -replace 'HKLM:', 'HKEY_LOCAL_MACHINE' -replace 'HKCU:', 'HKEY_CURRENT_USER'

                    $regContent += "[$regPath]"

                    # Determine registry value type
                    $valueType = switch ($setting.Type) {
                        'DWord' { 'dword' }
                        'String' { '' }
                        'QWord' { 'qword' }
                        'Binary' { 'hex' }
                        'MultiString' { 'hex(7)' }
                        'ExpandString' { 'hex(2)' }
                        default { 'dword' }
                    }

                    if ($valueType -eq '') {
                        # String value
                        $regContent += "`"$($setting.Name)`"=`"$($setting.Value)`""
                    }
                    else {
                        # Other types
                        $value = $setting.Value
                        if ($valueType -eq 'dword' -and $value -is [bool]) {
                            $value = if ($value) { 1 } else { 0 }
                        }
                        $regContent += "`"$($setting.Name)`"=$valueType`:$([string]$value)"
                    }

                    if ($setting.Description) {
                        $regContent += "; $($setting.Description)"
                    }
                    $regContent += ""
                }
            }
        }

        # Ensure output directory exists
        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }

        # Save registry file
        $outputFile = Join-Path $OutputPath $outputFileName
        $regContent | Out-File -FilePath $outputFile -Encoding ASCII -Force

        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generated registry file: $outputFile" -Level Information -Source 'New-AitherWindowsRegistryFile'
        }
        return $outputFile
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error generating registry file: $($_.Exception.Message)" -Level Error -Source 'New-AitherWindowsRegistryFile' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Error generating registry file: $($_.Exception.Message)" -Source 'New-AitherWindowsRegistryFile' -Exception $_
        }
        throw
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

