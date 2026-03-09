#Requires -Version 7.0

<#
.SYNOPSIS
    Generate Dockerfile from OS-specific configuration

.DESCRIPTION
    Creates a Dockerfile based on Linux or Windows configuration from config files.

.PARAMETER ConfigPath
    Path to configuration file (Linux or Windows)

.PARAMETER OutputPath
    Output directory for generated file

.PARAMETER Platform
    Target platform: linux or windows

.EXAMPLE
    New-AitherDockerfile -ConfigPath ./config.linux.psd1 -Platform linux
    
    Generate Linux Dockerfile

.EXAMPLE
    New-AitherDockerfile -ConfigPath ./config.windows.psd1 -Platform windows
    
    Generate Windows Dockerfile

.OUTPUTS
    String - Path to generated file, or null if generation is disabled

.NOTES
    Requires config.linux.psd1 or config.windows.psd1 with DeploymentArtifacts.Dockerfile section.
    Generation can be disabled in configuration.

.LINK
    New-AitherDeploymentArtifact
#>
function New-AitherDockerfile {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,
    
    [string]$OutputPath = './artifacts/docker',
    
    [ValidateSet('linux', 'windows')]
    [string]$Platform = 'linux'
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
            Write-AitherLog -Message "Generating Dockerfile from $ConfigPath" -Level Information -Source 'New-AitherDockerfile'
        }
        
        # Load configuration
        if (-not (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Get-AitherConfigs is not available. Cannot generate Dockerfile." -Source 'New-AitherDockerfile'
            return $null
        }
        
        $config = Get-AitherConfigs -ConfigFile $ConfigPath
        
        $dockerLines = @()
        $dockerConfig = $null
        
        if ($Platform -eq 'linux') {
            if (-not $config.Linux.DeploymentArtifacts.Dockerfile.Generate) {
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Dockerfile generation is disabled in configuration" -Level Warning -Source 'New-AitherDockerfile'
                } else {
                    Write-Warning "Dockerfile generation is disabled in configuration"
                }
                return $null
            }
            
            $dockerConfig = $config.Linux.DeploymentArtifacts.Dockerfile
            
            $dockerLines += "# AitherZero Linux Container"
            $dockerLines += "FROM $($dockerConfig.BaseImage)"
            $dockerLines += ""
            $dockerLines += "# Update and install packages"
            $dockerLines += "RUN apt-get update && apt-get install -y \"
            $dockerLines += "    $($config.Linux.Packages.Essential -join ' ') \"
            $dockerLines += "    && rm -rf /var/lib/apt/lists/*"
            $dockerLines += ""
            
            # Add environment variables
            if ($config.Linux.EnvironmentVariables.System.Count -gt 0) {
                $dockerLines += "# Environment variables"
                foreach ($env in $config.Linux.EnvironmentVariables.System.GetEnumerator()) {
                    $dockerLines += "ENV $($env.Key)=$($env.Value)"
                }
                $dockerLines += ""
            }
            
            $dockerLines += "WORKDIR /workspace"
            $dockerLines += 'CMD ["/bin/bash"]'
        }
        elseif ($Platform -eq 'windows') {
            if (-not $config.Windows.DeploymentArtifacts.Dockerfile.Generate) {
                if ($hasWriteAitherLog) {
                    Write-AitherLog -Message "Dockerfile generation is disabled in configuration" -Level Warning -Source 'New-AitherDockerfile'
                } else {
                    Write-Warning "Dockerfile generation is disabled in configuration"
                }
                return $null
            }
            
            $dockerConfig = $config.Windows.DeploymentArtifacts.Dockerfile
            
            $dockerLines += "# AitherZero Windows Container"
            $dockerLines += "FROM $($dockerConfig.BaseImage)"
            $dockerLines += ""
            $dockerLines += "# Install PowerShell packages"
            if ($config.Windows.PowerShell.Modules.Count -gt 0) {
                $dockerLines += "RUN Install-PackageProvider -Name NuGet -Force"
                foreach ($module in $config.Windows.PowerShell.Modules) {
                    $dockerLines += "RUN Install-Module -Name $module -Force -SkipPublisherCheck"
                }
                $dockerLines += ""
            }
            
            # Add environment variables
            if ($config.Windows.EnvironmentVariables.System.Count -gt 0) {
                $dockerLines += "# Environment variables"
                foreach ($env in $config.Windows.EnvironmentVariables.System.GetEnumerator()) {
                    $dockerLines += "ENV $($env.Key)=$($env.Value)"
                }
                $dockerLines += ""
            }
            
            $dockerLines += "WORKDIR C:\\workspace"
            $dockerLines += 'CMD ["powershell.exe"]'
        }
        
        # Validate that dockerConfig was set
        if (-not $dockerConfig) {
            throw "Docker configuration not found for platform: $Platform"
        }
        
        # Ensure output directory exists
        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        
        # Save Dockerfile
        $outputFile = Join-Path $OutputPath $dockerConfig.FileName
        $dockerLines -join "`n" | Out-File -FilePath $outputFile -Encoding UTF8 -Force
        
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generated Dockerfile: $outputFile" -Level Information -Source 'New-AitherDockerfile'
        }
        return $outputFile
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error generating Dockerfile: $($_.Exception.Message)" -Level Error -Source 'New-AitherDockerfile' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Error generating Dockerfile: $($_.Exception.Message)" -Source 'New-AitherDockerfile' -Exception $_
        }
        throw
    }
}

}

