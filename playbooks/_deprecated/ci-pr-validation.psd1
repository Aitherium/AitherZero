@{
    Name = "ci-pr-validation"
    Description = "Complete PR Validation Pipeline - Build, Test, and Report"
    Version = "1.0.0"
    Author = "AitherZero"
    Tags = @("ci", "pr", "validation", "build", "test", "report")
    
    # Complete PR validation pipeline
    Sequence = @(
        # Phase 1: Build
        @{
            Script = "0407"
            Description = "Syntax validation"
            Parameters = @{ All = $true }
            ContinueOnError = $false
            Timeout = 120
            Phase = "build"
        },
        @{
            Script = "0902"
            Description = "Create deployable package"
            Parameters = @{
                PackageFormat = "Both"
                IncludeTests = $false
                OnlyRuntime = $true
            }
            ContinueOnError = $false
            Timeout = 300
            Phase = "build"
        },
        
        # Phase 2: Test
        @{
            Script = "0402"
            Description = "Unit tests with coverage"
            Parameters = @{
                CodeCoverage = $true
                OutputFormat = "NUnitXml"
            }
            ContinueOnError = $true
            Timeout = 600
            Phase = "test"
        },
        @{
            Script = "0404"
            Description = "Code quality analysis"
            Parameters = @{
                Fast = $false
                ReportPath = "AitherZero/library/reports/quality-analysis.json"
                CompareBranch = $env:GITHUB_BASE_REF
            }
            ContinueOnError = $true
            Timeout = 300
            Phase = "test"
        },
        
        # Phase 3: Report
        @{
            Script = "0513"
            Description = "Generate PR changelog"
            Parameters = @{
                BaseBranch = $env:GITHUB_BASE_REF
                HeadBranch = $env:GITHUB_HEAD_REF
                OutputPath = "AitherZero/library/reports/CHANGELOG-PR$($env:PR_NUMBER).md"
            }
            ContinueOnError = $false
            Timeout = 120
            Phase = "report"
        },
        @{
            Script = "0512"
            Description = "Generate dashboard"
            Parameters = @{
                OutputPath = "AitherZero/library/reports"
                Format = "All"
                PRNumber = $env:PR_NUMBER
                BaseBranch = $env:GITHUB_BASE_REF
                HeadBranch = $env:GITHUB_HEAD_REF
            }
            ContinueOnError = $false
            Timeout = 600
            Phase = "report"
        },
        @{
            Script = "0519"
            Description = "Generate PR comment"
            Parameters = @{
                BuildMetadataPath = "AitherZero/library/reports/build-metadata.json"
                DashboardPath = "AitherZero/library/reports/dashboard.html"
                ChangelogPath = "AitherZero/library/reports/CHANGELOG-PR$($env:PR_NUMBER).md"
                OutputPath = "AitherZero/library/reports/pr-comment.md"
            }
            ContinueOnError = $false
            Timeout = 60
            Phase = "report"
        }
    )
    
    Variables = @{
        CI = $env:CI
        AITHERZERO_CI = "true"
        AITHERZERO_NONINTERACTIVE = "true"
        PR_NUMBER = $env:PR_NUMBER
        GITHUB_BASE_REF = $env:GITHUB_BASE_REF
        GITHUB_HEAD_REF = $env:GITHUB_HEAD_REF
    }
    
    Options = @{
        Parallel = $false
        MaxConcurrency = 1
        StopOnError = $false
        CaptureOutput = $true
        GenerateSummary = $true
        SummaryFormat = "JSON"
        SummaryPath = "AitherZero/library/reports/validation-summary.json"
    }
    
    SuccessCriteria = @{
        RequireAllSuccess = $false
        MinimumSuccessCount = 4
        CriticalScripts = @("0407", "0902", "0513", "0512", "0519")
    }
    
    Artifacts = @{
        Required = @(
            "AitherZero/library/reports/pr-comment.md",
            "AitherZero/library/reports/dashboard.html",
            "AitherZero/library/reports/CHANGELOG-PR*.md"
        )
        Optional = @(
            "AitherZero-*-runtime.zip",
            "AitherZero/library/reports/quality-analysis.json",
            "AitherZero/library/tests/results/*.xml"
        )
    }
    
    Reporting = @{
        GenerateReport = $true
        IncludeTimings = $true
        IncludeArtifacts = $true
        ReportPath = "AitherZero/library/reports/validation-report.md"
    }
}

