#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Direct playbook loader - workaround for Get-AitherPlaybook hanging issue
.DESCRIPTION
    Loads a playbook directly from file without using Get-AitherPlaybook.
    This is a temporary workaround until the Get-AitherPlaybook hanging issue is resolved.
.PARAMETER Name
    Name of the playbook to load
.EXAMPLE
    $playbook = & ./library/playbooks/_utilities/load-playbook-direct.ps1 -Name ci-pr-validation
#>

param(
    [Parameter(Mandatory)]
    [string]$Name
)

$projectRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$playbookPath = Join-Path $projectRoot "library/playbooks/$Name.psd1"

if (-not (Test-Path $playbookPath)) {
    throw "Playbook not found: $playbookPath"
}

# Load the playbook using script block evaluation (same as Import-ConfigDataFile)
$content = Get-Content -Path $playbookPath -Raw
$scriptBlock = [scriptblock]::Create($content)
& $scriptBlock
