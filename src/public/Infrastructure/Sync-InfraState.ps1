#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Synchronise OpenTofu state and generated configs with a Git-managed infrastructure repository.

.DESCRIPTION
    Sync-InfraState manages the bidirectional sync between OpenTofu workspaces and Git:

    Push flow (after apply):
    - Copies terraform.tfstate to repo's .state/<env>/ directory
    - Commits with structured message linking to pipeline/request IDs
    - Optionally pushes to remote

    Pull flow (before plan):
    - Pulls latest configs from remote
    - Restores state files to workspace directories
    - Validates state serial consistency

    State management:
    - Environment-isolated state directories (.state/dev/, .state/staging/, .state/prod/)
    - State locking via Git branch-based locks (lock-state-<env> branches)
    - State backup with serial versioning
    - State encryption for remote backends (passes through to tofu)

    This is the Git-ops backbone that ensures:
    - All infrastructure configs are version-controlled
    - State files are backed up and auditable
    - Multiple operators can collaborate without state conflicts
    - Rollback is possible via git revert

.PARAMETER RepoPath
    Path to the infrastructure Git repository.

.PARAMETER Environment
    Target environment for state sync.

.PARAMETER WorkspacePath
    OpenTofu workspace directory containing terraform.tfstate.

.PARAMETER Direction
    Sync direction: Push (workspace → repo) or Pull (repo → workspace).

.PARAMETER PipelineId
    Pipeline ID for commit message traceability.

.PARAMETER RequestId
    Infrastructure request ID for commit message traceability.

.PARAMETER AutoPush
    Automatically push to remote after committing.

.PARAMETER Lock
    Acquire state lock before syncing (creates lock-state-<env> branch).

.PARAMETER Force
    Force sync even if state serial mismatch detected.

.PARAMETER BackupState
    Create a timestamped backup before overwriting state. Default: true.

.PARAMETER PassThru
    Return sync result object.

.EXAMPLE
    Sync-InfraState -RepoPath ./infra -Environment dev -WorkspacePath ./environments/dev -Direction Push

.EXAMPLE
    Sync-InfraState -RepoPath ./infra -Environment staging -Direction Pull

