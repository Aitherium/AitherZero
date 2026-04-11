#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys the generated dashboard to the gh-pages branch.
.DESCRIPTION
    Handles the git operations to update the branch-specific folder in gh-pages.
    Ensures the root index.html links to the new branch.
.PARAMETER BranchName
    The name of the branch being deployed (e.g., 'dev').
.PARAMETER SourceDir
    The directory containing the generated dashboard (e.g., './public').
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BranchName,

    [Parameter(Mandatory)]
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'

# Configure git
git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"

# Create a temporary directory for the pages branch
$pagesDir = Join-Path $env:RUNNER_TEMP "gh-pages"
if (Test-Path $pagesDir) { Remove-Item $pagesDir -Recurse -Force }

Write-Host "Fetching gh-pages branch..." -ForegroundColor Cyan
# Clone only the gh-pages branch
git clone --branch gh-pages --single-branch "https://x-access-token:$env:GITHUB_TOKEN@github.com/$env:GITHUB_REPOSITORY.git" $pagesDir

if (-not (Test-Path $pagesDir)) {
    # If branch doesn't exist, create it (orphan)
    Write-Host "gh-pages branch not found. Creating orphan branch..." -ForegroundColor Yellow
    New-Item -Path $pagesDir -ItemType Directory -Force | Out-Null
    Set-Location $pagesDir
    git init
    git checkout --orphan gh-pages
} else {
    Set-Location $pagesDir
}

# Create/Update branch directory
$targetDir = Join-Path $pagesDir $BranchName
if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force }
New-Item -Path $targetDir -ItemType Directory -Force | Out-Null

# Copy content
Write-Host "Copying dashboard content to $targetDir..." -ForegroundColor Cyan
Copy-Item "$SourceDir/*" $targetDir -Recurse -Force

# Update Root Index (Landing Page)
$indexFile = Join-Path $pagesDir "index.html"
$indexContent = if (Test-Path $indexFile) { Get-Content $indexFile -Raw } else {
@"
<!DOCTYPE html>
<html>
<head>
    <title>AitherZero Dashboards</title>
    <style>
        body { font-family: system-ui, sans-serif; padding: 2rem; max-width: 800px; margin: 0 auto; }
        .branch-link { display: block; padding: 1rem; margin: 0.5rem 0; background: #f8f9fa; border: 1px solid #dee2e6; text-decoration: none; color: #212529; border-radius: 4px; }
        .branch-link:hover { background: #e9ecef; }
    </style>
</head>
<body>
    <h1>AitherZero Dashboards</h1>
    <div id="links"></div>
</body>
</html>
"@
}

# Simple check if link exists (naive but functional for now)
if ($indexContent -notmatch "href=['`"]$BranchName/index.html['`"]") {
    $linkHtml = "<a class='branch-link' href='$BranchName/index.html'>$BranchName</a>"
    $indexContent = $indexContent.Replace('<div id="links">', "<div id=`"links`">$linkHtml")
    $indexContent | Set-Content $indexFile
}

# Commit and Push
git add .
if ((git status --porcelain) -ne "") {
    git commit -m "Deploy dashboard for branch $BranchName"
    git push origin gh-pages
    Write-Host "✅ Successfully deployed to gh-pages" -ForegroundColor Green
} else {
    Write-Host "No changes to deploy" -ForegroundColor Yellow
}
