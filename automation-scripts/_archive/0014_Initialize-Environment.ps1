#Requires -Version 7.0
<#
.SYNOPSIS
    Initialize AitherZero environment on workspace open.

.DESCRIPTION
    This script is run automatically when the workspace opens to:
    - Set AITHERZERO_ROOT environment variable
    - Import the AitherZero module
    - Load API keys from secrets

.EXAMPLE
    ./0014_Initialize-Environment.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# Determine root path
if ($env:AITHERZERO_ROOT) {
    $rootPath = $env:AITHERZERO_ROOT
} else {
    $rootPath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $env:AITHERZERO_ROOT = $rootPath
}

$modulePath = Join-Path $rootPath 'AitherZero/AitherZero.psd1'

if (Test-Path $modulePath) {
    try {
        Import-Module $modulePath -Force -ErrorAction Stop
        Write-Host "`u{2705} AitherZero module loaded" -ForegroundColor Green
        
        # Try to load secrets if the function exists
        if (Get-Command Initialize-AitherSecrets -ErrorAction SilentlyContinue) {
            $result = Initialize-AitherSecrets -ErrorAction SilentlyContinue
            if ($result -and $result.Loaded -and $result.Loaded.Count -gt 0) {
                Write-Host "`u{1F511} Loaded $($result.Loaded.Count) API keys into environment" -ForegroundColor Cyan
            }
        }
    } catch {
        Write-Host "`u{26A0}`u{FE0F} Module import failed - run Bootstrap task" -ForegroundColor Yellow
        Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "`u{26A0}`u{FE0F} AitherZero module not found - run Bootstrap task first" -ForegroundColor Yellow
    Write-Host "   Expected path: $modulePath" -ForegroundColor DarkYellow
}
