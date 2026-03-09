@{
    Name = "ci-branch-ecosystem"
    Description = "Complete Branch Ecosystem - Build, Test, Package, Docker, Dashboard, Reports"
    Version = "1.0.0"
    Author = "AitherZero"
    Tags = @("ci", "branch", "ecosystem", "build", "test", "docker", "dashboard", "reporting")
    
    # Complete branch ecosystem pipeline
    Sequence = @(
        # Phase 1: Build & Validation
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
            Description = "Create deployable packages"
            Parameters = @{
                PackageFormat = "Both"
                IncludeTests = $false
                OnlyRuntime = $true
            }
            ContinueOnError = $false
            Timeout = 300
            Phase = "build"
        },
        @{
            Script = "0515"
            Description = "Generate build metadata"
            Parameters = @{
                OutputPath = "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/build-metadata.json"
                IncludeGitInfo = $true
                IncludeEnvironmentInfo = $true
                IncludePRInfo = $true
            }
            ContinueOnError = $false
            Timeout = 60
            Phase = "build"
        },
        
        # Phase 2: Testing (parallel execution)
        @{
            Script = "0402"
            Description = "Unit tests with coverage"
            Parameters = @{
                CodeCoverage = $true
                OutputFormat = "NUnitXml"
                OutputPath = "AitherZero/library/tests/results/$($env:GITHUB_REF_NAME)"
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
                OutputPath = "AitherZero/library/tests/results/$($env:GITHUB_REF_NAME)"
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
                ReportPath = "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/quality-analysis.json"
                CompareBranch = if ($env:GITHUB_BASE_REF) { $env:GITHUB_BASE_REF } else { "main" }
            }
            ContinueOnError = $true
            Timeout = 300
            Phase = "test"
            Parallel = $true
            Group = 1
        },
        
        # Phase 3: Comprehensive Reporting & Dashboard (using reporting module)
        @{
            Script = "0516"
            Description = "Generate comprehensive dashboard with reporting module"
            Parameters = @{
                BranchName = $env:GITHUB_REF_NAME
                OutputPath = "AitherZero/library/reports/$($env:GITHUB_REF_NAME)"
                Format = "All"
                IncludeTestResults = $true
                IncludeBuildArtifacts = $true
                IncludeDockerInfo = $true
                IncludeQualityMetrics = $true
                DockerRegistry = $env:DOCKER_REGISTRY ?? "ghcr.io"
                DockerImageTag = $env:GITHUB_REF_NAME
            }
            ContinueOnError = $false
            Timeout = 600
            Phase = "dashboard"
        },
        @{
            Script = "0527"
            Description = "Generate branch index page for GitHub Pages"
            Parameters = @{
                BranchName = $env:GITHUB_REF_NAME
                OutputPath = "AitherZero/library/reports/$($env:GITHUB_REF_NAME)"
                IncludeDashboardLinks = $true
                IncludeDockerLinks = $true
                IncludePackageLinks = $true
            }
            ContinueOnError = $false
            Timeout = 120
            Phase = "dashboard"
        },
        
        # Phase 4: Test Results Aggregation
        @{
            Script = "0517"
            Description = "Aggregate test and analysis results"
            Parameters = @{
                SourcePath = "AitherZero/library/reports/$($env:GITHUB_REF_NAME)"
                OutputPath = "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/analysis-summary.json"
                IncludeComparison = $true
                GenerateRecommendations = $true
            }
            ContinueOnError = $true
            Timeout = 120
            Phase = "report"
        }
    )
    
    Variables = @{
        CI = $env:CI
        AITHERZERO_CI = "true"
        AITHERZERO_NONINTERACTIVE = "true"
        BRANCH_NAME = $env:GITHUB_REF_NAME
        GITHUB_SHA = $env:GITHUB_SHA
        GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY
        GITHUB_BASE_REF = $env:GITHUB_BASE_REF
        GITHUB_HEAD_REF = $env:GITHUB_HEAD_REF
        PR_NUMBER = $env:PR_NUMBER
        DOCKER_REGISTRY = $env:DOCKER_REGISTRY ?? "ghcr.io"
        DOCKER_IMAGE_TAG = $env:GITHUB_REF_NAME
    }
    
    Options = @{
        Parallel = $true
        MaxConcurrency = 3
        StopOnError = $false
        CaptureOutput = $true
        GenerateSummary = $true
        SummaryFormat = "JSON"
        SummaryPath = "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/ecosystem-summary.json"
    }
    
    SuccessCriteria = @{
        RequireAllSuccess = $false
        MinimumSuccessCount = 5
        CriticalScripts = @("0407", "0902", "0515", "0516", "0527")
    }
    
    Artifacts = @{
        Required = @(
            "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/dashboard.html",
            "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/build-metadata.json",
            "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/index.html",
            "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/metrics.json"
        )
        Optional = @(
            "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/dashboard.json",
            "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/dashboard.md",
            "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/metrics.json",
            "AitherZero/library/tests/results/$($env:GITHUB_REF_NAME)/*.xml",
            "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/quality-analysis.json",
            "AitherZero-*-runtime.zip",
            "AitherZero-*-runtime.tar.gz"
        )
        Docker = @{
            Enabled = $true
            Registry = $env:DOCKER_REGISTRY ?? "ghcr.io"
            ImageName = $env:GITHUB_REPOSITORY
            Tag = $env:GITHUB_REF_NAME
            Platforms = @("linux/amd64", "linux/arm64")
        }
    }
    
    Reporting = @{
        GenerateReport = $true
        IncludeTimings = $true
        IncludeArtifacts = $true
        IncludeDockerInfo = $true
        IncludeTestResults = $true
        IncludeQualityMetrics = $true
        ReportPath = "AitherZero/library/reports/$($env:GITHUB_REF_NAME)/ecosystem-report.md"
    }
}

