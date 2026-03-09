#Requires -Version 7.0

<#
.SYNOPSIS
    Generate all deployment artifacts from configuration files

.DESCRIPTION
    Main function to generate all deployment artifacts based on OS-specific configs.
    Supports Windows (Unattend.xml, registry files), Linux (cloud-init, shell scripts),
    macOS (Brewfiles), and Docker (Dockerfiles).

.PARAMETER Platform
    Target platform(s): Windows, Linux, macOS, Docker, or All

.PARAMETER ConfigPath
    Base path to configuration files (defaults to module root)

.PARAMETER OutputPath
    Base output directory for all artifacts

.EXAMPLE
    New-AitherDeploymentArtifact -Platform Windows
    
    Generate Windows deployment artifacts

.EXAMPLE
    New-AitherDeploymentArtifact -Platform All -OutputPath ./build/artifacts
    
    Generate all deployment artifacts for all platforms

.OUTPUTS
    Hashtable - Dictionary with platform keys (Windows, Linux, macOS, Docker) containing arrays of generated file paths

.NOTES
    Requires OS-specific configuration files (config.windows.psd1, config.linux.psd1, config.macos.psd1).
    Artifacts are generated in platform-specific subdirectories.

.LINK
    New-AitherWindowsUnattendXml
    New-AitherLinuxCloudInit
    New-AitherMacOSBrewfile
    New-AitherDockerfile
#>
function New-AitherDeploymentArtifact {
[CmdletBinding()]
param(
    [ValidateSet('Windows', 'Linux', 'macOS', 'Docker', 'All')]
    [string[]]$Platform = 'All',
    
    [string]$ConfigPath,
    
    [string]$OutputPath = './artifacts'
)

begin {
    # Get module root
    $moduleRoot = Get-AitherModuleRoot
    
    if (-not $ConfigPath) {
        $ConfigPath = $moduleRoot
    }
    elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
        $ConfigPath = Join-Path $moduleRoot $ConfigPath
    }
        if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path $moduleRoot $OutputPath
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return @{}
        }
        
        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue
        
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generating deployment artifacts for: $($Platform -join ', ')" -Level Information -Source 'New-AitherDeploymentArtifact'
        }
        
        $generated = @{
            Windows = @()
            Linux = @()
            macOS = @()
            Docker = @()
        }
        
        # Windows artifacts
        if ($Platform -contains 'Windows' -or $Platform -contains 'All') {
            $windowsConfig = Join-Path $ConfigPath 'config.windows.psd1'
            if (Test-Path $windowsConfig) {
                Write-AitherLog -Message "Processing Windows configuration..." -Level Information -Source 'New-AitherDeploymentArtifact'
                if (Get-Command New-AitherWindowsUnattendXml -ErrorAction SilentlyContinue) {
                    $unattend = New-AitherWindowsUnattendXml -ConfigPath $windowsConfig -OutputPath (Join-Path $OutputPath 'windows')
                    if ($unattend) { $generated.Windows += $unattend }
                }
                if (Get-Command New-AitherWindowsRegistryFile -ErrorAction SilentlyContinue) {
                    $registry = New-AitherWindowsRegistryFile -ConfigPath $windowsConfig -OutputPath (Join-Path $OutputPath 'windows')
                    if ($registry) { $generated.Windows += $registry }
                }
            }
        }
        
        # Linux artifacts
        if ($Platform -contains 'Linux' -or $Platform -contains 'All') {
            $linuxConfig = Join-Path $ConfigPath 'config.linux.psd1'
            if (Test-Path $linuxConfig) {
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Processing Linux configuration..." -Level Information -Source 'New-AitherDeploymentArtifact'
                }
                if (Get-Command New-AitherLinuxCloudInit -ErrorAction SilentlyContinue) {
                    $cloudInit = New-AitherLinuxCloudInit -ConfigPath $linuxConfig -OutputPath (Join-Path $OutputPath 'linux')
                    if ($cloudInit) { $generated.Linux += $cloudInit }
                }
                if (Get-Command New-AitherLinuxShellScript -ErrorAction SilentlyContinue) {
                    $shellScript = New-AitherLinuxShellScript -ConfigPath $linuxConfig -OutputPath (Join-Path $OutputPath 'linux')
                    if ($shellScript) { $generated.Linux += $shellScript }
                }
            }
        }
        
        # macOS artifacts
        if ($Platform -contains 'macOS' -or $Platform -contains 'All') {
            $macosConfig = Join-Path $ConfigPath 'config.macos.psd1'
            if (Test-Path $macosConfig) {
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Processing macOS configuration..." -Level Information -Source 'New-AitherDeploymentArtifact'
                }
                if (Get-Command New-AitherMacOSBrewfile -ErrorAction SilentlyContinue) {
                    $brewfile = New-AitherMacOSBrewfile -ConfigPath $macosConfig -OutputPath (Join-Path $OutputPath 'macos')
                    if ($brewfile) { $generated.macOS += $brewfile }
                }
            }
        }
        
        # Docker artifacts
        if ($Platform -contains 'Docker' -or $Platform -contains 'All') {
            $linuxConfig = Join-Path $ConfigPath 'config.linux.psd1'
            if (Test-Path $linuxConfig) {
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Processing Docker configuration..." -Level Information -Source 'New-AitherDeploymentArtifact'
                }
                if (Get-Command New-AitherDockerfile -ErrorAction SilentlyContinue) {
                    $dockerfile = New-AitherDockerfile -ConfigPath $linuxConfig -OutputPath (Join-Path $OutputPath 'docker') -Platform 'linux'
                    if ($dockerfile) { $generated.Docker += $dockerfile }
                }
            }
        }
        
        # Summary
        $totalGenerated = ($generated.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generated $totalGenerated deployment artifacts" -Level Information -Source 'New-AitherDeploymentArtifact'
        }
        return $generated
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error generating deployment artifacts: $($_.Exception.Message)" -Level Error -Source 'New-AitherDeploymentArtifact' -Exception $_
        } else {
            Write-AitherLog -Message "Error generating deployment artifacts: $($_.Exception.Message)" -Level Error -Source 'New-AitherDeploymentArtifact' -Exception $_
        }
        throw
    }
}

}

