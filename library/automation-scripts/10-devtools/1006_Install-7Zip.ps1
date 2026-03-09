#Requires -Version 7.0
# Stage: Development
# Dependencies: PackageManager
# Description: Install 7-Zip file archiver using package managers (winget priority)

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [hashtable]$Configuration
)

. "$PSScriptRoot/_init.ps1"
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0209_Install-7Zip'
    } else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting 7-Zip installation..."

try {
    # 1. Check Configuration
    if ($Configuration) {
        if ($Configuration.Features -and 
            $Configuration.Features.DevTools -and 
            $Configuration.Features.DevTools.SevenZip) {
            
            $sevenZipConfig = $Configuration.Features.DevTools.SevenZip
            if ($sevenZipConfig.Enabled -eq $false) {
                Write-ScriptLog "7-Zip installation is disabled in configuration."
                exit 0
            }
        }
    }

    # 2. Install 7-Zip
    if ($PSCmdlet.ShouldProcess("System", "Install 7-Zip")) {
        Install-AitherPackage -Name "7z" -WingetId "7zip.7zip" -ChocoId "7zip" -BrewName "sevenzip" -AptName "p7zip-full" -YumName "p7zip"
    }

    # 3. Verify Installation
    $cmd = if ($IsWindows) { '7z.exe' } else { '7z' }
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        # Test functionality
        $test = & $cmd 2>&1
        if ($test -match '7-Zip') {
            Write-ScriptLog "7-Zip verified: $cmd" -Level Success
        } else {
            Write-ScriptLog "7-Zip command found but output unexpected." -Level Warning
        }
    } else {
        # On Windows, might need a PATH refresh or manual check if not in PATH yet
        if ($IsWindows) {
            $paths = @(
                "$env:ProgramFiles\7-Zip\7z.exe",
                "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
            )
            $found = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($found) {
                 Write-ScriptLog "7-Zip installed at $found (not in PATH yet)." -Level Success
            } else {
                 throw "7-Zip not found after installation."
            }
        } else {
            throw "7-Zip command not found after installation."
        }
    }

} catch {
    Write-ScriptLog "7-Zip installation failed: $_" -Level Error
    exit 1
}
