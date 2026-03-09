@{
    Name = 'diagnose-ci'
    Description = 'Diagnose and report on CI workflow failures'
    Version = '1.0.0'
    Author = 'AitherZero'
    
    Sequence = @(
        @{
            Script = '0531'
            Description = 'Fetch and analyze workflow run failures'
            Parameters = @{
                List = $true
                Status = 'failure'
                Limit = 10
            }
            ContinueOnError = $true
            Timeout = 120
            Phase = 'diagnostics'
        }
    )
    
    Variables = @{
        CI = $env:CI
        AITHERZERO_CI = 'true'
        OutputFormat = 'Both'
        Detailed = $true
        IncludeJobs = $true
        IncludeLogs = $false  # Set to true for full log download
    }
    
    Options = @{
        Parallel = $false
        MaxConcurrency = 1
        StopOnError = $false  # Always succeed, this is diagnostic
        CaptureOutput = $true
        GenerateSummary = $true
        SummaryFormat = 'JSON'
        SummaryPath = 'library/reports/ci-diagnostics-summary.json'
    }
    
    SuccessCriteria = @{
        RequireAllSuccess = $false
        MinimumSuccessCount = 0  # Always succeed, this is diagnostic
    }
    
    Reporting = @{
        GenerateReport = $true
        IncludeTimings = $true
        IncludeMetrics = $true
        ReportPath = 'library/reports/ci-diagnostics-report.md'
    }
}
