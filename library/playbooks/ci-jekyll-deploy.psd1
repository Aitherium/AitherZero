@{
    Name = "ci-jekyll-deploy"
    Description = "Jekyll Site Deployment to GitHub Pages"
    Version = "1.0.0"
    Author = "AitherZero"
    Tags = @("ci", "jekyll", "github-pages", "deployment", "documentation")
    
    Sequence = @(
        # Prepare documentation
        @{
            Script = "0521"
            Description = "Documentation coverage analysis"
            Parameters = @{
                IncludeMetrics = $true
                GenerateReport = $true
            }
            ContinueOnError = $true
            Timeout = 180
            Phase = "prepare"
        },
        
        # Generate documentation indexes if needed
        @{
            Script = "0520"
            Description = "Generate documentation indexes"
            Parameters = @{
                OutputPath = "AitherZero/library/docs"
            }
            ContinueOnError = $true
            Timeout = 120
            Phase = "prepare"
        }
    )
    
    Variables = @{
        CI = $env:CI
        AITHERZERO_CI = "true"
        AITHERZERO_NONINTERACTIVE = "true"
        BRANCH_NAME = $env:GITHUB_REF_NAME
        GITHUB_SHA = $env:GITHUB_SHA
        GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY
        BASE_URL = $env:BASE_URL
    }
    
    Options = @{
        Parallel = $false
        MaxConcurrency = 1
        StopOnError = $false
        CaptureOutput = $true
        GenerateSummary = $true
        SummaryFormat = "JSON"
        SummaryPath = "AitherZero/library/reports/jekyll-deploy-summary.json"
    }
    
    SuccessCriteria = @{
        RequireAllSuccess = $false
        MinimumSuccessCount = 0
    }
    
    Artifacts = @{
        Required = @()
        Optional = @(
            "AitherZero/library/reports/jekyll-deploy-summary.json"
        )
    }
    
    Reporting = @{
        GenerateReport = $true
        IncludeTimings = $true
        IncludeArtifacts = $true
        ReportPath = "AitherZero/library/reports/jekyll-deploy-report.md"
    }
    
    # Note: Actual Jekyll build and deployment is handled by GitHub Actions
    # This playbook prepares documentation and generates metadata
}

