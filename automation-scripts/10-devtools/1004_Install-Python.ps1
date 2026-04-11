#Requires -Version 7.0
# Stage: Development
# Dependencies: PackageManager
# Description: Install Python programming language using package managers (winget priority)
# Tags: development, python, programming

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [hashtable]$Configuration
)

. "$PSScriptRoot/_init.ps1"

if (-not $Configuration) {
    $Configuration = Get-AitherConfigs -ErrorAction SilentlyContinue
}

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0206_Install-Python'
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

Write-ScriptLog "Starting Python installation..."

try {
    # 1. Check Configuration
    Ensure-FeatureEnabled -Section "Features" -Key "Development.Python" -Name "Python"

    # Reload config
    $Configuration = Get-AitherConfigs
    $pythonConfig = $Configuration.Features.Development.Python

    # 2. Install Python
    if ($PSCmdlet.ShouldProcess("System", "Install Python")) {
        Install-AitherPackage -Name "python" -WingetId "Python.Python.3.12" -ChocoId "python" -BrewName "python@3.12" -AptName "python3" -YumName "python3"

        # Ensure venv support on Linux (often separate package)
        if ($IsLinux -and (Get-Command apt-get -ErrorAction SilentlyContinue)) {
            Write-ScriptLog "Installing python3-venv for virtual environment support..."
            Install-AitherPackage -Name "python3-venv" -AptName "python3-venv"
        }
    }

    # 3. Verify Installation & Configure
    $pythonCmd = if ($IsWindows) { 'python' } else { 'python3' }

    if (Get-Command $pythonCmd -ErrorAction SilentlyContinue) {
        $v = & $pythonCmd --version
        Write-ScriptLog "Python installed: $v" -Level Success

        # Verify pip
        if (Get-Command pip -ErrorAction SilentlyContinue) {
            $pv = pip --version
            Write-ScriptLog "Pip available: $pv"
        }
        elseif (Get-Command pip3 -ErrorAction SilentlyContinue) {
            $pv = pip3 --version
            Write-ScriptLog "Pip3 available: $pv"
        }

        # Install Python Packages if configured
        if ($pythonConfig -and $pythonConfig.Packages) {
            foreach ($pkg in $pythonConfig.Packages) {
                Write-ScriptLog "Installing Python package: $pkg"
                if ($PSCmdlet.ShouldProcess("Pip", "Install $pkg")) {
                    try {
                        if ($IsWindows) { pip install $pkg } else { pip3 install $pkg }
                    }
                    catch {
                        Write-ScriptLog "Failed to install package ${pkg}: $_" -Level Warning
                    }
                }
            }
        }

        # Upgrade pip
        if ($pythonConfig -and $pythonConfig.UpgradePip) {
            Write-ScriptLog "Upgrading pip..."
            if ($IsWindows) { pip install --upgrade pip } else { pip3 install --upgrade pip }
        }

    }
    else {
        throw "Python command not found after installation."
    }

}
catch {
    Write-ScriptLog "Python installation failed: $_" -Level Error
    exit 1
}
