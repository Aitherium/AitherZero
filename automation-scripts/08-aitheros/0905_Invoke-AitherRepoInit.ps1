<#
.SYNOPSIS
    Scaffolds a new project repository and pushes it to GitHub, ready for AitherOS integration.

.DESCRIPTION
    This script automates the full lifecycle of project creation:
    1. Validates inputs and environment
    2. Uses GitHub CLI to create the remote repository
    3. Clones the repository to AitherZero workspaces directory
    4. Scaffolds a basic template project structure (README, ROADMAP, docs)
    5. Performs initial git commit and push
    6. Emits standardized JSON output for AitherFlow integration

.PARAMETER RepoName
    The name of the new repository (e.g. 'project-phoenix')

.PARAMETER Description
    A short description of the project

.PARAMETER Organization
    Optional target GitHub organization. Defaults to the authenticated user.

.PARAMETER Visibility
    Public or Private (default: private)

.PARAMETER WorkspaceContext
    Optional. If true, initializes specific AitherWorkspace metadata.

.EXAMPLE
    .\0905_Invoke-AitherRepoInit.ps1 -RepoName "my-new-service" -Description "A test AI service"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$RepoName,

    [Parameter(Mandatory=$false)]
    [string]$Description = "AitherOS managed project",

    [Parameter(Mandatory=$false)]
    [string]$Organization = "",

    [Parameter(Mandatory=$false)]
    [ValidateSet("public", "private", "internal")]
    [string]$Visibility = "private",

    [Parameter(Mandatory=$false)]
    [switch]$WorkspaceContext
)

$ErrorActionPreference = "Stop"

# Constants
$WORKSPACE_ROOT = $env:AITHER_WORKSPACE_ROOT
if ([string]::IsNullOrEmpty($WORKSPACE_ROOT)) {
    # Fallback to local data dir for standalone execution
    $WORKSPACE_ROOT = "$PSScriptRoot\..\..\..\AitherOS\runtime\data\workspaces"
}

# Resolve target path
$RepoPath = if ($Organization) { "$Organization/$RepoName" } else { $RepoName }
$LocalPath = Join-Path $WORKSPACE_ROOT $RepoName

Write-Verbose "=== AitherProject Initialization ==="
Write-Verbose "Target Repo : $RepoPath"
Write-Verbose "Local Path  : $LocalPath"
Write-Verbose "Visibility  : $Visibility"

try {
    # 1. Validation
    if (!(Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found in PATH. Required for repo creation."
    }

    if (Test-Path $LocalPath) {
        throw "Workspace path already exists: $LocalPath"
    }

    # Ensure workspace root exists
    if (!(Test-Path $WORKSPACE_ROOT)) {
        New-Item -ItemType Directory -Path $WORKSPACE_ROOT -Force | Out-Null
    }

    # 2. Create Remote Repository
    Write-Verbose "Creating remote repository via GitHub CLI..."
    $ghArgs = @("repo", "create", $RepoPath, "--$Visibility", "--description", "`"$Description`"")
    
    # Store stderr heavily but let it throw if error code occurs
    $null = & gh $ghArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create remote repository."
    }

    # 3. Clone Repository
    Write-Verbose "Cloning repository..."
    Push-Location $WORKSPACE_ROOT
    try {
        & gh repo clone $RepoPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone new repository."
        }
    }
    finally {
        Pop-Location
    }

    # 4. Scaffold Basic Template
    Write-Verbose "Scaffolding baseline architecture..."
    Push-Location $LocalPath
    try {
        # Directories
        New-Item -ItemType Directory -Path "docs" | Out-Null
        New-Item -ItemType Directory -Path "src" | Out-Null
        New-Item -ItemType Directory -Path "tests" | Out-Null

        # .gitignore
        @"
node_modules/
dist/
build/
.env
.venv/
__pycache__/
*.pyc
logs/
data/
.DS_Store
"@ | Out-File -FilePath ".gitignore" -Encoding utf8

        # README.md
        $year = (Get-Date).Year
        @"
# $RepoName

$Description

Created automatically by AitherFlow Project Onboarding.

## Overview
This repository is managed within the AitherOS ecosystem workspace.

## License
MIT License (c) $year
"@ | Out-File -FilePath "README.md" -Encoding utf8

        # ROADMAP.md
        @"
# Project Roadmap

**Last Updated:** $(Get-Date -Format 'yyyy-MM-dd')

## Current Sprint
| ID | Task | Status | Assignee |
|----|------|--------|----------|
| P1 | Initial Project Scaffold | [OK] Done | AitherFlow |

## Backlog
| ID | Task | Status | Assignee |
|----|------|--------|----------|
| B1 | Design architecture spec | [COPY] Planned | - |
"@ | Out-File -FilePath "ROADMAP.md" -Encoding utf8

        if ($WorkspaceContext) {
            # Write AitherOS connection metadata
            $meta = @{
                managed_by = "AitherFlow"
                created_at = (Get-Date -IfFormat "yyyy-MM-ddTHH:mm:ssZ")
                scaffold_version = "1.0"
            }
            $meta | ConvertTo-Json | Out-File -FilePath ".aither-workspace.json" -Encoding utf8
        }

        # 5. Initial Commit & Push
        Write-Verbose "Committing and pushing scaffolding..."
        & git add .
        & git commit -m "chore: initial project baseline via AitherFlow"
        & git push -u origin HEAD

        $originUrl = (& git config --get remote.origin.url).Trim()

        # Build output payload
        $result = @{
            success     = $true
            repo_name   = $RepoName
            remote_url  = $originUrl
            local_path  = $LocalPath
            visibility  = $Visibility
            message     = "Project successfully scaffolded and pushed."
        }

        # JSON output for Python caller
        $result | ConvertTo-Json -Compress
    }
    finally {
        Pop-Location
    }

}
catch {
    $errorObj = @{
        success = $false
        error   = $_.Exception.Message
        step    = "Project Onboarding"
    }
    Write-Error $_.Exception.Message
    $errorObj | ConvertTo-Json -Compress
    exit 1
}
exit 0
