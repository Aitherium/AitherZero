#Requires -Version 7.0
# Stage: Development
# Dependencies: PackageManager
# Description: Install Azure CLI for cloud management using package managers (winget priority)

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [hashtable]$Configuration
)

. "$PSScriptRoot/_init.ps1"
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0212_Install-AzureCLI'
    } else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting Azure CLI installation..."

try {
    # 1. Check Configuration
    $azureCliConfig = $null
    if ($Configuration) {
        if ($Configuration.Features -and 
            $Configuration.Features.Cloud -and 
            $Configuration.Features.Cloud.AzureCLI) {
            
            $azureCliConfig = $Configuration.Features.Cloud.AzureCLI
            if ($azureCliConfig.Enabled -eq $false) {
                Write-ScriptLog "Azure CLI installation is disabled in configuration."
                exit 0
            }
        }
    }

    # 2. Install Azure CLI
    if ($PSCmdlet.ShouldProcess("System", "Install Azure CLI")) {
        Install-AitherPackage -Name "az" -WingetId "Microsoft.AzureCLI" -ChocoId "azure-cli" -BrewName "azure-cli" -AptName "azure-cli" -YumName "azure-cli"
    }

    # 3. Verify & Configure
    $azCmd = if ($IsWindows) { 'az.cmd' } else { 'az' }
    
    if (Get-Command $azCmd -ErrorAction SilentlyContinue) {
        # Get version (parse JSON)
        try {
             $vJson = & $azCmd version --output json | ConvertFrom-Json
             Write-ScriptLog "Azure CLI installed: $($vJson.'azure-cli')" -Level Success
        } catch {
             Write-ScriptLog "Azure CLI installed but version check failed." -Level Warning
        }

        # Configure Defaults
        if ($azureCliConfig -and $azureCliConfig.DefaultSettings) {
            foreach ($key in $azureCliConfig.DefaultSettings.Keys) {
                $val = $azureCliConfig.DefaultSettings[$key]
                if ($PSCmdlet.ShouldProcess("AzureConfig", "Set $key = $val")) {
                    & $azCmd config set $key=$val
                }
            }
        }

        # Install Extensions
        if ($azureCliConfig -and $azureCliConfig.Extensions) {
            foreach ($ext in $azureCliConfig.Extensions) {
                if ($PSCmdlet.ShouldProcess("AzureExt", "Install $ext")) {
                     Write-ScriptLog "Installing extension: $ext"
                     & $azCmd extension add --name $ext
                }
            }
        }

    } else {
        if ($IsWindows) {
            Write-ScriptLog "Azure CLI installed but 'az' command not found in current PATH. Restart shell." -Level Warning
        } else {
            throw "Azure CLI command not found after installation."
        }
    }

} catch {
    Write-ScriptLog "Azure CLI installation failed: $_" -Level Error
    exit 1
}
