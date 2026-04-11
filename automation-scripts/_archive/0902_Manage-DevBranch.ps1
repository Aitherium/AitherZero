<#
.SYNOPSIS
    Manages dev branch lifecycle for Test-Driven Development workflow.

.DESCRIPTION
    Part of SASE TDD Workflow (MISSION-003, P371-P372).
    
    Provides automated dev branch management with Git worktrees for safe,
    isolated development. Ensures all changes are validated before
    cherry-picking to target branches.

    Workflow:
    1. Create: Make isolated dev branch/worktree
    2. (Developer makes changes, writes tests)
    3. Test: Run Genesis validation suite
    4. Promote: Cherry-pick validated commits to target
    5. Cleanup: Remove dev branch and worktree

.PARAMETER Create
    Create a new dev branch for isolated development.

.PARAMETER Test
    Run Genesis test suite on current dev branch.

.PARAMETER Promote
    Cherry-pick specified commits to target branch.

.PARAMETER Cleanup
    Remove dev branch and worktree.

.PARAMETER Status
    Show current dev branch status.

.PARAMETER Feature
    Feature name for branch naming (used with -Create).

.PARAMETER Commits
    Comma-separated commit SHAs to cherry-pick (used with -Promote).

.PARAMETER UseWorktree
    Use Git worktree for complete isolation (default: true).

.PARAMETER TargetBranch
    Branch to cherry-pick to (default: current branch before dev).

.EXAMPLE
    # Create dev branch for new feature
    ./0902_Manage-DevBranch.ps1 -Create -Feature "web-search"
    
    # Run tests on dev branch
    ./0902_Manage-DevBranch.ps1 -Test
    
    # Promote validated commits
    ./0902_Manage-DevBranch.ps1 -Promote -Commits "abc123,def456"
    
    # Cleanup when done
    ./0902_Manage-DevBranch.ps1 -Cleanup

.NOTES
    SASE Mission: MISSION-003 (TDD Workflow Integration)
    Priority Items: P371, P372
    Author: Aitherium
#>

