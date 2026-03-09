@{
    Name = "benchmark-gpu"
    Description = "Run GPU performance benchmarks and save results for trend analysis"
    Version = "1.0.0"
    Author = "AitherZero"
    
    # Default parameters
    Parameters = @{
        Quick = $false
        SaveResults = $true
        GenerateReport = $true
    }
    
    Steps = @(
        @{
            Name = "Start AitherAccel"
            Script = "0764_Start-AitherAccel"
            Description = "Start GPU optimization service"
            Parameters = @{}
            ContinueOnError = $false
        },
        @{
            Name = "Run GPU Tests"
            Description = "Execute GPU benchmark Pester tests"
            Command = "Invoke-Pester -Path 'AitherZero/tests/Unit/AitherZero.GPU.Tests.ps1' -Output Detailed -PassThru"
            ContinueOnError = $true
        },
        @{
            Name = "Generate Benchmark Report"
            Script = "0510_Generate-ProjectReport"
            Description = "Generate project report with benchmark data"
            Parameters = @{
                ShowAll = '$true'
            }
            Condition = '$GenerateReport'
        }
    )
    
    # Post-run actions
    OnSuccess = @{
        Message = "GPU benchmarks completed successfully. Check AitherZero/benchmarks/history/ for results."
    }
    
    OnFailure = @{
        Message = "Some GPU benchmarks failed. Review output for details."
    }
}
