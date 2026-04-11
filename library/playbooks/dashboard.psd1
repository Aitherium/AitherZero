@{
    Name = "dashboard"
    Description = "Dashboard generation with sequential metrics collection"
    Version = "1.0.0"

    Variables = @{
        OutputDir = "AitherZero/library/reports/dashboard"
        MetricsDir = "AitherZero/library/reports/metrics"
    }

    # Common configuration for all metrics collection scripts (0520-0524)
    # ContinueOnError=$true: Allow dashboard generation even if individual metric collection fails
    # Timeout=60: Each collection script has 60 seconds to complete
    # These are identical because all metrics are equally important but non-critical

    Sequence = @(
        # Generate comprehensive project report
        @{
            Script = "0510"
            Description = "Generate project report"
            Parameters = @{
                Format = "All"
            }
            ContinueOnError = $false
            Timeout = 300
        },

        # Generate web dashboard
        @{
            Script = "0515"
            Description = "Generate web dashboard"
            Parameters = @{
                OutputPath = "public"
            }
            ContinueOnError = $false
            Timeout = 120
        }
    )

    Options = @{
        Parallel = $false
        MaxConcurrency = 1
        StopOnError = $true
        CaptureOutput = $true
    }

    Metadata = @{
        Author = "Aitherium"
        Created = "2025-01-10"
        Tags = @("dashboard", "reporting", "metrics", "visualization")
        EstimatedDuration = "420s"
    }
}