[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Create')]
    [switch]$Create,
    
    [Parameter(ParameterSetName = 'Test')]
    [switch]$Test,
    
    [Parameter(ParameterSetName = 'Promote')]
    [switch]$Promote,
    
    [Parameter(ParameterSetName = 'Cleanup')]
    [switch]$Cleanup,
    
    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,
    
    [Parameter(ParameterSetName = 'Create', Mandatory = $true)]
    [string]$Feature,
    
    [Parameter(ParameterSetName = 'Promote')]
    [string]$Commits,
    
    [Parameter(ParameterSetName = 'Create')]
    [switch]$UseWorktree = $true,
    
    [Parameter(ParameterSetName = 'Promote')]
    [string]$TargetBranch,
    
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

$AitherZeroRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$DevStateFile = Join-Path $AitherZeroRoot ".aither-dev-state.json"
$GenesisScript = Join-Path $AitherZeroRoot "AitherZero/library/automation-scripts/1100_Run-GenesisTest.ps1"
$WorktreeBaseDir = Split-Path -Parent $AitherZeroRoot

# ═══════════════════════════════════════════════════════════════════════════════
# STATE MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

function Get-DevState {
    if (Test-Path $DevStateFile) {
        return Get-Content $DevStateFile -Raw | ConvertFrom-Json
    }
    return $null
}

function Save-DevState {
    param([hashtable]$State)
    $State | ConvertTo-Json -Depth 5 | Set-Content $DevStateFile -Encoding UTF8
}

function Remove-DevState {
    if (Test-Path $DevStateFile) {
        Remove-Item $DevStateFile -Force
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

function Get-CurrentBranch {
    return (git rev-parse --abbrev-ref HEAD 2>$null)
}

function Test-IsDevBranch {
    $branch = Get-CurrentBranch
    return $branch -like "dev-*"
}

function Get-SafeFeatureName {
    param([string]$Name)
    return $Name -replace '[^a-zA-Z0-9-]', '-' -replace '-+', '-' -replace '^-|-$', ''
}

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE DEV BRANCH
# ═══════════════════════════════════════════════════════════════════════════════

function New-DevBranch {
    param(
        [string]$FeatureName,
        [switch]$Worktree
    )
    
    Write-Host "`n════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  TDD WORKFLOW - Creating Dev Branch" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    # Check if already in dev branch
    if (Test-IsDevBranch) {
        Write-Warning "Already in a dev branch: $(Get-CurrentBranch)"
        Write-Host "Use -Cleanup to remove current dev branch first."
        return
    }
    
    # Check for uncommitted changes
    $status = git status --porcelain
    if ($status -and -not $Force) {
        Write-Warning "Uncommitted changes detected. Commit or stash before creating dev branch."
        Write-Host "Use -Force to proceed anyway (changes will be included in dev branch)."
        return
    }
    
    $baseBranch = Get-CurrentBranch
    $safeFeature = Get-SafeFeatureName -Name $FeatureName
    $devBranch = "dev-$baseBranch-$safeFeature"
    
    Write-Host "`nBase Branch: $baseBranch"
    Write-Host "Dev Branch:  $devBranch"
    Write-Host "Feature:     $FeatureName"
    
    if ($Worktree) {
        # Create worktree for complete isolation
        $worktreePath = Join-Path $WorktreeBaseDir "aitherzero-$safeFeature"
        
        Write-Host "`nCreating worktree at: $worktreePath"
        
        # Create branch and worktree
        git branch $devBranch 2>$null
        git worktree add $worktreePath $devBranch
        
        # Save state
        Save-DevState @{
            BaseBranch = $baseBranch
            DevBranch = $devBranch
            Feature = $FeatureName
            WorktreePath = $worktreePath
            CreatedAt = (Get-Date -Format "o")
            UseWorktree = $true
        }
        
        Write-Host "`n✅ Dev worktree created!" -ForegroundColor Green
        Write-Host "`nTo work in dev environment:"
        Write-Host "  cd $worktreePath" -ForegroundColor Yellow
        
    } else {
        # Simple branch (no worktree)
        git checkout -b $devBranch
        
        Save-DevState @{
            BaseBranch = $baseBranch
            DevBranch = $devBranch
            Feature = $FeatureName
            WorktreePath = $null
            CreatedAt = (Get-Date -Format "o")
            UseWorktree = $false
        }
        
        Write-Host "`n✅ Dev branch created and checked out!" -ForegroundColor Green
    }
    
    Write-Host "`nNext steps:"
    Write-Host "  1. Write tests that define expected behavior"
    Write-Host "  2. Implement changes to satisfy tests"
    Write-Host "  3. Run: ./0902_Manage-DevBranch.ps1 -Test"
    Write-Host "  4. If green: ./0902_Manage-DevBranch.ps1 -Promote"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST DEV BRANCH
# ═══════════════════════════════════════════════════════════════════════════════

function Test-DevBranch {
    Write-Host "`n════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  TDD WORKFLOW - Running Validation Suite" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $state = Get-DevState
    
    if (-not $state) {
        Write-Warning "No active dev branch state found."
        Write-Host "Create one with: ./0902_Manage-DevBranch.ps1 -Create -Feature 'name'"
        return $false
    }
    
    Write-Host "`nDev Branch: $($state.DevBranch)"
    Write-Host "Feature:    $($state.Feature)"
    Write-Host "Created:    $($state.CreatedAt)"
    
    # Run Genesis test if available
    if (Test-Path $GenesisScript) {
        Write-Host "`nRunning Genesis Test Suite..." -ForegroundColor Yellow
        
        try {
            & $GenesisScript -Quick
            $testResult = $LASTEXITCODE -eq 0
        } catch {
            Write-Warning "Genesis test failed with exception: $_"
            $testResult = $false
        }
    } else {
        # Fallback to basic validation
        Write-Host "`nGenesis test not found. Running basic validation..." -ForegroundColor Yellow
        
        # Syntax check
        $syntaxScript = Join-Path $AitherZeroRoot "AitherZero/library/automation-scripts/0906_Validate-Syntax.ps1"
        if (Test-Path $syntaxScript) {
            & $syntaxScript
            $testResult = $LASTEXITCODE -eq 0
        } else {
            Write-Host "Running PowerShell syntax validation..."
            $scripts = Get-ChildItem -Path "$AitherZeroRoot/AitherZero" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
            $errors = @()
            foreach ($script in $scripts | Select-Object -First 20) {
                $parseErrors = $null
                [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
                if ($parseErrors) {
                    $errors += $parseErrors
                }
            }
            $testResult = $errors.Count -eq 0
            if (-not $testResult) {
                Write-Warning "Found $($errors.Count) syntax errors"
            }
        }
    }
    
    if ($testResult) {
        Write-Host "`n✅ VALIDATION PASSED" -ForegroundColor Green
        Write-Host "`nNext: ./0902_Manage-DevBranch.ps1 -Promote -Commits '<sha>'"
    } else {
        Write-Host "`n❌ VALIDATION FAILED" -ForegroundColor Red
        Write-Host "`nFix the issues and run -Test again."
    }
    
    return $testResult
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROMOTE COMMITS
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-Promote {
    param(
        [string]$CommitList,
        [string]$Target
    )
    
    Write-Host "`n════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  TDD WORKFLOW - Promoting Commits" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $state = Get-DevState
    
    if (-not $state) {
        Write-Warning "No active dev branch state found."
        return
    }
    
    $targetBranch = if ($Target) { $Target } else { $state.BaseBranch }
    
    Write-Host "`nDev Branch:    $($state.DevBranch)"
    Write-Host "Target Branch: $targetBranch"
    
    # Get commits to cherry-pick
    if (-not $CommitList) {
        # Default: all commits on dev branch not on base
        Write-Host "`nFinding commits to promote..."
        $commits = git log "$targetBranch..$($state.DevBranch)" --oneline --reverse
        
        if (-not $commits) {
            Write-Warning "No commits to promote."
            return
        }
        
        Write-Host "Commits found:"
        $commits | ForEach-Object { Write-Host "  $_" }
        
        if (-not $Force) {
            $confirm = Read-Host "`nPromote these commits? (y/N)"
            if ($confirm -ne 'y') {
                Write-Host "Cancelled."
                return
            }
        }
        
        $commitShas = git log "$targetBranch..$($state.DevBranch)" --format="%H" --reverse
    } else {
        $commitShas = $CommitList -split ','
    }
    
    # Switch to target branch
    if ($state.UseWorktree) {
        # Cherry-pick from worktree to main repo
        Push-Location $AitherZeroRoot
        git checkout $targetBranch
    } else {
        git checkout $targetBranch
    }
    
    # Cherry-pick each commit
    $promoted = 0
    foreach ($sha in $commitShas) {
        $sha = $sha.Trim()
        if ($sha) {
            Write-Host "Cherry-picking: $sha"
            git cherry-pick $sha
            if ($LASTEXITCODE -eq 0) {
                $promoted++
            } else {
                Write-Warning "Failed to cherry-pick $sha"
                git cherry-pick --abort 2>$null
                break
            }
        }
    }
    
    if ($state.UseWorktree) {
        Pop-Location
    }
    
    Write-Host "`n✅ Promoted $promoted commit(s) to $targetBranch" -ForegroundColor Green
    Write-Host "`nNext: ./0902_Manage-DevBranch.ps1 -Cleanup"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════

function Remove-DevBranch {
    Write-Host "`n════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  TDD WORKFLOW - Cleanup" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $state = Get-DevState
    
    if (-not $state) {
        Write-Warning "No active dev branch state found."
        return
    }
    
    Write-Host "`nDev Branch: $($state.DevBranch)"
    Write-Host "Base Branch: $($state.BaseBranch)"
    
    if ($state.UseWorktree -and $state.WorktreePath) {
        Write-Host "Worktree: $($state.WorktreePath)"
        
        # Ensure we're not in the worktree
        $currentPath = Get-Location
        if ($currentPath.Path -like "$($state.WorktreePath)*") {
            Set-Location $AitherZeroRoot
        }
        
        # Remove worktree
        Write-Host "`nRemoving worktree..."
        git worktree remove $state.WorktreePath --force 2>$null
    }
    
    # Ensure we're on base branch
    $current = Get-CurrentBranch
    if ($current -eq $state.DevBranch) {
        git checkout $state.BaseBranch
    }
    
    # Delete dev branch
    Write-Host "Deleting branch: $($state.DevBranch)"
    git branch -D $state.DevBranch 2>$null
    
    # Remove state file
    Remove-DevState
    
    Write-Host "`n✅ Cleanup complete!" -ForegroundColor Green
    Write-Host "Now on branch: $(Get-CurrentBranch)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATUS
# ═══════════════════════════════════════════════════════════════════════════════

function Show-Status {
    Write-Host "`n════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  TDD WORKFLOW - Status" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $state = Get-DevState
    
    Write-Host "`nCurrent Branch: $(Get-CurrentBranch)"
    Write-Host "Is Dev Branch:  $(Test-IsDevBranch)"
    
    if ($state) {
        Write-Host "`n--- Active Dev Session ---" -ForegroundColor Yellow
        Write-Host "Dev Branch:   $($state.DevBranch)"
        Write-Host "Base Branch:  $($state.BaseBranch)"
        Write-Host "Feature:      $($state.Feature)"
        Write-Host "Created:      $($state.CreatedAt)"
        Write-Host "Worktree:     $(if ($state.UseWorktree) { $state.WorktreePath } else { 'No' })"
        
        # Show commits on dev branch
        if ($state.DevBranch -and $state.BaseBranch) {
            $commits = git log "$($state.BaseBranch)..$($state.DevBranch)" --oneline 2>$null
            if ($commits) {
                Write-Host "`nCommits on dev branch:"
                $commits | ForEach-Object { Write-Host "  $_" }
            } else {
                Write-Host "`nNo commits yet on dev branch."
            }
        }
    } else {
        Write-Host "`nNo active dev session."
        Write-Host "Create one with: ./0902_Manage-DevBranch.ps1 -Create -Feature 'name'"
    }
    
    Write-Host "`n--- TDD Workflow Commands ---" -ForegroundColor Yellow
    Write-Host "  -Create -Feature 'name'  Create dev branch"
    Write-Host "  -Test                    Run validation suite"
    Write-Host "  -Promote [-Commits]      Cherry-pick to target"
    Write-Host "  -Cleanup                 Remove dev branch"
    Write-Host "  -Status                  Show this status"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

Push-Location $AitherZeroRoot

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Create' {
            New-DevBranch -FeatureName $Feature -Worktree:$UseWorktree
        }
        'Test' {
            Test-DevBranch
        }
        'Promote' {
            Invoke-Promote -CommitList $Commits -Target $TargetBranch
        }
        'Cleanup' {
            Remove-DevBranch
        }
        default {
            Show-Status
        }
    }
} finally {
    Pop-Location
}