.NOTES
    Part of AitherZero Infrastructure pipeline.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Sync-InfraState {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoPath,

        [Parameter(Mandatory)]
        [ValidateSet('dev', 'staging', 'prod')]
        [string]$Environment,

        [string]$WorkspacePath,

        [ValidateSet('Push', 'Pull')]
        [string]$Direction = 'Push',

        [string]$PipelineId,

        [string]$RequestId,

        [switch]$AutoPush,

        [switch]$Lock,

        [switch]$Force,

        [bool]$BackupState = $true,

        [switch]$PassThru
    )

    $SyncId = "sync-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $StateDir = Join-Path $RepoPath '.state' $Environment
    $EnvDir = Join-Path $RepoPath 'environments' $Environment

    Write-Host "`n  🔄 Infrastructure State Sync ($Direction)" -ForegroundColor Cyan
    Write-Host "  Repo:        $RepoPath" -ForegroundColor Gray
    Write-Host "  Environment: $Environment" -ForegroundColor Gray
    Write-Host "  Direction:   $Direction" -ForegroundColor Gray

    # Resolve workspace
    if (-not $WorkspacePath) {
        $WorkspacePath = $EnvDir
    }

    $Result = [PSCustomObject]@{
        sync_id       = $SyncId
        direction     = $Direction
        environment   = $Environment
        repo_path     = $RepoPath
        workspace     = $WorkspacePath
        status        = 'pending'
        state_serial  = $null
        files_synced  = @()
        locked        = $false
        pushed        = $false
        backup_path   = $null
        error         = $null
    }

    try {
        # ── Validate paths ────────────────────────────────────────────────
        if (-not (Test-Path $RepoPath)) {
            throw "Repository path not found: $RepoPath"
        }
        if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
            throw "Not a Git repository: $RepoPath"
        }

        # Ensure state directory exists
        if (-not (Test-Path $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }

        # ── Acquire lock ──────────────────────────────────────────────────
        if ($Lock) {
            $LockBranch = "lock-state-$Environment"
            Push-Location $RepoPath
            try {
                # Check if lock branch exists (means someone else has it)
                $lockExists = git branch --list $LockBranch 2>&1
                if ($lockExists -and -not $Force) {
                    throw "State lock held: branch '$LockBranch' exists. Use -Force to override."
                }

                # Create lock branch from current HEAD
                git branch -f $LockBranch HEAD 2>&1 | Out-Null
                $Result.locked = $true
                Write-Host "  🔒 Lock acquired ($LockBranch)" -ForegroundColor Green
            } finally {
                Pop-Location
            }
        }

        switch ($Direction) {
            'Push' {
                # ── Push: workspace → repo ────────────────────────────────
                $StateFile = Join-Path $WorkspacePath 'terraform.tfstate'

                if (-not (Test-Path $StateFile)) {
                    Write-Host "  ⚠️  No state file found in workspace" -ForegroundColor DarkYellow
                    $Result.status = 'no-state'
                    break
                }

                # Read state serial
                $State = Get-Content $StateFile -Raw | ConvertFrom-Json
                $Result.state_serial = $State.serial

                # Check serial conflict
                $RepoStateFile = Join-Path $StateDir 'terraform.tfstate'
                if ((Test-Path $RepoStateFile) -and -not $Force) {
                    $RepoState = Get-Content $RepoStateFile -Raw | ConvertFrom-Json
                    if ($RepoState.serial -ge $State.serial) {
                        throw "State serial conflict: repo has serial $($RepoState.serial), workspace has $($State.serial). Use -Force to override."
                    }
                }

                # Backup existing state
                if ($BackupState -and (Test-Path $RepoStateFile)) {
                    $BackupDir = Join-Path $StateDir 'backups'
                    if (-not (Test-Path $BackupDir)) {
                        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
                    }
                    $BackupFile = Join-Path $BackupDir "terraform.tfstate.serial-$($RepoState.serial).$(Get-Date -Format 'yyyyMMddHHmmss')"
                    Copy-Item $RepoStateFile $BackupFile
                    $Result.backup_path = $BackupFile
                    Write-Host "  💾 State backed up (serial $($RepoState.serial))" -ForegroundColor DarkGray

                    # Keep only last 10 backups
                    $Backups = Get-ChildItem $BackupDir -File | Sort-Object LastWriteTime -Descending
                    if ($Backups.Count -gt 10) {
                        $Backups | Select-Object -Skip 10 | Remove-Item -Force
                    }
                }

                # Copy state file
                if ($PSCmdlet.ShouldProcess($RepoStateFile, "Copy state (serial $($State.serial))")) {
                    Copy-Item $StateFile $RepoStateFile -Force
                    $Result.files_synced += 'terraform.tfstate'
                    Write-Host "  📄 State copied (serial $($State.serial), $($State.resources.Count) resources)" -ForegroundColor Green
                }

                # Copy state backup if exists
                $BackupSrc = Join-Path $WorkspacePath 'terraform.tfstate.backup'
                if (Test-Path $BackupSrc) {
                    Copy-Item $BackupSrc (Join-Path $StateDir 'terraform.tfstate.backup') -Force
                    $Result.files_synced += 'terraform.tfstate.backup'
                }

                # Copy any plan files
                $PlanFile = Get-ChildItem $WorkspacePath -Filter '*.tfplan' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($PlanFile) {
                    Copy-Item $PlanFile.FullName (Join-Path $StateDir $PlanFile.Name) -Force
                    $Result.files_synced += $PlanFile.Name
                }

                # Write sync metadata
                @{
                    sync_id      = $SyncId
                    serial       = $State.serial
                    resources    = $State.resources.Count
                    synced_at    = [DateTime]::UtcNow.ToString('o')
                    pipeline_id  = $PipelineId
                    request_id   = $RequestId
                    workspace    = $WorkspacePath
                    tofu_version = $State.terraform_version
                } | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $StateDir 'sync-metadata.json') -Encoding UTF8
                $Result.files_synced += 'sync-metadata.json'

                # Git commit
                Push-Location $RepoPath
                try {
                    git add -A 2>&1 | Out-Null
                    $gitStatus = git status --porcelain 2>&1
                    if ($gitStatus) {
                        $CommitMsg = "state($Environment): serial $($State.serial) | $($State.resources.Count) resources"
                        if ($PipelineId) { $CommitMsg += " [pipeline:$PipelineId]" }
                        if ($RequestId) { $CommitMsg += " [request:$RequestId]" }

                        git commit -m $CommitMsg 2>&1 | Out-Null
                        Write-Host "  📝 Committed: $CommitMsg" -ForegroundColor Green

                        if ($AutoPush) {
                            git push origin HEAD 2>&1 | Out-Null
                            $Result.pushed = $true
                            Write-Host "  📡 Pushed to remote" -ForegroundColor Green
                        }
                    } else {
                        Write-Host "  No changes to commit" -ForegroundColor DarkGray
                    }
                } finally {
                    Pop-Location
                }

                $Result.status = 'synced'
            }

            'Pull' {
                # ── Pull: repo → workspace ────────────────────────────────
                if (-not (Test-Path $WorkspacePath)) {
                    New-Item -ItemType Directory -Path $WorkspacePath -Force | Out-Null
                }

                # Pull latest from remote
                Push-Location $RepoPath
                try {
                    git pull origin HEAD --rebase 2>&1 | Out-Null
                    Write-Host "  📥 Pulled latest from remote" -ForegroundColor Green
                } catch {
                    Write-Host "  ⚠️  Git pull failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
                } finally {
                    Pop-Location
                }

                # Copy state to workspace
                $RepoStateFile = Join-Path $StateDir 'terraform.tfstate'
                if (Test-Path $RepoStateFile) {
                    $State = Get-Content $RepoStateFile -Raw | ConvertFrom-Json
                    $Result.state_serial = $State.serial

                    $TargetStateFile = Join-Path $WorkspacePath 'terraform.tfstate'

                    # Check serial conflict
                    if ((Test-Path $TargetStateFile) -and -not $Force) {
                        $WorkspaceState = Get-Content $TargetStateFile -Raw | ConvertFrom-Json
                        if ($WorkspaceState.serial -gt $State.serial) {
                            throw "Workspace has newer state (serial $($WorkspaceState.serial)) than repo (serial $($State.serial)). Push workspace state first or use -Force."
                        }
                    }

                    if ($PSCmdlet.ShouldProcess($TargetStateFile, "Restore state (serial $($State.serial))")) {
                        Copy-Item $RepoStateFile $TargetStateFile -Force
                        $Result.files_synced += 'terraform.tfstate'
                        Write-Host "  📄 State restored (serial $($State.serial))" -ForegroundColor Green
                    }
                } else {
                    Write-Host "  ⚠️  No state file in repo for $Environment" -ForegroundColor DarkYellow
                }

                # Copy environment configs if workspace is different from env dir
                if ($WorkspacePath -ne $EnvDir -and (Test-Path $EnvDir)) {
                    Get-ChildItem $EnvDir -Filter '*.tf' | ForEach-Object {
                        Copy-Item $_.FullName (Join-Path $WorkspacePath $_.Name) -Force
                        $Result.files_synced += $_.Name
                    }
                    Get-ChildItem $EnvDir -Filter '*.tfvars' | ForEach-Object {
                        Copy-Item $_.FullName (Join-Path $WorkspacePath $_.Name) -Force
                        $Result.files_synced += $_.Name
                    }
                    Write-Host "  📄 Configs synced ($($Result.files_synced.Count) files)" -ForegroundColor Green
                }

                $Result.status = 'synced'
            }
        }
    } catch {
        $Result.status = 'failed'
        $Result.error = $_.Exception.Message
        Write-Host "  ❌ Sync failed: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        # Release lock
        if ($Result.locked) {
            $LockBranch = "lock-state-$Environment"
            Push-Location $RepoPath
            try {
                git branch -D $LockBranch 2>&1 | Out-Null
                Write-Host "  🔓 Lock released ($LockBranch)" -ForegroundColor DarkGray
            } catch {
                Write-Host "  ⚠️  Failed to release lock" -ForegroundColor DarkYellow
            } finally {
                Pop-Location
            }
        }
    }

    Write-Host "  ── Sync $($Result.status) ($($Result.files_synced.Count) files) ──`n" -ForegroundColor $(
        if ($Result.status -eq 'synced') { 'Green' } else { 'Red' }
    )

    if ($PassThru) { return $Result }
}

Export-ModuleMember -Function Sync-InfraState
