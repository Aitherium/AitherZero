#Requires -Version 7.0
<#
.SYNOPSIS
    Commits and pushes changes to ALL repositories in a single operation.

.DESCRIPTION
    Master orchestrator for multi-repo synchronization:
    1. Commits all pending changes in the monorepo
    2. Pushes to origin (AitherOS private)
    3. Syncs AitherZero subtree to the public Aitherium/AitherZero repo
    4. Optionally syncs to AitherOS-Alpha public repo
    5. Records sync event to deployment history

    This is the script that Atlas/Demiurge agents should call when they
    need to push updates to all repositories.

.PARAMETER Message
    Commit message. Auto-generates from changes if omitted.

.PARAMETER SyncPublic
    Also sync to public repos (AitherZero, AitherOS-Alpha). Default: true

.PARAMETER AitherZeroOnly
    Only sync to the AitherZero public repo (skip Alpha).

.PARAMETER DryRun
    Show what would happen without executing.

.PARAMETER Force
    Force-push subtrees if they've diverged.

.PARAMETER SkipCommit
    Skip the commit step (only push/sync existing commits).

.PARAMETER Branch
    Branch to push. Default: current branch.

.EXAMPLE
    .\7011_Sync-AllRepos.ps1 -Message "feat: new deployment tools"
    # Commit, push to origin, sync AitherZero + Alpha public repos

.EXAMPLE
    .\7011_Sync-AllRepos.ps1 -SkipCommit -AitherZeroOnly
    # Just sync AitherZero subtree to public (no new commit)

.EXAMPLE
    .\7011_Sync-AllRepos.ps1 -DryRun
    # Show what would be pushed everywhere

.NOTES
    Category: git
    Script: 7011
    Used by: MCP repo_sync tool, Atlas agent, deploy playbooks
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$Message,

    [Parameter()]
    [switch]$SyncPublic = $true,

    [switch]$AitherZeroOnly,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SkipCommit,

    [string]$Branch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ═══════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════

$MonoRoot = Split-Path $PSScriptRoot -Parent | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent
$LogFile = Join-Path $MonoRoot "AitherZero/library/logs/repo-sync.jsonl"

$Repos = @{
    Origin = @{
        Remote = 'origin'
        Url    = 'https://github.com/Aitherium/AitherOS.git'
        Type   = 'direct'     # Direct push
    }
    AitherZero = @{
        Remote    = 'aitherzero-public'
        Url       = 'https://github.com/Aitherium/AitherZero.git'
        Type      = 'subtree'   # Subtree push with filtered content
        Prefix    = 'AitherZero'
        TargetRef = 'main'
    }
    Alpha = @{
        Remote    = 'alpha-public'
        Url       = 'https://github.com/Aitherium/AitherOS-Alpha.git'
        Type      = 'curated'   # Curated file copy (via workflow)
        TargetRef = 'main'
    }
}

# ═══════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════

function Write-SyncLog {
    param([string]$Repo, [string]$Action, [string]$Status, [string]$Detail)
    $entry = @{
        timestamp = (Get-Date -Format 'o')
        repo      = $Repo
        action    = $Action
        status    = $Status
        detail    = $Detail
        branch    = $Branch
        commit    = (git rev-parse --short HEAD 2>$null)
        user      = $env:USERNAME ?? $env:USER ?? 'agent'
    } | ConvertTo-Json -Compress

    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $entry | Add-Content -Path $LogFile -Encoding UTF8
}

function Ensure-Remote {
    param([string]$Name, [string]$Url)
    $existing = git remote 2>$null
    if ($Name -notin $existing) {
        Write-Host "  Adding remote '$Name'..." -ForegroundColor DarkGray
        git remote add $Name $Url 2>&1 | Out-Null
    }
}

function Get-ChangeSummary {
    $changes = git diff --cached --stat --no-color 2>$null
    if (-not $changes) { $changes = git diff --stat --no-color 2>$null }
    $fileCount = (git status --porcelain 2>$null).Count
    return "($fileCount files changed)"
}

# ═══════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           AITHEROS MULTI-REPO SYNC                      ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Push-Location $MonoRoot

