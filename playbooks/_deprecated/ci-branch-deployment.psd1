@{
    Name = "ci-branch-deployment"
    Description = "Branch Deployment Pipeline - Test, Build, Dashboard"
    Version = "1.0.0"
    Author = "AitherZero"
    Tags = @("ci", "deployment", "branch", "docker", "dashboard")
    
    Sequence = @(
        # Test execution
        @{
            Script = "0402"
            Description = "Unit tests"
            Parameters = @{
                CodeCoverage = $true
                OutputFormat = "NUnitXml"
            }
            ContinueOnError = $true
            Timeout = 600
            Phase = "test"
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
        },
        
        # Build Docker image (handled by workflow, but tracked here)
        @{
            Script = "0515"
            Description = "Generate build metadata"
            Parameters = @{
                OutputPath = "library/reports/build-metadata.json"
                IncludeGitInfo = $true
                IncludeEnvironmentInfo = $true
            }
            ContinueOnError = $false
            Timeout = 60
            Phase = "build"
        },
        
        # Dashboard generation
        @{
            Script = "0512"
            Description = "Generate dashboard"
            Parameters = @{
                OutputPath = "library/reports"
                Format = "All"
                BaseBranch = $env:GITHUB_REF_NAME
                IncludeTestResults = $true
                IncludeBuildArtifacts = $true
            }
            ContinueOnError = $false
            Timeout = 600
            Phase = "dashboard"
        }
    )
    
    Variables = @{
        CI = $env:CI
        AITHERZERO_CI = "true"
        AITHERZERO_NONINTERACTIVE = "true"
        BRANCH_NAME = $env:GITHUB_REF_NAME
        GITHUB_SHA = $env:GITHUB_SHA
        GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY
    }
    
    Options = @{
        Parallel = $true
        MaxConcurrency = 2
        StopOnError = $false
        CaptureOutput = $true
        GenerateSummary = $true
        SummaryFormat = "JSON"
        SummaryPath = "library/reports/deployment-summary.json"
    }
    
    SuccessCriteria = @{
        RequireAllSuccess = $false
        MinimumSuccessCount = 2
        CriticalScripts = @("0512")
    }
    
    Artifacts = @{
        Required = @(
            "library/reports/dashboard.html",
            "library/reports/build-metadata.json"
        )
        Optional = @(
            "library/tests/results/*.xml",
            "library/reports/deployment-summary.json"
        )
    }
    
    Reporting = @{
        GenerateReport = $true
        IncludeTimings = $true
        IncludeArtifacts = $true
        ReportPath = "library/reports/deployment-report.md"
    }
}

