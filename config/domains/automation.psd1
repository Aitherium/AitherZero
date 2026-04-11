@{
    # ===================================================================
    # AUTOMATION - Orchestration and Execution Control
    # ===================================================================
    Automation               = @{
        # Script execution settings
        ScriptsPath             = './library/automation-scripts'
        DefaultTimeout          = 3600
        MaxTimeout              = 7200  # Maximum allowed timeout (2 hours)
        MaxConcurrency          = 4
        ParallelExecution       = $true
        DefaultMode             = 'Parallel'  # Parallel, Sequential, Staged, Conditional

        # Success criteria defaults - applied to all playbooks unless overridden
        # Individual playbooks can override these in their SuccessCriteria section
        DefaultSuccessCriteria  = @{
            RequireAllSuccess      = $true   # Default: 100% success required (strict mode)
            MinimumSuccessCount    = 0       # Ignored when RequireAllSuccess is true
            MinimumSuccessPercent  = 100     # Alternative: percentage-based threshold
            AllowedFailures        = @()     # Default: no failures allowed
            StopOnError            = $false  # Continue through all steps by default
        }

        # Error handling and retries
        ContinueOnError         = $false
        MaxRetries              = 3
        RetryDelay              = 5
        EnableRollback          = $false

        # Execution control
        ValidateBeforeRun       = $true
        SkipConfirmation        = $false
        RequiredModules         = @('ThreadJob')
        AutoInstallDependencies = $true

        # Orchestration engine settings
        OrchestrationEngine     = @{
            SupportsParallel     = $true
            SupportsSequential   = $true
            SupportsMixed        = $true
            DependencyResolution = $true
            MaxConcurrency       = 4
            DefaultMode          = 'Parallel'
        }

        # Progress and monitoring
        ShowProgress            = $true
        ShowDependencies        = $true
        ExecutionHistory        = $true
        HistoryRetentionDays    = 30
        CacheExecutionPlans     = $true
        NotificationEnabled     = $true

        # Script range defaults - defines behavior per script number range
        ScriptRangeDefaults     = @{
            '0000-0099' = @{
                Name              = 'Environment Setup'
                DefaultTimeout    = 300  # 5 minutes
                ContinueOnError   = $false
                RequiresElevation = $true
                Stage             = 'Setup'
                AllowParallel     = $false  # Sequential for setup scripts
            }
            '0100-0199' = @{
                Name              = 'Infrastructure'
                DefaultTimeout    = 600  # 10 minutes
                ContinueOnError   = $false
                RequiresElevation = $true
                Stage             = 'Infrastructure'
                AllowParallel     = $true
            }
            '0200-0299' = @{
                Name              = 'Development Tools'
                DefaultTimeout    = 900  # 15 minutes
                ContinueOnError   = $true  # Can continue if optional tools fail
                RequiresElevation = $false
                Stage             = 'Development'
                AllowParallel     = $true
            }
            '0400-0499' = @{
                Name              = 'Testing & Validation'
                DefaultTimeout    = 600  # 10 minutes
                ContinueOnError   = $true  # Show all test results
                RequiresElevation = $false
                Stage             = 'Testing'
                AllowParallel     = $true
            }
            '0500-0599' = @{
                Name              = 'Reporting & Metrics'
                DefaultTimeout    = 300  # 5 minutes
                ContinueOnError   = $true
                RequiresElevation = $false
                Stage             = 'Reporting'
                AllowParallel     = $true
            }
            '0700-0799' = @{
                Name              = 'Git Automation'
                DefaultTimeout    = 180  # 3 minutes
                ContinueOnError   = $false
                RequiresElevation = $false
                Stage             = 'Development'
                AllowParallel     = $false
            }
            '0800-0899' = @{
                Name              = 'Issue Management'
                DefaultTimeout    = 120  # 2 minutes
                ContinueOnError   = $true
                RequiresElevation = $false
                Stage             = 'Development'
                AllowParallel     = $true
            }
            '0900-0999' = @{
                Name              = 'Validation & Diagnostics'
                DefaultTimeout    = 300  # 5 minutes
                ContinueOnError   = $true
                RequiresElevation = $false
                Stage             = 'Testing'
                AllowParallel     = $true
            }
            '9000-9999' = @{
                Name              = 'Maintenance & Cleanup'
                DefaultTimeout    = 600  # 10 minutes
                ContinueOnError   = $true
                RequiresElevation = $true
                Stage             = 'Maintenance'
                AllowParallel     = $false
            }
        }

        # Execution profiles mapping - references Manifest.ExecutionProfiles
        # Profiles are defined in Manifest.ExecutionProfiles (lines 432-465)
        # This section provides automation-specific settings for each profile
        ProfileSettings         = @{
            Minimal = @{
                MaxConcurrency = 2
            }
            Standard = @{
                MaxConcurrency = 4
            }
            Developer = @{
                MaxConcurrency = 6
            }
            Full = @{
                MaxConcurrency = 8
            }
            CI = @{
                MaxConcurrency = 4
                Parallel = $true
                NonInteractive = $true
            }
        }

        # Playbook registry - centralized playbook management
        Playbooks               = @{
            'test-orchestration'     = @{
                Enabled             = $true
                Description         = 'Enhanced test orchestration with three-tier validation'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'comprehensive-validation' = @{
                Enabled             = $true
                Description         = 'Complete three-tier validation: AST → PSScriptAnalyzer → Pester'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI', 'Staging', 'Production')
                Features            = @('AST', 'PSScriptAnalyzer', 'Pester', 'FunctionalTests', 'QualityScore')
            }
            'pr-ecosystem-complete' = @{
                Enabled             = $true
                Description         = 'Complete PR ecosystem: Build → Analyze → Report with full deployment artifacts'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
                Features            = @('Build', 'Analyze', 'Report', 'Dashboard', 'QualityMetrics', 'Deployment', 'Container', 'ReleasePackages')
            }
            'project-health-check'   = @{
                Enabled             = $true
                Description         = 'Complete project health validation (matches GitHub Actions)'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
                ScriptDefaults      = @{
                    DefaultTimeout = 300  # Override range defaults for this playbook
                }
            }
            'pr-validation-fast'     = @{
                Enabled             = $true
                Description         = 'Fast PR validation (syntax + config)'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
                ScriptDefaults      = @{
                    '0407' = @{ Timeout = 60 }   # Faster syntax check
                    '0413' = @{ Timeout = 30 }   # Faster config validation
                }
            }
            'pr-validation-full'     = @{
                Enabled             = $true
                Description         = 'Full PR validation (syntax, quality, tests)'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'code-quality-fast'      = @{
                Enabled             = $true
                Description         = 'Quick code quality checks'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'code-quality-full'      = @{
                Enabled             = $true
                Description         = 'Comprehensive code quality analysis'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'integration-tests-full' = @{
                Enabled             = $true
                Description         = 'Full integration test suite'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
                ScriptDefaults      = @{
                    DefaultTimeout  = 600
                    ContinueOnError = $true
                }
            }
            'diagnose-ci'            = @{
                Enabled             = $true
                Description         = 'Diagnose CI/CD failures'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'fix-ci-validation'      = @{
                Enabled             = $false  # Disabled by default - maintenance only
                Description         = 'Fix CI validation issues'
                RequiresApproval    = $true
                AllowedEnvironments = @('Dev')
            }
            'generate-documentation' = @{
                Enabled             = $true
                Description         = 'Generate all project documentation'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'generate-indexes'       = @{
                Enabled             = $true
                Description         = 'Generate all project indexes'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'pr-validation'          = @{
                Enabled             = $true
                Description         = 'Comprehensive PR validation (8 phases)'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'pr-ecosystem-build'     = @{
                Enabled             = $true
                Description         = 'PR ecosystem build phase'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'pr-ecosystem-analyze'   = @{
                Enabled             = $true
                Description         = 'PR ecosystem analysis phase'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'pr-ecosystem-report'    = @{
                Enabled             = $true
                Description         = 'PR ecosystem reporting phase'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
            }
            'self-deployment-test'   = @{
                Enabled             = $true
                Description         = 'Self-deployment validation - tests that AitherZero can deploy itself'
                RequiresApproval    = $false
                AllowedEnvironments = @('Dev', 'CI')
                ScriptDefaults      = @{
                    DefaultTimeout  = 600  # Self-deployment can take time
                    ContinueOnError = $true  # Don't fail on individual test failures
                }
            }
        }
    }

    # ===================================================================
    # AUTOMATED ISSUE MANAGEMENT - GitHub Issue Automation
    # ===================================================================
    AutomatedIssueManagement = @{
        # Issue creation settings
        AutoCreateIssues       = $true
        CreateFromTestFailures = $true
        CreateFromCodeQuality  = $true
        CreateFromSecurity     = $true

        # Priority-based processing
        PriorityLabels         = @{
            Enabled         = $true
            Required        = $true  # Priority label REQUIRED before automated processing
            ValidLabels     = @('P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P8', 'P9', 'P10')
            DefaultPriority = 'P5'  # Default if not specified

            # Priority definitions
            P1              = @{ Name = 'Critical'; SLA = '4 hours'; AutoProcess = $true }
            P2              = @{ Name = 'High'; SLA = '24 hours'; AutoProcess = $true }
            P3              = @{ Name = 'Medium'; SLA = '48 hours'; AutoProcess = $true }
            P4              = @{ Name = 'Normal'; SLA = '1 week'; AutoProcess = $true }
            P5              = @{ Name = 'Low'; SLA = '2 weeks'; AutoProcess = $true }
            P6toP10         = @{ Name = 'Backlog'; SLA = 'As capacity allows'; AutoProcess = $true }
        }

        # Automated processing rules
        AutomatedProcessing    = @{
            Enabled               = $true
            RequirePriorityLabel  = $true  # Must have P1-P10 label to be auto-processed
            RequireManualApproval = $false  # Set to true to require @copilot mention
            MinimumAgeHours       = 2  # Wait 2 hours before auto-processing (allows manual triage)
            MaxIssuesPerRun       = 5  # Limit concurrent processing

            # Filters
            RequiredLabels        = @('copilot-task')  # Must have these labels
            ExcludedLabels        = @('on-hold', 'blocked', 'wontfix')  # Skip these
        }

        # PR-based grouping (Phase 2)
        PRGrouping             = @{
            Enabled                  = $true
            MinimumGroupSize         = 2  # Minimum issues to create group PR (except P1/P2)
            GroupByType              = $true  # Group by issue type (code-quality, testing, security)
            GroupByDomain            = $true  # Group by file/domain context
            GroupByPriority          = $true  # Final grouping by priority level

            # Grouping rules
            AlwaysGroupTypes         = @('code-quality', 'testing', 'security', 'maintenance')
            SingleIssuePRForPriority = @('P1', 'P2')  # Create individual PR for these priorities

            # Branch naming
            BranchPrefix             = 'auto-fix/'
            BranchPattern            = '{type}-{context}-{priority}-{timestamp}'

            # PR settings
            PRTitlePattern           = '🤖 [{priority}] Fix {type} issues in {context}'
            AddCopilotMention        = $true  # Mention @copilot in PR
            LinkIssuesToPR           = $true  # Add comments linking issues to PR
            AddInProgressLabel       = $true  # Add in-progress label to grouped issues
        }

        # Workflow integration
        Workflows              = @{
            IssueCreation  = 'auto-create-issues-from-failures.yml'
            CopilotAgent   = 'automated-copilot-agent.yml'
            PRAutomation   = 'copilot-pr-automation.yml'
            IssueCommenter = 'copilot-issue-commenter.yml'
            IssueCleanup   = 'close-auto-issues.yml'  # Phase 1: Close existing auto-created issues
            PRGrouping     = 'auto-create-prs-for-issues.yml'  # Phase 2: Group issues and create PRs
        }

        # Label management
        Labels                 = @{
            AutoCreated   = 'auto-created'
            CopilotTask   = 'copilot-task'
            CopilotPR     = 'copilot-pr'  # PRs created for grouped issues
            NeedsPriority = 'needs-priority'  # Issues awaiting priority assignment
            TestFailure   = 'test-failure'
            CodeQuality   = 'code-quality'
            Security      = 'security'
            NeedsFix      = 'needs-fix'
            InProgress    = 'in-progress'  # Issues linked to active PR
            NeedsReview   = 'needs-review'
        }
    }
}
