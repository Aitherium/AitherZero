<#
.SYNOPSIS
    Creates a GitHub Pull Request for the current branch.

.DESCRIPTION
    Uses the GitHub CLI (gh) to create a Pull Request.
    Requires 'gh' to be installed and authenticated.
    Automatically pushes the current branch to origin before creating the PR.

.PARAMETER Title
    The title of the Pull Request.

.PARAMETER Body
    The body/description of the Pull Request.

.PARAMETER Draft
    If set, creates the PR as a draft.

.EXAMPLE
    ./0703_Create-PullRequest.ps1 -Title "feat: add login" -Body "Implements login logic" --Draft

.NOTES
    Script Number: 0703
    Author: AitherZero
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Title,

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$Body,

    [Parameter(Mandatory = $false)]
    [switch]$Draft
)

try {
    # Check for GitHub CLI
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error "GitHub CLI (gh) is not installed. Please run script 0211_Install-GitHubCLI.ps1 first."
        exit 1
    }

    # Get current branch
    $currentBranch = git branch --show-current
    if (-not $currentBranch) {
        throw "Could not determine current git branch."
    }

    Write-Host "Pushing branch '$currentBranch' to origin..." -ForegroundColor Cyan
    git push -u origin $currentBranch

    # Build arguments
    $ghArgs = @("pr", "create", "--title", "$Title", "--body", "$Body")
    if ($Draft) {
        $ghArgs += "--draft"
    }

    Write-Host "Creating Pull Request..." -ForegroundColor Green
    # Using Start-Process or direct execution depending on env, here direct
    gh @ghArgs

    Write-Host "PR Creation process completed." -ForegroundColor Green
}
catch {
    Write-Error "Failed to create Pull Request: $_"
    exit 1
}
