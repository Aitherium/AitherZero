<#
.SYNOPSIS
    Applies environment path configurations from config.psd1 permanently.

.DESCRIPTION
    Reads the path configurations from AitherZero's config.psd1 and applies them
    as permanent user environment variables. This ensures applications like Ollama,
    Docker, npm, pip, and HuggingFace store their data on the configured drive
    (default: D:\) instead of filling up the system drive.

.PARAMETER ShowOutput
    Display detailed output during execution.

.PARAMETER WhatIf
    Preview what would be applied without making changes.

.PARAMETER Force
    Override existing environment variables even if already set.

.EXAMPLE
    .\0015_Apply-EnvironmentPaths.ps1 -ShowOutput
    Applies all environment path configurations with output.

.EXAMPLE
    .\0015_Apply-EnvironmentPaths.ps1 -WhatIf
    Shows what would be applied without making changes.

.NOTES
    Script Number: 0015
    Category: Environment Setup
    Requires: PowerShell 7.0+
    
    IMPORTANT: After running this script, restart any running applications
    (Ollama, Docker, etc.) for the new paths to take effect.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$ShowOutput,
    [switch]$Force
)

# Initialize script environment
$scriptPath = $PSScriptRoot
$initPath = Join-Path $scriptPath "_init.ps1"
if (Test-Path $initPath) {
    . $initPath
}

function Write-Info {
    param([string]$Message)
    if ($ShowOutput) {
        Write-Host $Message -ForegroundColor Cyan
    }
}

function Write-Success {
    param([string]$Message)
    if ($ShowOutput) {
        Write-Host "✔ $Message" -ForegroundColor Green
    }
}

function Write-Change {
    param([string]$Message)
    if ($ShowOutput) {
        Write-Host "  â†’ $Message" -ForegroundColor Yellow
    }
}

# Load configuration
try {
    $config = Get-AitherConfigs -ErrorAction Stop
} catch {
    # Fallback to direct load if module not available
    $configPath = Join-Path $PSScriptRoot "..\..\config\config.psd1"
    $config = Import-PowerShellDataFile $configPath
}

Write-Info "═”═══════════════════════════════════════════════════════════════—"
Write-Info "═‘     AitherZero Environment Path Configuration                ═‘"
Write-Info "═š═══════════════════════════════════════════════════════════════"
Write-Info ""

# Get application environment variables from config
$appEnvVars = $config.EnvironmentConfiguration.EnvironmentVariables.Applications

if (-not $appEnvVars -or $appEnvVars.Count -eq 0) {
    Write-Warning "No application environment variables found in config"
    return
}

$applied = 0
$skipped = 0
$created = 0

foreach ($varName in $appEnvVars.Keys) {
    $varValue = $appEnvVars[$varName]
    
    if ([string]::IsNullOrWhiteSpace($varValue)) {
        continue
    }
    
    # Check current value
    $currentValue = [System.Environment]::GetEnvironmentVariable($varName, "User")
    
    if ($currentValue -eq $varValue) {
        Write-Info "  â—‹ $varName already set correctly"
        $skipped++
        continue
    }
    
    if ($currentValue -and -not $Force) {
        Write-Change "$varName exists with different value"
        Write-Info "    Current: $currentValue"
        Write-Info "    Config:  $varValue"
        Write-Info "    Use -Force to override"
        $skipped++
        continue
    }
    
    # Create the directory if it doesn't exist
    $dirPath = $varValue
    if ($dirPath -notmatch '^\d+$' -and $dirPath -notlike '*:*:*') {
        # It's a path, not a port or other value
        if (-not (Test-Path $dirPath)) {
            if ($PSCmdlet.ShouldProcess($dirPath, "Create directory")) {
                try {
                    New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
                    Write-Success "Created directory: $dirPath"
                    $created++
                } catch {
                    Write-Warning "Failed to create directory: $dirPath - $_"
                }
            }
        }
    }
    
    # Set the environment variable
    if ($PSCmdlet.ShouldProcess($varName, "Set environment variable to '$varValue'")) {
        try {
            [System.Environment]::SetEnvironmentVariable($varName, $varValue, "User")
            # Also set for current session
            [System.Environment]::SetEnvironmentVariable($varName, $varValue, "Process")
            Write-Success "$varName = $varValue"
            $applied++
        } catch {
            Write-Warning "Failed to set $varName : $_"
        }
    }
}

Write-Info ""
Write-Info "════════════════════════════════════════════════════════════════"
Write-Info "Summary:"
Write-Info "  Applied:  $applied environment variables"
Write-Info "  Skipped:  $skipped (already set or different)"
Write-Info "  Created:  $created directories"
Write-Info ""

if ($applied -gt 0) {
    Write-Host "âš  IMPORTANT: Restart any running applications for changes to take effect:" -ForegroundColor Yellow
    Write-Host "  - Ollama: Stop and restart 'ollama serve'" -ForegroundColor Gray
    Write-Host "  - Docker: Restart Docker Desktop" -ForegroundColor Gray
    Write-Host "  - Terminal: Open a new terminal window" -ForegroundColor Gray
}

# Return summary
[PSCustomObject]@{
    Applied = $applied
    Skipped = $skipped
    Created = $created
}

