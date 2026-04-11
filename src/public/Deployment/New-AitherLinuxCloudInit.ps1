#Requires -Version 7.0

<#
.SYNOPSIS
    Generate cloud-init configuration from Linux config

.DESCRIPTION
    Creates a cloud-init YAML/JSON configuration file based on config.linux.psd1.

.PARAMETER ConfigPath
    Path to Linux configuration file

.PARAMETER OutputPath
    Output directory for generated file

.PARAMETER Format
    Output format: yaml or json

.EXAMPLE
    New-AitherLinuxCloudInit -ConfigPath ./config.linux.psd1
    
    Generate cloud-init YAML configuration

.OUTPUTS
    String - Path to generated file, or null if generation is disabled

.NOTES
    Requires config.linux.psd1 with Linux.DeploymentArtifacts.CloudInit section.
    Generation can be disabled in configuration.

.LINK
    New-AitherDeploymentArtifact
    New-AitherLinuxShellScript
#>
function New-AitherLinuxCloudInit {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,
    
    [string]$OutputPath = './artifacts/linux',
    
    [ValidateSet('yaml', 'json')]
    [string]$Format = 'yaml'
)

begin {
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $moduleRoot = Get-AitherModuleRoot
        $OutputPath = Join-Path $moduleRoot $OutputPath
    }
    
    # Helper function for YAML conversion
    function ConvertTo-SimpleYaml {
        param([hashtable]$Data, [int]$Indent = 0)
        $yaml = ""
        $indentStr = "  " * $Indent
        foreach ($key in $Data.Keys) {
            $value = $Data[$key]
            if ($value -is [hashtable]) {
                $yaml += "$indentStr$($key):`n"
                $yaml += ConvertTo-SimpleYaml -Data $value -Indent ($Indent + 1)
            }
            elseif ($value -is [array]) {
                $yaml += "$indentStr$($key):`n"
                foreach ($item in $value) {
                    if ($item -is [hashtable]) {
                        $yaml += "$indentStr  -`n"
                        foreach ($subKey in $item.Keys) {
                            $yaml += "$indentStr    $($subKey): $($item[$subKey])`n"
                        }
                    }
                    else {
                        $yaml += "$indentStr  - $item`n"
                    }
                }
            }
            elseif ($null -ne $value) {
                $yaml += "$indentStr$($key): $value`n"
            }
        }
        return $yaml
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return $null
        }
        
        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue
        
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generating cloud-init configuration from $ConfigPath" -Level Information -Source 'New-AitherLinuxCloudInit'
        }
        
        # Load configuration
        if (-not (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Get-AitherConfigs is not available. Cannot generate cloud-init config." -Source 'New-AitherLinuxCloudInit'
            return $null
        }
        
        $config = Get-AitherConfigs -ConfigFile $ConfigPath
        
        if (-not $config.Linux.DeploymentArtifacts.CloudInit.Generate) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "Cloud-init generation is disabled in configuration" -Level Warning -Source 'New-AitherLinuxCloudInit'
            } else {
                Write-Warning "Cloud-init generation is disabled in configuration"
            }
            return $null
        }
        
        $cloudInitConfig = $config.Linux.DeploymentArtifacts.CloudInit
        
        # Build cloud-init configuration
        $cloudInit = @{
            '#cloud-config' = $null
            hostname = $config.Linux.System.Hostname.Name
            fqdn = $config.Linux.System.Hostname.FQDN
            manage_etc_hosts = $true
        }
        
        # Add users
        if ($config.Linux.Users.Create.Count -gt 0) {
            $cloudInit.users = @()
            foreach ($user in $config.Linux.Users.Create) {
                $cloudInit.users += @{
                    name = $user.Username
                    groups = $user.Groups -join ','
                    shell = $user.Shell
                    sudo = if ($user.Groups -contains 'sudo') { 'ALL=(ALL) NOPASSWD:ALL' } else { $null }
                }
            }
        }
        
        # Add packages
        if ($config.Linux.Packages.Essential.Count -gt 0) {
            $cloudInit.packages = $config.Linux.Packages.Essential
        }
        
        # Add kernel parameters
        if ($config.Linux.KernelParameters.AutoApply) {
            $cloudInit.write_files = @(
                @{
                    path = $config.Linux.KernelParameters.ConfigFile
                    content = ($config.Linux.KernelParameters.Parameters.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join "`n"
                    owner = 'root:root'
                    permissions = '0644'
                }
            )
        }
        
        # Ensure output directory exists
        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        
        # Save cloud-init file
        $fileName = if ($Format -eq 'yaml') { 'cloud-init.yaml' } else { 'cloud-init.json' }
        $outputFile = Join-Path $OutputPath $fileName
        
        if ($Format -eq 'yaml') {
            $yamlContent = "#cloud-config`n"
            $yamlContent += ConvertTo-SimpleYaml -Data $cloudInit
            $yamlContent | Out-File -FilePath $outputFile -Encoding UTF8 -Force
        }
        else {
            $cloudInit | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding UTF8 -Force
        }
        
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generated cloud-init config: $outputFile" -Level Information -Source 'New-AitherLinuxCloudInit'
        }
        return $outputFile
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error generating cloud-init config: $($_.Exception.Message)" -Level Error -Source 'New-AitherLinuxCloudInit' -Exception $_
        } else {
            Write-Error "Error generating cloud-init config: $($_.Exception.Message)"
        }
        throw
    }
}

}

