<#
.SYNOPSIS
    Commits staged changes with a Conventional Commits message.

.DESCRIPTION
    Wraps 'git commit' to enforce the Conventional Commits specification.
    Constructs the message as: type(scope): description
    Automatically stages all tracked files if requested.

.PARAMETER Type
    The type of change. Options: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.

.PARAMETER Scope
    Optional scope of the change (e.g., auth, ui, api).

.PARAMETER Message
    The short description of the change.

.PARAMETER StageAll
    If set, runs 'git add .' before committing.

.EXAMPLE
    ./0702_Commit-Changes.ps1 -Type feat -Scope "auth" -Message "implement login" -StageAll
    Commits with message: "feat(auth): implement login"

.NOTES
    Script Number: 0702
    Author: AitherZero
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('feat', 'fix', 'docs', 'style', 'refactor', 'perf', 'test', 'build', 'ci', 'chore', 'revert')]
    [string]$Type,

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$Scope,

    [Parameter(Mandatory = $true, Position = 2)]
    [string]$Message,

    [Parameter(Mandatory = $false)]
    [switch]$StageAll
)

try {
    if ($StageAll) {
        Write-Host "Staging all changes..." -ForegroundColor Cyan
        git add .
    }

    # Check if there are staged changes
    $status = git diff --cached --name-only
    if (-not $status) {
        Write-Warning "No changes staged for commit. Use -StageAll to stage all changes."
        exit 0
    }

    # Construct commit message
    $commitMsg = "$Type"
    if (-not [string]::IsNullOrWhiteSpace($Scope)) {
        $commitMsg += "($Scope)"
    }
    $commitMsg += ": $Message"

    Write-Host "Committing with message: '$commitMsg'" -ForegroundColor Green
    
    git commit -m "$commitMsg"

    Write-Host "Commit successful." -ForegroundColor Green
    git log -1 --oneline
}
catch {
    Write-Error "Commit failed: $_"
    exit 1
}
