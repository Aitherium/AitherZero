<#
.SYNOPSIS
    Synchronizes AitherZero with the public open-source repository.

.DESCRIPTION
    Bidirectional sync between the monorepo's AitherZero/ directory and the
    public Aitherium/AitherZero GitHub repository.

    Push mode: Copies public-safe files to a staging directory, commits, and pushes.
    Pull mode: Pulls upstream changes from the public repo into the monorepo.

    Files excluded from push (defined in .gitignore):
    - plugins/aitheros/, plugins/adk/ (private plugins)
    - config/aitheros.psd1, config/partner-config.psd1, config/config.local.psd1
    - AitherZero.psm1, AitherZero.psd1 (build artifacts)
    - library/automation-scripts/08-aitheros/, 20-build/, 30-deploy/, 40-lifecycle/

.PARAMETER Direction
    'push' to push monorepo changes to public repo.
    'pull' to pull public repo changes into monorepo.

.PARAMETER DryRun
    Show what would be done without making changes.

.PARAMETER Message
    Custom commit message for push operations.

.EXAMPLE
    .\7010_Sync-OpenSource.ps1 -Direction push -Message "feat: add new playbook engine"

.EXAMPLE
    .\7010_Sync-OpenSource.ps1 -Direction pull
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('push', 'pull')]
    [string]$Direction,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$Message
)

$ErrorActionPreference = 'Stop'
$AitherZeroRoot = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
$MonoRoot = Split-Path $AitherZeroRoot -Parent
$PublicRemote = 'aitherzero-public'
$PublicRepo = 'https://github.com/Aitherium/AitherZero.git'

# Excluded patterns (from .gitignore + additional private content)
$ExcludePatterns = @(
    'bin/'
    'AitherZero.psm1'
    'AitherZero.psd1'
    'library/logs/'
    'logs/'
    'plugins/aitheros/'
    'plugins/adk/'
    'config/aitheros.psd1'
    'config/partner-config.psd1'
    'config/config.local.psd1'
    'config/projects.json'
    'config/narrative_agent.yaml'
    'config/services.psd1'
    'src/public/WindowsIntegration.psm1'
    'library/automation-scripts/00-bootstrap/'
    'library/automation-scripts/01-infrastructure/'
    'library/automation-scripts/08-aitheros/'
    'library/automation-scripts/20-build/'
    'library/automation-scripts/30-deploy/'
    'library/automation-scripts/31-remote/'
    'library/automation-scripts/40-lifecycle/'
    'library/automation-scripts/50-ai-setup/'
    'library/automation-scripts/60-security/'
    'library/automation-scripts/_archive/'
    '0908_Switch-GpuProfile.ps1'
    '0806_AitherOS-Lifecycle.ps1'
    'Plan Spec'
    'library/reports/'
    'training-data/'
    'OPEN_SOURCE_PLAN.md'
    '.terraform/'
    'node_modules/'
    '.next/'
    '.vscode/'
)

function Test-Excluded {
    param([string]$RelativePath)
    foreach ($pattern in $ExcludePatterns) {
        $normalized = $RelativePath -replace '\\', '/'
        if ($normalized -like "*$pattern*" -or $normalized.StartsWith($pattern)) {
            return $true
        }
    }
    return $false
}

# Ensure remote exists
Push-Location $MonoRoot
try {
    $remotes = git remote
    if ($PublicRemote -notin $remotes) {
        Write-Host "Adding remote '$PublicRemote'..."
        git remote add $PublicRemote $PublicRepo
    }
} finally {
    Pop-Location
}

if ($Direction -eq 'push') {
    Write-Host "=== Pushing to public repo ===" -ForegroundColor Cyan

    # Create temp staging directory
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "aitherzero-sync-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    try {
        # Clone existing public repo
        Write-Host "Cloning public repo..."
        git clone --depth 1 $PublicRepo $staging 2>&1 | Write-Verbose

        # Remove all tracked files (except .git)
        Get-ChildItem -Path $staging -Force | Where-Object { $_.Name -ne '.git' } | Remove-Item -Recurse -Force

        # Copy filtered files
        Write-Host "Copying filtered files..."
        $sourceFiles = Get-ChildItem -Path $AitherZeroRoot -Recurse -File -Force |
            Where-Object { $_.FullName -notlike '*\.git\*' }

        $copied = 0
        $skipped = 0
        foreach ($file in $sourceFiles) {
            $relativePath = $file.FullName.Substring($AitherZeroRoot.Length + 1)
            if (Test-Excluded $relativePath) {
                $skipped++
                continue
            }

            $destPath = Join-Path $staging $relativePath
            $destDir = Split-Path $destPath -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item $file.FullName $destPath -Force
            $copied++
        }

        # NOTE: We used to override README.md with README_OPENSOURCE.md here.
        # As of 2026-04, the root README.md is the canonical public-facing README.
        # README_OPENSOURCE.md is kept for reference but is no longer preferred.

        # NOTE: We used to override README.md with README_OPENSOURCE.md here.
        # As of 2026-04, the root README.md is the canonical public-facing README.
        # README_OPENSOURCE.md is kept for reference but is no longer preferred.

        Write-Host "Copied $copied files, skipped $skipped excluded files"

        if ($DryRun) {
            Write-Host "[DRY RUN] Would commit and push to $PublicRepo" -ForegroundColor Yellow
            Push-Location $staging
            git add -A
            git status --short
            Pop-Location
            return
        }

        # Commit and push
        Push-Location $staging
        git add -A

        $changes = git status --porcelain
        if (-not $changes) {
            Write-Host "No changes to push." -ForegroundColor Green
            Pop-Location
            return
        }

        # Ensure git identity is set in the temp clone (inherits from monorepo config or global)
        $monoName = git -C $PSScriptRoot/../../../.. config user.name 2>$null
        $monoEmail = git -C $PSScriptRoot/../../../.. config user.email 2>$null
        if ($monoName) { git config user.name $monoName }
        if ($monoEmail) { git config user.email $monoEmail }

        $commitMsg = if ($Message) { $Message } else { "sync: update from monorepo $(Get-Date -Format 'yyyy-MM-dd')" }
        git commit -m $commitMsg
        git push origin main

        Write-Host "Pushed to $PublicRepo" -ForegroundColor Green
        Pop-Location

    } finally {
        if (Test-Path $staging) {
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
elseif ($Direction -eq 'pull') {
    Write-Host "=== Pulling from public repo ===" -ForegroundColor Cyan

    Push-Location $MonoRoot
    try {
        Write-Host "Fetching from $PublicRemote..."
        git fetch $PublicRemote main

        if ($DryRun) {
            Write-Host "[DRY RUN] Would merge changes from $PublicRemote/main" -ForegroundColor Yellow
            git log HEAD..$PublicRemote/main --oneline 2>$null
            return
        }

        # Use subtree merge strategy for the AitherZero/ prefix
        git subtree pull --prefix=AitherZero $PublicRemote main --squash -m "sync: pull upstream changes from public AitherZero"

        Write-Host "Pulled upstream changes." -ForegroundColor Green
    } catch {
        Write-Warning "Subtree pull failed. You may need to resolve conflicts manually."
        Write-Warning "Error: $_"
    } finally {
        Pop-Location
    }
}
