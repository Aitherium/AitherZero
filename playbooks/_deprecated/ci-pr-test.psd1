@{
    Name = "ci-pr-test"
    Description = "PR Test Phase - Tests and Quality Analysis"
    Version = "1.0.0"
    Author = "AitherZero"
    Tags = @("ci", "pr", "test", "quality", "analysis")
    
    Sequence = @(
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
            Parallel = $true
            Group = 1
        },
        @{
            Script = "0403"
            Description = "Integration tests"
            Parameters = @{
                OutputFormat = "NUnitXml"
            }
            ContinueOnError = $true
            Timeout = 600
            Phase = "test"
            Parallel = $true
            Group = 1
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
            Phase = "quality"
            Parallel = $true
            Group = 2
        },
        @{
            Script = "0514"
            Description = "PR diff and impact analysis"
            Parameters = @{
                BaseBranch = $env:GITHUB_BASE_REF
                HeadBranch = $env:GITHUB_HEAD_REF
                OutputPath = "AitherZero/library/reports/diff-analysis.json"
            }
            ContinueOnError = $false
            Timeout = 180
            Phase = "diff"
        }
    )
    
    Variables = @{
        CI = $env:CI
        AITHERZERO_CI = "true"
        AITHERZERO_NONINTERACTIVE = "true"
        TEST_PHASE = "ci-pr-test"
        PR_NUMBER = $env:PR_NUMBER
        GITHUB_BASE_REF = $env:GITHUB_BASE_REF
        GITHUB_HEAD_REF = $env:GITHUB_HEAD_REF
    }
    
    Options = @{
        Parallel = $true
        MaxConcurrency = 2
        StopOnError = $false
        CaptureOutput = $true
        GenerateSummary = $true
        SummaryFormat = "JSON"
        SummaryPath = "AitherZero/library/reports/test-summary.json"
    }
    
    SuccessCriteria = @{
        RequireAllSuccess = $false
        MinimumSuccessCount = 2
        AllowedFailures = @("0402", "0403")
    }
    
    Artifacts = @{
        Required = @(
            "AitherZero/library/reports/diff-analysis.json"
        )
        Optional = @(
            "AitherZero/library/tests/results/*.xml",
            "AitherZero/library/tests/coverage/**",
            "AitherZero/library/reports/quality-analysis.json"
        )
    }
    
    Reporting = @{
        GenerateReport = $true
        IncludeTimings = $true
        IncludeArtifacts = $true
        IncludeFailures = $true
        ReportPath = "AitherZero/library/reports/test-report.md"
    }
}

