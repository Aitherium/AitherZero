#Requires -Version 7.0
# Stage: Development
# Dependencies: AitherZero
# Description: Install Visual Studio Code editor using Install-AitherPackage.

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [hashtable]$Configuration
)

. "$PSScriptRoot/_init.ps1"
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0210_Install-VSCode'
    } else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting Visual Studio Code installation..."

try {
    # 1. Check Configuration
    $vscodeConfig = $null
    if ($Configuration) {
        if ($Configuration.Features -and 
            $Configuration.Features.Development -and 
            $Configuration.Features.Development.VSCode) {
            
            $vscodeConfig = $Configuration.Features.Development.VSCode
            if ($vscodeConfig.Enabled -eq $false) {
                Write-ScriptLog "VS Code installation is disabled in configuration."
                exit 0
            }
        }
    }

    # 2. Install VS Code
    if ($PSCmdlet.ShouldProcess("System", "Install Visual Studio Code")) {
        Install-AitherPackage -Name "code" -WingetId "Microsoft.VisualStudioCode" -ChocoId "vscode" -BrewName "visual-studio-code" -AptName "code" -YumName "code"
    }

    # 3. Verify & Install Extensions
    $codeCmd = if ($IsWindows) { 'code.cmd' } else { 'code' }
    
    if (Get-Command $codeCmd -ErrorAction SilentlyContinue) {
        $v = & $codeCmd --version
        Write-ScriptLog "VS Code installed: $($v[0])" -Level Success

        # Install Extensions
        if ($vscodeConfig -and $vscodeConfig.Extensions) {
            foreach ($ext in $vscodeConfig.Extensions) {
                Write-ScriptLog "Installing extension: $ext"
                if ($PSCmdlet.ShouldProcess("VSCode", "Install extension $ext")) {
                    try {
                        & $codeCmd --install-extension $ext --force
                    } catch {
                        Write-ScriptLog "Failed to install extension $ext" -Level Warning
                    }
                }
            }
        }

    } else {
        # On Windows, PATH might not be updated yet in current session
        if ($IsWindows) {
            Write-ScriptLog "VS Code installed but 'code' command not yet in PATH. Restart shell to use." -Level Warning
        } else {
            throw "VS Code command '$codeCmd' not found after installation."
        }
    }

} catch {
    Write-ScriptLog "VS Code installation failed: $_" -Level Error
    exit 1
}