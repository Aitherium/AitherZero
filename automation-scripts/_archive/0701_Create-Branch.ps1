<#
.SYNOPSIS
    Creates a new git branch with standardized naming convention.

.DESCRIPTION
    Creates a new git branch based on the provided type and name.
    Enforces conventional branch naming: type/name (e.g., feature/add-login, bugfix/fix-header).
    Checks if the branch already exists and switches to it if it does.

.PARAMETER Type
    The type of branch. Options: feature, bugfix, hotfix, release, chore, docs, test, refactor.
    Default: feature

.PARAMETER Name
    The descriptive name of the branch (kebab-case recommended).

.EXAMPLE
    ./0701_Create-Branch.ps1 -Type feature -Name "add-login-page"
    Creates and switches to 'feature/add-login-page'.

.NOTES
    Script Number: 0701
    Author: AitherZero
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('feature', 'bugfix', 'hotfix', 'release', 'chore', 'docs', 'test', 'refactor')]
    [string]$Type = 'feature',

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Name
)

try {
    # Sanitize name: replace spaces with hyphens, remove special chars
    $sanitizedName = $Name -replace '\s+', '-' -replace '[^a-zA-Z0-9\-_]', ''
    $branchName = "$Type/$sanitizedName"

    Write-Host "Preparing to manage branch: $branchName" -ForegroundColor Cyan

    # Check if branch exists locally
    $branchExists = git branch --list $branchName
    
    if ($branchExists) {
        Write-Host "Branch '$branchName' already exists. Switching to it..." -ForegroundColor Yellow
        git checkout $branchName
    }
    else {
        Write-Host "Creating new branch '$branchName'..." -ForegroundColor Green
        git checkout -b $branchName
    }

    # Show status
    Write-Host "Current Branch Status:" -ForegroundColor Cyan
    git status -s
}
catch {
    Write-Error "Failed to create/switch branch: $_"
    exit 1
}
