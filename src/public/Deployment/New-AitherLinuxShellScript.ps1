#Requires -Version 7.0

<#
.SYNOPSIS
    Generate Linux shell script from configuration

.DESCRIPTION
    Creates a shell script that applies Linux configuration settings from config.linux.psd1.

.PARAMETER ConfigPath
    Path to Linux configuration file

.PARAMETER OutputPath
    Output directory for generated file

.EXAMPLE
    New-AitherLinuxShellScript -ConfigPath ./config.linux.psd1
    
    Generate Linux shell script from configuration

.OUTPUTS
    String - Path to generated file, or null if generation is disabled

.NOTES
    Requires config.linux.psd1 with Linux.DeploymentArtifacts.ShellScript section.
    Generated script is made executable on Unix systems.

.LINK
    New-AitherDeploymentArtifact
    New-AitherLinuxCloudInit
#>
function New-AitherLinuxShellScript {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,
    
    [string]$OutputPath = './artifacts/linux'
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
            Write-AitherLog -Message "Generating Linux shell script from $ConfigPath" -Level Information -Source 'New-AitherLinuxShellScript'
        }
        
        # Load configuration
        if (-not (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Get-AitherConfigs is not available. Cannot generate shell script." -Source 'New-AitherLinuxShellScript'
            return $null
        }
        
        $config = Get-AitherConfigs -ConfigFile $ConfigPath
        
        if (-not $config.Linux.DeploymentArtifacts.ShellScript.Generate) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "Shell script generation is disabled in configuration" -Level Warning -Source 'New-AitherLinuxShellScript'
            } else {
                Write-Warning "Shell script generation is disabled in configuration"
            }
                return $null
        }
        
        $scriptConfig = $config.Linux.DeploymentArtifacts.ShellScript
        
        # Build shell script
        $scriptLines = @()
        $scriptLines += $scriptConfig.Shebang
        $scriptLines += "#"
        $scriptLines += "# AitherZero Linux Configuration Script"
        $scriptLines += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $scriptLines += "#"
        $scriptLines += ""
        $scriptLines += "set -e  # Exit on error"
        $scriptLines += ""
        
        # Add hostname configuration
        if ($config.Linux.System.Hostname.Name) {
            $scriptLines += "# Set hostname"
            $scriptLines += "hostnamectl set-hostname $($config.Linux.System.Hostname.Name)"
            $scriptLines += ""
        }
        
        # Add kernel parameters
        if ($config.Linux.KernelParameters.AutoApply) {
            $scriptLines += "# Configure kernel parameters"
            $scriptLines += "cat > $($config.Linux.KernelParameters.ConfigFile) << 'EOF'"
            foreach ($param in $config.Linux.KernelParameters.Parameters.GetEnumerator()) {
                $scriptLines += "$($param.Key) = $($param.Value)"
            }
            $scriptLines += "EOF"
            $scriptLines += "sysctl -p $($config.Linux.KernelParameters.ConfigFile)"
            $scriptLines += ""
        }
        
        # Add package installation
        if ($config.Linux.Packages.Essential.Count -gt 0) {
            $scriptLines += "# Install essential packages"
            $scriptLines += "apt-get update -qq"
            $scriptLines += "apt-get install -y $($config.Linux.Packages.Essential -join ' ')"
            $scriptLines += ""
        }
        
        # Add firewall rules
        if ($config.Linux.Firewall.AutoApply) {
            $scriptLines += "# Configure firewall"
            $scriptLines += "ufw default $($config.Linux.Firewall.DefaultPolicy.Incoming) incoming"
            $scriptLines += "ufw default $($config.Linux.Firewall.DefaultPolicy.Outgoing) outgoing"
            
            foreach ($rule in $config.Linux.Firewall.Rules | Where-Object { $_.Enabled -ne $false }) {
                $scriptLines += "ufw $($rule.Action) $($rule.Port)/$($rule.Protocol)"
            }
            if ($config.Linux.Firewall.Enabled) {
                $scriptLines += "ufw --force enable"
            }
            $scriptLines += ""
        }
        
        $scriptLines += "echo 'AitherZero configuration complete!'"
        
        # Ensure output directory exists
        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        
        # Save shell script
        $outputFile = Join-Path $OutputPath $scriptConfig.FileName
        $scriptLines -join "`n" | Out-File -FilePath $outputFile -Encoding UTF8 -Force
        
        # Make executable on Unix
        if ($IsLinux -or $IsMacOS) {
            chmod +x $outputFile
        }
        
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generated shell script: $outputFile" -Level Information -Source 'New-AitherLinuxShellScript'
        }
        return $outputFile
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error generating shell script: $($_.Exception.Message)" -Level Error -Source 'New-AitherLinuxShellScript' -Exception $_
        } else {
            Write-Error "Error generating shell script: $($_.Exception.Message)"
        }
        throw
    }
}

}

