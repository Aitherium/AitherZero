<#
.SYNOPSIS
    Runs a benchmark on a trained model.

.DESCRIPTION
    Evaluates model quality using the AitherTrainer benchmark API.
    Measures accuracy, latency, and cost efficiency.

.PARAMETER Model
    Model to benchmark (e.g., ollama/qwen2.5:7b)

.PARAMETER JudgeModel
    Model to use for judging quality. Default: gemini-2.0-flash

.PARAMETER TestCases
    Number of test cases to run. Default: 50

.PARAMETER BenchmarkType
    Type of benchmark: quality, speed, inference

.PARAMETER ShowOutput
    Display verbose output during execution.

.EXAMPLE
    ./0783_Benchmark-Model.ps1 -Model "ollama/qwen2.5:7b" -ShowOutput

.NOTES
    Script ID: 0783
    Category: AI Services / Benchmarking
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Model = "ollama/qwen2.5:7b",
    
    [Parameter()]
    [string]$JudgeModel = "gemini-2.0-flash",
    
    [Parameter()]
    [int]$TestCases = 50,
    
    [Parameter()]
    [ValidateSet("quality", "speed", "inference")]
    [string]$BenchmarkType = "quality",
    
    [Parameter()]
    [switch]$Wait,
    
    [Parameter()]
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"

$TrainerUrl = "http://localhost:8107"

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    if ($ShowOutput) {
        $color = switch ($Level) {
            "Success" { "Green" }
            "Warning" { "Yellow" }
            "Error"   { "Red" }
            default   { "Cyan" }
        }
        Write-Host "[$Level] $Message" -ForegroundColor $color
    }
}

# Check if trainer is running
try {
    $health = Invoke-RestMethod -Uri "$TrainerUrl/health" -TimeoutSec 5
    Write-Log "AitherTrainer is running" -Level Information
} catch {
    Write-Log "AitherTrainer is not running. Start it with: 0779_Start-AitherTrainer.ps1" -Level Error
    exit 1
}

$benchmarkRequest = @{
    model = $Model
    judge_model = $JudgeModel
    test_cases = $TestCases
    benchmark_type = $BenchmarkType
}

Write-Log "Starting benchmark..." -Level Information
Write-Log "  Model: $Model" -Level Information
Write-Log "  Judge: $JudgeModel" -Level Information
Write-Log "  Test Cases: $TestCases" -Level Information

try {
    $body = $benchmarkRequest | ConvertTo-Json
    $response = Invoke-RestMethod -Uri "$TrainerUrl/api/benchmark/run" -Method Post -Body $body -ContentType "application/json"
    
    $benchmarkId = $response.id
    Write-Log "Benchmark started: $benchmarkId" -Level Success
    
    if ($Wait) {
        Write-Log "Waiting for benchmark to complete..." -Level Information
        
        do {
            Start-Sleep -Seconds 3
            $result = Invoke-RestMethod -Uri "$TrainerUrl/api/benchmark/$benchmarkId" -TimeoutSec 10
        } while ($result.status -eq "running")
        
        if ($result.status -eq "completed") {
            Write-Log "Benchmark completed!" -Level Success
            Write-Log "  Pass Rate: $([math]::Round($result.pass_rate * 100, 1))%" -Level Information
            Write-Log "  Avg Latency: $($result.avg_latency_ms)ms" -Level Information
            Write-Log "  Cost: `$$([math]::Round($result.cost, 4))" -Level Information
        }
    }
    
    @{
        Success = $true
        BenchmarkId = $benchmarkId
        Status = $response.status
    } | ConvertTo-Json -Compress
    
} catch {
    Write-Log "Failed to run benchmark: $_" -Level Error
    exit 1
}
