#Requires -Version 7.0

<#
.SYNOPSIS
    Generate Windows Unattend.xml from configuration

.DESCRIPTION
    Creates an Unattend.xml file for Windows automated installation
    based on settings from config.windows.psd1.

.PARAMETER ConfigPath
    Path to Windows configuration file

.PARAMETER OutputPath
    Output directory for generated file

.PARAMETER FileName
    Output filename (default: Autounattend.xml)

.EXAMPLE
    New-AitherWindowsUnattendXml -ConfigPath ./config.windows.psd1

    Generate Unattend.xml from Windows configuration

.OUTPUTS
    String - Path to generated file, or null if generation is disabled

.NOTES
    Requires config.windows.psd1 with DeploymentArtifacts.Unattend section.
    Generation can be disabled in configuration.

.LINK
    New-AitherDeploymentArtifact
    New-AitherWindowsRegistryFile
#>
function New-AitherWindowsUnattendXml {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,

    [string]$OutputPath = './artifacts/windows',

    [string]$FileName = 'Autounattend.xml',

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
            Write-AitherLog -Message "Generating Windows Unattend.xml from $ConfigPath" -Level Information -Source 'New-AitherWindowsUnattendXml'
        }

        # Load configuration
        if (-not (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Get-AitherConfigs is not available. Cannot generate Unattend.xml." -Source 'New-AitherWindowsUnattendXml'
            return $null
        }

        $config = Get-AitherConfigs -ConfigFile $ConfigPath

        if (-not $config.Windows.DeploymentArtifacts.Unattend.Generate) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "Unattend.xml generation is disabled in configuration" -Level Warning -Source 'New-AitherWindowsUnattendXml'
            } else {
                Write-AitherLog -Level Warning -Message "Unattend.xml generation is disabled in configuration" -Source 'New-AitherWindowsUnattendXml'
            }
            return $null
        }

        $unattendConfig = $config.Windows.DeploymentArtifacts.Unattend

        # Create XML document
        $xml = [xml]@'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
</unattend>
'@

        # Add windowsPE configuration pass
        $windowsPE = $xml.CreateElement('settings', $xml.DocumentElement.NamespaceURI)
        $windowsPE.SetAttribute('pass', 'windowsPE')

        # Add specialize configuration pass
        $specialize = $xml.CreateElement('settings', $xml.DocumentElement.NamespaceURI)
        $specialize.SetAttribute('pass', 'specialize')

        # Add oobeSystem configuration pass
        $oobeSystem = $xml.CreateElement('settings', $xml.DocumentElement.NamespaceURI)
        $oobeSystem.SetAttribute('pass', 'oobeSystem')

        # Add computer name if configured
        if ($unattendConfig.ComputerName) {
            $component = $xml.CreateElement('component', $xml.DocumentElement.NamespaceURI)
            $component.SetAttribute('name', 'Microsoft-Windows-Shell-Setup')
            $component.SetAttribute('processorArchitecture', 'amd64')
            $component.SetAttribute('publicKeyToken', '31bf3856ad364e35')
            $component.SetAttribute('language', 'neutral')
            $component.SetAttribute('versionScope', 'nonSxS')

            $computerName = $xml.CreateElement('ComputerName', $xml.DocumentElement.NamespaceURI)
            $computerName.InnerText = $unattendConfig.ComputerName
            $component.AppendChild($computerName) | Out-Null

            $specialize.AppendChild($component) | Out-Null
        }

        $xml.DocumentElement.AppendChild($windowsPE) | Out-Null
        $xml.DocumentElement.AppendChild($specialize) | Out-Null
        $xml.DocumentElement.AppendChild($oobeSystem) | Out-Null

        # Ensure output directory exists
        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }

        # Save XML file
        $outputFile = Join-Path $OutputPath $FileName
        $xml.Save($outputFile)

        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generated Unattend.xml: $outputFile" -Level Information -Source 'New-AitherWindowsUnattendXml'
        }
        return $outputFile
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error generating Unattend.xml: $($_.Exception.Message)" -Level Error -Source 'New-AitherWindowsUnattendXml' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Error generating Unattend.xml: $($_.Exception.Message)" -Source 'New-AitherWindowsUnattendXml' -Exception $_
        }
        throw
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

