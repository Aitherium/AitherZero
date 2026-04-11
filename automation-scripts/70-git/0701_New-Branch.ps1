#Requires -Version 7.0
<#
.SYNOPSIS
    Creates a new Git branch from the current or specified base branch.

.DESCRIPTION
    Creates and switches to a new branch following the AitherOS branch naming
    conventions (feature/*, fix/*, chore/*, etc.).

.PARAMETER Name
    Branch name. If it doesn't include a prefix (feature/, fix/, chore/),
    'feature/' will be prepended automatically.

.PARAMETER Base
    Base branch to create from. Defaults to 'develop'.

.PARAMETER NoSwitch
    Create the branch but don't switch to it.

.EXAMPLE
    .\0701_New-Branch.ps1 -Name "add-ring-tools"
    # Creates feature/add-ring-tools from develop

.EXAMPLE
    .\0701_New-Branch.ps1 -Name "fix/broken-sync" -Base main
    # Creates fix/broken-sync from main

.NOTES
    Category: git
    Script: 0701
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter()]
    [string]$Base = 'develop',

    [switch]$NoSwitch
)

$ErrorActionPreference = 'Stop'

# Auto-prefix if no convention prefix present
$prefixes = @('feature/', 'fix/', 'chore/', 'hotfix/', 'release/', 'experiment/')
$hasPrefix = $false
foreach ($p in $prefixes) {
    if ($Name.StartsWith($p)) { $hasPrefix = $true; break }
}
if (-not $hasPrefix) {
    $Name = "feature/$Name"
    Write-Host "  Auto-prefixed branch name: $Name" -ForegroundColor DarkGray
}

# Sanitize branch name
$Name = $Name -replace '[^a-zA-Z0-9/_-]', '-' -replace '-+', '-'

# Ensure we're on the base branch and up to date
Write-Host "  Creating branch '$Name' from '$Base'..." -ForegroundColor Cyan

git fetch origin $Base 2>&1 | Out-Null

if ($NoSwitch) {
    git branch $Name "origin/$Base" 2>&1
    Write-Host "  ✓ Branch '$Name' created (not switched)" -ForegroundColor Green
} else {
    git checkout -b $Name "origin/$Base" 2>&1
    Write-Host "  ✓ Switched to new branch '$Name'" -ForegroundColor Green
}

# Show current state
git log --oneline -3
