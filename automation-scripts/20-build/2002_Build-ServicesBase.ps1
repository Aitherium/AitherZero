#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the Unified Base Image for AitherOS (Wrapper).

.DESCRIPTION
    This script is a wrapper around docker/scripts/Build-BaseImage.ps1.
    It builds the 'aitheros-base' Docker image which contains ALL Python dependencies.

.PARAMETER Push
    Push images to registry after build. Default: $false

.EXAMPLE
    .\2002_Build-ServicesBase.ps1 -Push

.NOTES
    Category: build
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [switch]$Push
)

$ErrorActionPreference = 'Stop'

# Get workspace root
$scriptDir = $PSScriptRoot
# Adjusting to reach root from AitherZero/library/automation-scripts/20-build/
$workspaceRoot = Resolve-Path "$scriptDir/../../../../"
$builderScript = Join-Path $workspaceRoot "docker/scripts/Build-BaseImage.ps1"

if (Test-Path $builderScript) {
    Write-Host "🚀 Delegating to primary builder: $builderScript" -ForegroundColor Cyan
    
    $params = @{}
    if ($Push) { $params['Push'] = $true }
    
    & $builderScript @params
} else {
    Write-Error "Could not find builder script at $builderScript"
}
