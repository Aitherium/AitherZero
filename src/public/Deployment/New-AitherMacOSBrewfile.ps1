#Requires -Version 7.0

<#
.SYNOPSIS
    Generate Homebrew Brewfile from macOS configuration

.DESCRIPTION
    Creates a Brewfile for installing Homebrew packages based on config.macos.psd1.

.PARAMETER ConfigPath
    Path to macOS configuration file

.PARAMETER OutputPath
    Output directory for generated file

.EXAMPLE
    New-AitherMacOSBrewfile -ConfigPath ./config.macos.psd1
    
    Generate Brewfile from macOS configuration

.OUTPUTS
    String - Path to generated file, or null if generation is disabled

.NOTES
    Requires config.macos.psd1 with macOS.DeploymentArtifacts.Brewfile section.
    Generation can be disabled in configuration.

.LINK
    New-AitherDeploymentArtifact
#>
function New-AitherMacOSBrewfile {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,
    
    [string]$OutputPath = './artifacts/macos'
)

begin {
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
            Write-AitherLog -Message "Generating Homebrew Brewfile from $ConfigPath" -Level Information -Source 'New-AitherMacOSBrewfile'
        }
        
        # Load configuration
        if (-not (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Get-AitherConfigs is not available. Cannot generate Brewfile." -Source 'New-AitherMacOSBrewfile'
            return $null
        }
        
        $config = Get-AitherConfigs -ConfigFile $ConfigPath
        
        if (-not $config.macOS.DeploymentArtifacts.Brewfile.Generate) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "Brewfile generation is disabled in configuration" -Level Warning -Source 'New-AitherMacOSBrewfile'
            } else {
                Write-AitherLog -Level Warning -Message "Brewfile generation is disabled in configuration" -Source 'New-AitherMacOSBrewfile'
            }
            return $null
        }
        
        $brewConfig = $config.macOS.DeploymentArtifacts.Brewfile
        $brewLines = @()
        
        # Add taps
        if ($brewConfig.IncludeTaps -and $config.macOS.Homebrew.Taps.Count -gt 0) {
            $brewLines += "# Taps"
            foreach ($tap in $config.macOS.Homebrew.Taps) {
                $brewLines += "tap '$tap'"
            }
            $brewLines += ""
        }
        
        # Add formulae
        if ($brewConfig.IncludeFormulae -and $config.macOS.Homebrew.Formulae.Count -gt 0) {
            $brewLines += "# Formulae"
            foreach ($formula in $config.macOS.Homebrew.Formulae) {
                $brewLines += "brew '$formula'"
            }
            $brewLines += ""
        }
        
        # Add casks
        if ($brewConfig.IncludeCasks -and $config.macOS.Homebrew.Casks.Count -gt 0) {
            $brewLines += "# Casks"
            foreach ($cask in $config.macOS.Homebrew.Casks) {
                $brewLines += "cask '$cask'"
            }
            $brewLines += ""
        }
        
        # Add Mac App Store apps
        if ($brewConfig.IncludeMAS -and $config.macOS.Homebrew.MAS.Count -gt 0) {
            $brewLines += "# Mac App Store"
            foreach ($app in $config.macOS.Homebrew.MAS) {
                $brewLines += "mas '$app'"
            }
        }
        
        # Ensure output directory exists
        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        
        # Save Brewfile
        $outputFile = Join-Path $OutputPath $brewConfig.FileName
        $brewLines -join "`n" | Out-File -FilePath $outputFile -Encoding UTF8 -Force
        
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generated Brewfile: $outputFile" -Level Information -Source 'New-AitherMacOSBrewfile'
        }
        return $outputFile
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error generating Brewfile: $($_.Exception.Message)" -Level Error -Source 'New-AitherMacOSBrewfile' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Error generating Brewfile: $($_.Exception.Message)" -Source 'New-AitherMacOSBrewfile' -Exception $_
        }
        throw
    }
}

}

