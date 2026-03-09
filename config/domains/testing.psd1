@{
    # ===================================================================
    # TESTING - Test Execution and Quality Assurance
    # ===================================================================
    Testing                  = @{
        # Testing framework
        Framework          = 'Pester'
        ShowProgress       = $true
        NotifyOnCompletion = $true
        ShowSkipped        = $true

        # Test execution profiles
        Profiles           = @{
            Quick    = @{
                Description = 'Fast validation for development'
                Categories  = @('Unit', 'Syntax')
                Timeout     = 300
                FailFast    = $true
            }
            Standard = @{
                Description = 'Default test suite'
                Categories  = @('Unit', 'Integration', 'Syntax')
                Timeout     = 900
                FailFast    = $false
            }
            Full     = @{
                Description = 'Complete validation including performance'
                Categories  = @('*')
                Timeout     = 3600
                FailFast    = $false
            }
            CI       = @{
                Description     = 'Continuous Integration suite'
                Categories      = @('Unit', 'Integration', 'E2E')
                Timeout         = 1800
                FailFast        = $true
                GenerateReports = $true
                Platforms       = @('Windows', 'Linux', 'macOS')
            }
        }

        # Pester configuration
        Pester             = @{
            # Parallel execution settings - optimized for performance
            Parallel = @{
                Enabled          = $true
                BlockSize        = 3   # Base block size for Pester parallel execution
                Workers          = 4     # Balanced worker count for CI environments
                ProcessIsolation = $false  # Disable process isolation for faster execution
            }

            # Output settings - optimized for CI/CD
            Output   = @{
                Verbosity           = 'Minimal'     # Minimal output for speed
                CIFormat            = $true          # Use CI-friendly output format
                StackTraceVerbosity = 'FirstLine'  # Reduce verbose output
                ShowPassedTests     = $false  # Only show failures for speed
            }

            # Run settings
            Run      = @{
                PassThru      = $true  # Return result object
                Exit          = $false     # Don't exit PowerShell after tests
                TestExtension = '.Tests.ps1'  # Test file extension
            }

            # Filter settings - control which tests to run
            # NOTE: To run ALL tests, leave Tag empty or set to @()
            Filter   = @{
                Tag        = @()  # Empty array = run all tests regardless of tags
                ExcludeTag = @('Skip', 'Disabled')  # Only exclude explicitly disabled tests
            }

            # Should assertion settings
            Should   = @{
                ErrorAction = 'Stop'  # Stop, Continue, SilentlyContinue
            }
        }

        # PSScriptAnalyzer settings
        PSScriptAnalyzer   = @{
            Enabled      = $true
            OutputPath   = './library/tests/analysis'

            # Select which rules to run
            IncludeRules = @('*')

            # Exclude specific rules
            ExcludeRules = @(
                'PSAvoidUsingWriteHost'  # We use Write-Host for UI output
                'PSUseShouldProcessForStateChangingFunctions'  # Not all functions need ShouldProcess
            )

            # Severity levels to check
            Severity     = @('Error', 'Warning', 'Information')

            # Rule-specific settings
            Rules        = @{
                PSProvideCommentHelp  = @{
                    Enable       = $true
                    ExportedOnly = $false
                    BlockComment = $true
                    Placement    = "begin"
                }

                PSUseCompatibleSyntax = @{
                    Enable         = $true
                    TargetVersions = @('7.0')
                }
            }
        }

        # Code coverage
        CodeCoverage       = @{
            Enabled        = $true
            OutputPath     = './library/tests/coverage'
            Format         = @('JaCoCo', 'Cobertura')
            MinimumPercent = 80
            ExcludePaths   = @('*/tests/*', '*/legacy-to-migrate/*', '*/library/examples/*')
        }

        # Test output
        OutputPath         = './library/tests/results'
        OutputFormat       = @('NUnitXml', 'JUnitXml')
        GenerateReport     = $true
        OpenReportAfterRun = $false
    }

    Features = @{
        # Testing and quality tools
        Testing        = @{
            Pester            = @{
                Enabled       = $true  # Always enabled for Standard+ profiles
                Version       = '5.0.0+'
                InstallScript = '0400'
                Required      = $true
                Platforms     = @('Windows', 'Linux', 'macOS')
            }
            PSScriptAnalyzer  = @{
                Enabled       = $true  # Always enabled for Standard+ profiles
                Version       = '1.20.0+'
                InstallScript = '0400'
                Required      = $true
                Platforms     = @('Windows', 'Linux', 'macOS')
            }
            Act               = @{
                Enabled       = $false
                InstallScript = '0442'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Description   = 'Local GitHub Actions testing with nektos/act'
            }
            PowerShellYaml    = @{
                Enabled       = $false
                InstallScript = '0443'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Description   = 'YAML parsing for workflow validation'
            }
            QualityValidation = @{
                Enabled       = $true  # Always enabled for Standard+ profiles
                InstallScript = '0420'
                Required      = $false
                Platforms     = @('Windows', 'Linux', 'macOS')
                Configuration = @{
                    MinimumScore     = 70  # Minimum quality score required (0-100)
                    FailOnWarnings   = $false  # Fail validation on warnings
                    SkipChecks       = @()  # Checks to skip: ErrorHandling, Logging, TestCoverage, UIIntegration, GitHubActions, PSScriptAnalyzer
                    ReportFormat     = 'Text'  # Text, HTML, JSON
                    ReportPath       = './library/reports/quality'
                    AutoCreateIssues = $true  # Create GitHub issues for failures in CI
                    IssueLabels      = @('quality-validation', 'automated', 'needs-fix')
                }
            }
            AutoTestGenerator = @{
                Enabled       = $true  # Automatic test generation system
                InstallScript = '0950'
                Required      = $false
                Platforms     = @('Windows', 'Linux', 'macOS')
                Description   = '100% automatic test generation with three-tier functional validation'
                Configuration = @{
                    Mode                  = 'Full'  # Full, Quick, Changed, Watch
                    Force                 = $false  # Regenerate existing tests
                    RunTests              = $false  # Run tests after generation
                    AutoGenerate          = $true   # Auto-generate on script changes
                    TestsPath             = './tests'
                    CoverageTarget        = 100     # Target test coverage percentage
                    # NEW: Three-tier validation integration
                    EnableFunctionalTests = $true   # Enable functional test generation
                    EnableThreeTierValidation = $true  # Enable AST→PSSA→Pester validation
                    FunctionalTemplates   = './aithercore/testing/FunctionalTestTemplates.psm1'
                    ValidationFramework   = './aithercore/testing/ThreeTierValidation.psm1'
                    PlaybookFramework     = './aithercore/testing/PlaybookTestFramework.psm1'
                    # Test frameworks to include in generated tests
                    TestFrameworks        = @(
                        'FunctionalTestFramework'
                        'PlaybookTestFramework'
                        'ThreeTierValidation'
                    )
                    # Quality thresholds
                    MinimumQualityScore   = 70      # Minimum quality score (0-100)
                    MaxComplexity         = 20      # Maximum cyclomatic complexity
                    MaxNestingDepth       = 5       # Maximum nesting depth
                }
            }
        }
    }
}
