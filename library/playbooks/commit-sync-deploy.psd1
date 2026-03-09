@{
    # =========================================================================
    # COMMIT-SYNC-DEPLOY PLAYBOOK
    # =========================================================================
    # Full pipeline: commit → push → sync all repos → promote rings
    # This is the playbook that Atlas/Demiurge agents call for deployments.
    #
    # Usage:
    #   ./bootstrap.ps1 -Playbook commit-sync-deploy
    #   Invoke-AitherPlaybook -Name commit-sync-deploy -Variables @{Message="feat: new feature"}
    #   MCP: execute_playbook("commit-sync-deploy", variables={message: "feat: update"})
    # =========================================================================

    Name        = "commit-sync-deploy"
    Description = "Commit changes, push to all repos, and optionally promote rings. The master deployment playbook for agent-driven workflows."
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "deploy"

    Parameters = @{
        Message       = ""         # Commit message (auto-generated if empty)
        PromoteRing   = "none"     # "none", "staging", "prod", or "all"
        SyncPublic    = $true      # Sync to public repos
        DryRun        = $false     # Preview mode
        Force         = $false     # Force push/promote
        SkipTests     = $false     # Skip test gates
        SkipBuild     = $false     # Skip build gates
    }

    Prerequisites = @(
        "Git configured with push access to all remotes"
        "GitHub CLI (gh) installed for PR and workflow triggers"
    )

    # =========================================================================
    # PHASES
    # =========================================================================

    Phases = @(
        # ─── Phase 1: Validate ───────────────────────────────────────
        @{
            Name        = "validate"
            Description = "Pre-flight checks"
            Steps       = @(
                @{
                    Name    = "Check Git Status"
                    Type    = "command"
                    Command = "git status --porcelain | Measure-Object | Select-Object -ExpandProperty Count"
                    ContinueOnError = $true
                }
                @{
                    Name    = "Verify Remotes"
                    Type    = "command"
                    Command = "git remote -v"
                }
                @{
                    Name    = "Check gh CLI"
                    Type    = "command"
                    Command = "if (Get-Command gh -ErrorAction SilentlyContinue) { Write-Host '✓ gh CLI available' } else { Write-Host '⚠ gh CLI not found (Alpha sync will be skipped)' }"
                    ContinueOnError = $true
                }
            )
        }

        # ─── Phase 2: Quality Gate (optional) ────────────────────────
        @{
            Name        = "quality"
            Description = "Run quality checks before deploy"
            Condition   = '$Parameters.SkipTests -eq $false'
            Steps       = @(
                @{
                    Name    = "Syntax Validation"
                    Script  = "0906"
                    Args    = "-QuickCheck"
                    ContinueOnError = $true
                }
                @{
                    Name    = "PSScriptAnalyzer"
                    Script  = "0404"
                    ContinueOnError = $true
                }
            )
        }

        # ─── Phase 3: Commit & Push ─────────────────────────────────
        @{
            Name        = "sync"
            Description = "Commit and push to all repositories"
            Steps       = @(
                @{
                    Name    = "Sync All Repos"
                    Script  = "7011"
                    Args    = '-Message "$($Parameters.Message)" $(if($Parameters.DryRun){"-DryRun"}) $(if($Parameters.Force){"-Force"}) $(if(-not $Parameters.SyncPublic){"-SkipCommit"})'
                    Timeout = 300
                }
            )
        }

        # ─── Phase 4: Ring Promotion (optional) ─────────────────────
        @{
            Name        = "promote-staging"
            Description = "Promote to staging ring"
            Condition   = '$Parameters.PromoteRing -in @("staging", "all")'
            Steps       = @(
                @{
                    Name    = "Promote dev → staging"
                    Script  = "3025"
                    Args    = '-Action promote -From dev -To staging -Approve -NonInteractive $(if($Parameters.SkipTests){"-SkipTests"}) $(if($Parameters.SkipBuild){"-SkipBuild"}) $(if($Parameters.DryRun){"-DryRun"}) $(if($Parameters.Force){"-Force"})'
                    Timeout = 600
                }
            )
        }
        @{
            Name        = "promote-prod"
            Description = "Promote to production ring"
            Condition   = '$Parameters.PromoteRing -eq "prod" -or $Parameters.PromoteRing -eq "all"'
            Steps       = @(
                @{
                    Name    = "Promote staging → prod"
                    Script  = "3025"
                    Args    = '-Action promote -From staging -To prod -Approve -NonInteractive $(if($Parameters.DryRun){"-DryRun"}) $(if($Parameters.Force){"-Force"})'
                    Timeout = 900
                    RequiresApproval = $true
                }
            )
        }

        # ─── Phase 5: Verify ────────────────────────────────────────
        @{
            Name        = "verify"
            Description = "Post-deploy verification"
            Steps       = @(
                @{
                    Name    = "Ring Status"
                    Script  = "3025"
                    Args    = "-Action status -NonInteractive"
                }
                @{
                    Name    = "Git Log"
                    Type    = "command"
                    Command = "git log --oneline -5"
                }
            )
        }
    )

    # =========================================================================
    # PROFILES
    # =========================================================================

    Profiles = @{
        quick = @{
            Description = "Fast sync: commit + push, skip quality checks"
            Overrides   = @{
                SkipTests = $true
                SkipBuild = $true
            }
            SkipPhases = @("quality")
        }
        standard = @{
            Description = "Standard: commit + push + quality checks"
            Overrides   = @{}
        }
        full = @{
            Description = "Full pipeline: commit + push + quality + promote staging"
            Overrides   = @{
                PromoteRing = "staging"
            }
        }
        ci = @{
            Description = "CI mode: non-interactive, full pipeline through prod"
            Overrides   = @{
                PromoteRing = "all"
                Force       = $false
            }
        }
    }

    # =========================================================================
    # NOTIFICATIONS
    # =========================================================================

    Notifications = @{
        OnSuccess = @{
            Type    = "strata"
            Message = "Multi-repo sync completed successfully"
        }
        OnFailure = @{
            Type    = "strata"
            Message = "Multi-repo sync failed — manual intervention may be needed"
        }
    }
}
