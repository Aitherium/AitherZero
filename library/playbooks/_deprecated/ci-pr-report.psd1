@{
    Name = "ci-pr-report"
    Description = "PR Report Phase - Dashboard, Changelog, PR Comment"
    Version = "1.0.0"
    Author = "AitherZero"
    Tags = @("ci", "pr", "report", "dashboard", "changelog")
    
    Sequence = @(
        @{
            Script = "0513"
            Description = "Generate PR changelog"
            Parameters = @{
                BaseBranch = $env:GITHUB_BASE_REF
                HeadBranch = $env:GITHUB_HEAD_REF
                OutputPath = "AitherZero/library/reports/CHANGELOG-PR$($env:PR_NUMBER).md"
                IncludeIssueLinks = $true
                CategorizeCommits = $true
            }
            ContinueOnError = $false
            Timeout = 120
            Phase = "changelog"
        },
        @{
            Script = "0512"
            Description = "Generate comprehensive dashboard"
            Parameters = @{
                OutputPath = "AitherZero/library/reports"
                Format = "All"
                PRNumber = $env:PR_NUMBER
                BaseBranch = $env:GITHUB_BASE_REF
                HeadBranch = $env:GITHUB_HEAD_REF
                IncludePRContext = $true
                IncludeDiffAnalysis = $true
                IncludeChangelog = $true
                IncludeTestResults = $true
            }
            ContinueOnError = $false
            Timeout = 600
            Phase = "dashboard"
        },
        @{
            Script = "0519"
            Description = "Generate PR comment"
            Parameters = @{
                BuildMetadataPath = "AitherZero/library/reports/build-metadata.json"
                AnalysisSummaryPath = "AitherZero/library/reports/test-summary.json"
                DashboardPath = "AitherZero/library/reports/dashboard.html"
                ChangelogPath = "AitherZero/library/reports/CHANGELOG-PR$($env:PR_NUMBER).md"
                OutputPath = "AitherZero/library/reports/pr-comment.md"
                IncludeDeploymentInstructions = $true
            }
            ContinueOnError = $false
            Timeout = 60
            Phase = "pr-comment"
        }
    )
    
    Variables = @{
        CI = $env:CI
        AITHERZERO_CI = "true"
        AITHERZERO_NONINTERACTIVE = "true"
        REPORT_PHASE = "ci-pr-report"
        PR_NUMBER = $env:PR_NUMBER
        GITHUB_BASE_REF = $env:GITHUB_BASE_REF
        GITHUB_HEAD_REF = $env:GITHUB_HEAD_REF
        GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY
        GITHUB_SHA = $env:GITHUB_SHA
        GITHUB_RUN_NUMBER = $env:GITHUB_RUN_NUMBER
    }
    
    Options = @{
        Parallel = $false
        MaxConcurrency = 1
        StopOnError = $false
        CaptureOutput = $true
        GenerateSummary = $true
        SummaryFormat = "JSON"
        SummaryPath = "AitherZero/library/reports/report-summary.json"
    }
    
    SuccessCriteria = @{
        RequireAllSuccess = $false
        MinimumSuccessCount = 3
        CriticalScripts = @("0513", "0512", "0519")
    }
    
    Artifacts = @{
        Required = @(
            "AitherZero/library/reports/dashboard.html",
            "AitherZero/library/reports/CHANGELOG-PR*.md",
            "AitherZero/library/reports/pr-comment.md"
        )
        Optional = @(
            "AitherZero/library/reports/dashboard.json",
            "AitherZero/library/reports/dashboard.md"
        )
    }
    
    Reporting = @{
        GenerateReport = $true
        IncludeTimings = $true
        IncludeArtifacts = $true
        ReportPath = "AitherZero/library/reports/report-summary.md"
    }
}

