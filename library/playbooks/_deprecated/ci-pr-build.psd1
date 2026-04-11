@{
    Name = "ci-pr-build"
    Description = "PR Build Phase - Validation and Package Creation"
    Version = "1.0.0"
    Author = "AitherZero"
    Tags = @("ci", "pr", "build", "package")
    
    Sequence = @(
        @{
            Script = "0407"
            Description = "Syntax validation before build"
            Parameters = @{ All = $true }
            ContinueOnError = $false
            Timeout = 120
            Phase = "validate"
        },
        @{
            Script = "0515"
            Description = "Generate build metadata"
            Parameters = @{
                OutputPath = "AitherZero/library/reports/build-metadata.json"
                IncludePRInfo = $true
                IncludeGitInfo = $true
                IncludeEnvironmentInfo = $true
            }
            ContinueOnError = $false
            Timeout = 60
            Phase = "metadata"
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
            Phase = "package"
        }
    )
    
    Variables = @{
        CI = $env:CI
        AITHERZERO_CI = "true"
        AITHERZERO_NONINTERACTIVE = "true"
        BUILD_PHASE = "ci-pr-build"
        PR_NUMBER = $env:PR_NUMBER
    }
    
    Options = @{
        Parallel = $false
        MaxConcurrency = 1
        StopOnError = $true
        CaptureOutput = $true
        GenerateSummary = $true
        SummaryFormat = "JSON"
        SummaryPath = "AitherZero/library/reports/build-summary.json"
    }
    
    SuccessCriteria = @{
        RequireAllSuccess = $true
        MinimumSuccessCount = 3
    }
    
    Artifacts = @{
        Required = @(
            "AitherZero/library/reports/build-metadata.json",
            "AitherZero-*-runtime.zip"
        )
        Optional = @(
            "AitherZero-*-runtime.tar.gz"
        )
    }
    
    Reporting = @{
        GenerateReport = $true
        IncludeTimings = $true
        IncludeArtifacts = $true
        ReportPath = "AitherZero/library/reports/build-report.md"
    }
}