try {
    # Get current branch
    if (-not $Branch) {
        $Branch = git symbolic-ref --short HEAD 2>$null
        if (-not $Branch) { $Branch = 'develop' }
    }
    Write-Host "  Branch: $Branch" -ForegroundColor White

    $results = @{}

    # ═══════════════════════════════════════════════════════════
    # STEP 1: COMMIT (if not skipping)
    # ═══════════════════════════════════════════════════════════

    if (-not $SkipCommit) {
        Write-Host ""
        Write-Host "  ━━━ Step 1: Commit ━━━" -ForegroundColor Yellow

        $pendingChanges = git status --porcelain 2>$null
        if ($pendingChanges) {
            $fileCount = ($pendingChanges).Count
            Write-Host "  $fileCount file(s) with changes" -ForegroundColor Gray

            # Check for secrets in staged content
            git add -A 2>&1 | Out-Null
            $secretsCheck = git diff --cached --diff-filter=A -S 'DISCORD_BOT_TOKEN\|sk-\|ghp_\|gho_' --name-only 2>$null
            if ($secretsCheck) {
                Write-Host "  ⚠ Potential secrets detected in:" -ForegroundColor Red
                $secretsCheck | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                if (-not $Force) {
                    Write-Host "  Aborting. Use -Force to override." -ForegroundColor Red
                    $results['Commit'] = 'BLOCKED (secrets detected)'
                    return
                }
            }

            # Auto-generate message if not provided
            if (-not $Message) {
                $types = @()
                $pendingChanges | ForEach-Object {
                    $path = $_.Substring(3).Trim()
                    if ($path -like 'AitherOS/*') { $types += 'services' }
                    elseif ($path -like 'AitherZero/*') { $types += 'automation' }
                    elseif ($path -like '.github/*') { $types += 'ci' }
                    elseif ($path -like '*.yml' -or $path -like '*.yaml') { $types += 'config' }
                    else { $types += 'chore' }
                }
                $uniqueTypes = $types | Select-Object -Unique
                $scope = ($uniqueTypes | Select-Object -First 3) -join ', '
                $Message = "chore($scope): sync updates ($fileCount files)"
            }

            if ($DryRun) {
                Write-Host "  [DRY RUN] Would commit: $Message" -ForegroundColor Yellow
                git status --short | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                $results['Commit'] = 'DRY RUN'
            } else {
                git commit -m $Message 2>&1 | Out-Null
                $commitHash = git rev-parse --short HEAD
                Write-Host "  ✓ Committed: $commitHash" -ForegroundColor Green
                Write-Host "    $Message" -ForegroundColor DarkGray
                Write-SyncLog -Repo 'monorepo' -Action 'commit' -Status 'success' -Detail $Message
                $results['Commit'] = "✓ $commitHash"
            }
        } else {
            Write-Host "  ℹ No pending changes" -ForegroundColor DarkGray
            $results['Commit'] = 'nothing to commit'
        }
    }

    # ═══════════════════════════════════════════════════════════
    # STEP 2: PUSH TO ORIGIN (AitherOS private)
    # ═══════════════════════════════════════════════════════════

    Write-Host ""
    Write-Host "  ━━━ Step 2: Push to origin (AitherOS) ━━━" -ForegroundColor Yellow

    Ensure-Remote 'origin' $Repos.Origin.Url

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would push to origin/$Branch" -ForegroundColor Yellow
        $ahead = git rev-list "origin/$Branch..$Branch" --count 2>$null
        Write-Host "  $ahead commit(s) ahead" -ForegroundColor DarkGray
        $results['Origin'] = "DRY RUN ($ahead ahead)"
    } else {
        try {
            $output = git push origin $Branch 2>&1
            if ($output -match 'Everything up-to-date') {
                Write-Host "  ℹ Already up to date" -ForegroundColor DarkGray
                $results['Origin'] = 'up-to-date'
            } else {
                Write-Host "  ✓ Pushed to origin/$Branch" -ForegroundColor Green
                Write-SyncLog -Repo 'origin' -Action 'push' -Status 'success' -Detail "Pushed to $Branch"
                $results['Origin'] = '✓ pushed'
            }
        } catch {
            Write-Host "  ✗ Push failed: $_" -ForegroundColor Red
            Write-SyncLog -Repo 'origin' -Action 'push' -Status 'error' -Detail "$_"
            $results['Origin'] = "✗ $($_.Exception.Message)"
        }
    }

    # ═══════════════════════════════════════════════════════════
    # STEP 3: SYNC AITHERZERO PUBLIC
    # ═══════════════════════════════════════════════════════════

    if ($SyncPublic) {
        Write-Host ""
        Write-Host "  ━━━ Step 3: Sync AitherZero public ━━━" -ForegroundColor Yellow

        $syncScript = Join-Path $PSScriptRoot "7010_Sync-OpenSource.ps1"

        if (Test-Path $syncScript) {
            if ($DryRun) {
                Write-Host "  [DRY RUN] Would sync AitherZero to public repo" -ForegroundColor Yellow
                & $syncScript -Direction push -DryRun
                $results['AitherZero'] = 'DRY RUN'
            } else {
                try {
                    $syncMsg = if ($Message) { $Message } else { "sync: update from monorepo $(Get-Date -Format 'yyyy-MM-dd')" }
                    & $syncScript -Direction push -Message $syncMsg
                    Write-Host "  ✓ AitherZero public synced" -ForegroundColor Green
                    Write-SyncLog -Repo 'aitherzero-public' -Action 'sync' -Status 'success' -Detail $syncMsg
                    $results['AitherZero'] = '✓ synced'
                } catch {
                    Write-Host "  ✗ AitherZero sync failed: $_" -ForegroundColor Red
                    Write-SyncLog -Repo 'aitherzero-public' -Action 'sync' -Status 'error' -Detail "$_"
                    $results['AitherZero'] = "✗ $($_.Exception.Message)"

                    # Retry with force if requested
                    if ($Force) {
                        Write-Host "  Retrying with force..." -ForegroundColor Yellow
                        try {
                            Ensure-Remote $Repos.AitherZero.Remote $Repos.AitherZero.Url
                            $splitSha = git subtree split --prefix=AitherZero -b aitherzero-split 2>&1
                            git push $Repos.AitherZero.Remote "aitherzero-split:$($Repos.AitherZero.TargetRef)" --force 2>&1
                            git branch -D aitherzero-split 2>&1 | Out-Null
                            Write-Host "  ✓ Force-pushed AitherZero subtree" -ForegroundColor Green
                            $results['AitherZero'] = '✓ force-pushed'
                        } catch {
                            Write-Host "  ✗ Force push also failed: $_" -ForegroundColor Red
                            $results['AitherZero'] = "✗ force failed: $_"
                        }
                    }
                }
            }
        } else {
            Write-Host "  ⚠ Sync script not found at $syncScript" -ForegroundColor Yellow
            $results['AitherZero'] = 'skipped (script missing)'
        }

        # ═══════════════════════════════════════════════════════
        # STEP 4: SYNC AITHEROS-ALPHA (if not AitherZeroOnly)
        # ═══════════════════════════════════════════════════════

        if (-not $AitherZeroOnly) {
            Write-Host ""
            Write-Host "  ━━━ Step 4: AitherOS-Alpha sync ━━━" -ForegroundColor Yellow

            # Alpha sync is done via GitHub Actions workflow (sync-alpha.yml)
            # We trigger it here if gh CLI is available
            if (Get-Command gh -ErrorAction SilentlyContinue) {
                if ($DryRun) {
                    Write-Host "  [DRY RUN] Would trigger sync-alpha workflow" -ForegroundColor Yellow
                    $results['Alpha'] = 'DRY RUN'
                } else {
                    try {
                        gh workflow run sync-alpha.yml --ref $Branch 2>&1
                        Write-Host "  ✓ Alpha sync workflow triggered" -ForegroundColor Green
                        Write-SyncLog -Repo 'alpha-public' -Action 'workflow-trigger' -Status 'success' -Detail "Triggered sync-alpha.yml"
                        $results['Alpha'] = '✓ workflow triggered'
                    } catch {
                        Write-Host "  ⚠ Could not trigger Alpha sync: $_" -ForegroundColor Yellow
                        Write-Host "    Trigger manually: gh workflow run sync-alpha.yml" -ForegroundColor DarkGray
                        $results['Alpha'] = "⚠ manual trigger needed"
                    }
                }
            } else {
                Write-Host "  ℹ gh CLI not available — Alpha sync via GitHub Actions only" -ForegroundColor DarkGray
                Write-Host "    Push to origin will trigger sync-alpha.yml on tag push" -ForegroundColor DarkGray
                $results['Alpha'] = 'skipped (no gh CLI)'
            }
        }
    }

    # ═══════════════════════════════════════════════════════════
    # SUMMARY
    # ═══════════════════════════════════════════════════════════

    Write-Host ""
    Write-Host "  ╔═════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  SYNC SUMMARY                              ║" -ForegroundColor Cyan
    Write-Host "  ╠═════════════════════════════════════════════╣" -ForegroundColor Cyan
    foreach ($key in $results.Keys | Sort-Object) {
        $val = $results[$key]
        $color = if ($val -match '✓') { 'Green' } elseif ($val -match '✗') { 'Red' } else { 'White' }
        $line = "  ║  {0,-15} {1,-28}║" -f "$($key):", $val
        Write-Host $line -ForegroundColor $color
    }
    Write-Host "  ╚═════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

} finally {
    Pop-Location
}
