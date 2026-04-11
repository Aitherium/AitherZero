@{
    Name = "ci-release"
    Description = "Release Pipeline - Validation, Package Creation, Publishing"
    Version = "1.0.0"
    Author = "AitherZero"
    Tags = @("ci", "release", "package", "publish")
    
    Sequence = @(
        # Pre-release validation
        @{
            Script = "0407"
            Description = "Syntax validation"
            Parameters = @{ All = $true }
            ContinueOnError = $false
            Timeout = 120
            Phase = "validate"
        },
        @{
            Script = "0950"
            Description = "Module architecture validation"
            Parameters = @{ Fast = $true }
            ContinueOnError = $false
            Timeout = 300
            Phase = "validate"
        },
        @{
            Script = "0402"
            Description = "Core functionality tests"
            Parameters = @{}
            ContinueOnError = $true
            Timeout = 600
            Phase = "validate"
        },
        @{
            Script = "0404"
            Description = "Code quality analysis"
            Parameters = @{}
            ContinueOnError = $true
            Timeout = 300
            Phase = "validate"
        },
        
        # Package creation
        @{
            Script = "0902"
            Description = "Create release package"
            Parameters = @{
                PackageFormat = "Both"
                IncludeTests = $false
                OnlyRuntime = $true
            }
            ContinueOnError = $false
            Timeout = 300
            Phase = "package"
        },
        
        # Version and metadata
        @{
            Script = "0515"
            Description = "Generate release metadata"
            Parameters = @{
                OutputPath = "AitherZero/library/reports/release-metadata.json"
                IncludeGitInfo = $true
                IncludeEnvironmentInfo = $true
            }
            ContinueOnError = $false
            Timeout = 60
            Phase = "metadata"
        }
    )
    
    Variables = @{
        CI = $env:CI
        AITHERZERO_CI = "true"
        AITHERZERO_NONINTERACTIVE = "true"
        RELEASE_VERSION = $env:RELEASE_VERSION
        GITHUB_REF_NAME = $env:GITHUB_REF_NAME
        GITHUB_SHA = $env:GITHUB_SHA
    }
    
    Options = @{
        Parallel = $false
        MaxConcurrency = 1
        StopOnError = $true
        CaptureOutput = $true
        GenerateSummary = $true
        SummaryFormat = "JSON"
        SummaryPath = "AitherZero/library/reports/release-summary.json"
    }
    
    SuccessCriteria = @{
        RequireAllSuccess = $false
        MinimumSuccessCount = 4
        CriticalScripts = @("0407", "0950", "0902", "0515")
    }
    
    Artifacts = @{
        Required = @(
            "AitherZero/library/reports/release-metadata.json",
            "AitherZero-*-runtime.zip",
            "AitherZero-*-runtime.tar.gz"
        )
        Optional = @(
            "AitherZero/library/reports/release-summary.json"
        )
    }
    
    Reporting = @{
        GenerateReport = $true
        IncludeTimings = $true
        IncludeArtifacts = $true
        ReportPath = "AitherZero/library/reports/release-report.md"
    }
}

