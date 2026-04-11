#Requires -Version 7.0

<#
.SYNOPSIS
    Example plugin script — deploy the project.
.DESCRIPTION
    This is a template script showing the pattern for plugin automation scripts.
    Replace with your actual deployment logic.
.NOTES
    Category: Deploy
    Plugin: my-plugin
#>

[CmdletBinding()]
param(
    [ValidateSet('development', 'staging', 'production')]
    [string]$Environment = 'development',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Import module init (resolves from the main automation-scripts/_init.ps1)
. (Join-Path $PSScriptRoot '../../library/automation-scripts/_init.ps1')

Write-ScriptLog "Deploying to $Environment..." -Level Info

$config = Get-AitherConfigs
$projectName = $config.ProjectContext.Name

if ($DryRun) {
    Write-ScriptLog "[DRY RUN] Would deploy $projectName to $Environment" -Level Info
    return
}

# Your deployment logic here
# Example: Invoke-AitherCompose -Action up -Detached

Write-ScriptLog "Deployment of $projectName to $Environment complete." -Level Info
