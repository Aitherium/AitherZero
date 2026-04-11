#Requires -Version 7.0
# Stage: Development
# Dependencies: Python
# Description: Sets up a Python virtual environment and installs dependencies
# Tags: python, venv, dependencies

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)]
    [string]$Path,
    
    [Parameter()]
    [string]$Requirements = "requirements.txt"
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_init.ps1"
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '0752_Setup-AgentVenv'
    } else {
        Write-Host "[$Level] $Message"
    }
}

# Resolve Path
if (Test-Path $Path) {
    $targetPath = Resolve-Path $Path
} elseif ($env:AITHERZERO_ROOT -and (Test-Path (Join-Path $env:AITHERZERO_ROOT $Path))) {
    $targetPath = Join-Path $env:AITHERZERO_ROOT $Path
} else {
    throw "Target path does not exist: $Path (Checked relative to '$PWD' and '$env:AITHERZERO_ROOT')"
}

$venvPath = Join-Path $targetPath ".venv"
$reqPath = Join-Path $targetPath $Requirements

Write-ScriptLog "Setting up Python environment in $targetPath..."

try {
    # 1. Create Virtual Environment
    if (-not (Test-Path $venvPath)) {
        Write-ScriptLog "Creating virtual environment at $venvPath..."
        if ($PSCmdlet.ShouldProcess($venvPath, "Create Python Venv")) {
            $pythonCmd = if ($IsWindows) { "python" } else { "python3" }
            
            $proc = Start-Process -FilePath $pythonCmd -ArgumentList "-m", "venv", ".venv" -WorkingDirectory $targetPath -PassThru -NoNewWindow -Wait
            
            if ($proc.ExitCode -ne 0) {
                throw "Failed to create venv. Exit code: $($proc.ExitCode)"
            }
            Write-ScriptLog "Virtual environment created." -Level Success
        }
    } else {
        Write-ScriptLog "Virtual environment already exists."
    }

    # 2. Install Requirements
    if (Test-Path $reqPath) {
        Write-ScriptLog "Installing dependencies from $Requirements..."
        
        if ($PSCmdlet.ShouldProcess($reqPath, "Install Dependencies")) {
            # Determine pip path
            if ($IsWindows) {
                $pipPath = Join-Path $venvPath "Scripts" "pip.exe"
            } else {
                $pipPath = Join-Path $venvPath "bin/pip"
            }
            
            if (-not (Test-Path $pipPath)) {
                throw "Pip not found at $pipPath. Venv creation might have failed."
            }

            $proc = Start-Process -FilePath $pipPath -ArgumentList "install", "-r", $Requirements -WorkingDirectory $targetPath -PassThru -NoNewWindow -Wait
            
            if ($proc.ExitCode -ne 0) {
                throw "Failed to install dependencies. Exit code: $($proc.ExitCode)"
            }
            Write-ScriptLog "Dependencies installed successfully." -Level Success
        }
    } else {
        Write-ScriptLog "No $Requirements file found. Skipping dependency installation." -Level Warning
    }

} catch {
    Write-ScriptLog "Failed to setup python environment: $_" -Level Error
    exit 1
}
