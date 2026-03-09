#Requires -Version 7.0
# Stage: Development
# Dependencies: None
# Description: Install AWS CLI for cloud management

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [hashtable]$Configuration
)

. "$PSScriptRoot/_init.ps1"
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0213_Install-AWSCLI'
    } else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting AWS CLI installation..."

try {
    # 1. Check Configuration
    $awsCliConfig = $null
    if ($Configuration) {
        if ($Configuration.Features -and 
            $Configuration.Features.Cloud -and 
            $Configuration.Features.Cloud.AWSCLI) {
            
            $awsCliConfig = $Configuration.Features.Cloud.AWSCLI
            if ($awsCliConfig.Enabled -eq $false) {
                Write-ScriptLog "AWS CLI installation is disabled in configuration."
                exit 0
            }
        }
    }

    # 2. Install AWS CLI
    if ($PSCmdlet.ShouldProcess("System", "Install AWS CLI")) {
        Install-AitherPackage -Name "aws" -WingetId "Amazon.AWSCLI" -ChocoId "awscli" -BrewName "awscli" -AptName "awscli" -YumName "awscli"
    }

    # 3. Verify & Configure
    $awsCmd = if ($IsWindows) { 'aws.exe' } else { 'aws' }
    
    if (Get-Command $awsCmd -ErrorAction SilentlyContinue) {
        $v = & $awsCmd --version
        Write-ScriptLog "AWS CLI installed: $v" -Level Success

        # Configure Defaults
        if ($awsCliConfig -and $awsCliConfig.DefaultSettings) {
            foreach ($key in $awsCliConfig.DefaultSettings.Keys) {
                 $val = $awsCliConfig.DefaultSettings[$key]
                 if ($PSCmdlet.ShouldProcess("AWSConfig", "Set $key = $val")) {
                     & $awsCmd configure set $key $val
                 }
            }
        }

    } else {
        if ($IsWindows) {
             Write-ScriptLog "AWS CLI installed but 'aws' command not found in PATH. Restart shell." -Level Warning
        } else {
             throw "AWS CLI command not found after installation."
        }
    }

} catch {
    Write-ScriptLog "AWS CLI installation failed: $_" -Level Error
    exit 1
}
