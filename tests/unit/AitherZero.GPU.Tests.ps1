#Requires -Version 7.0
#Requires -Modules Pester

<#
.SYNOPSIS
    GPU Performance Benchmark Tests for AitherZero
    
.DESCRIPTION
    Comprehensive Pester tests for GPU optimization services:
    - AitherAccel (GPU optimization service)
    - AitherParallel (Parallel reasoning with quantization)
    - AitherWorkingMemory (GPU embedding engine)
    
    These tests validate:
    1. Service availability and health
    2. GPU detection and monitoring
    3. Model selection and quantization
    4. Embedding performance (GPU vs Ollama)
    5. Benchmark collection and storage
    
    POLICY: NO SILENT FALLBACKS
    - Service unavailability is a SKIP (decided at BeforeAll), never a silent pass.
    - All assertions MUST have descriptive failure messages.
    - No try/catch that returns $false silently.
    
.NOTES
    Test Category: Integration
    Dependencies: Running GPU services (AitherAccel, AitherParallel, AitherWorkingMemory)
    
.EXAMPLE
    Invoke-Pester -Path ./AitherZero.GPU.Tests.ps1 -Output Detailed
#>

# Tag: requires running GPU services — skipped in CI
# Invoke with: Invoke-Pester -Path ./AitherZero.GPU.Tests.ps1 -Tag Integration

BeforeAll {
    # Service endpoints
    $script:Endpoints = @{
        AitherAccel = "http://localhost:8103"
        AitherParallel = "http://localhost:8100"
        AitherWorkingMemory = "http://localhost:8095"
    }
    
    # Benchmark storage
    $script:BenchmarkDir = Join-Path $PSScriptRoot "../../benchmarks/history"
    if (-not (Test-Path $script:BenchmarkDir)) {
        New-Item -Path $script:BenchmarkDir -ItemType Directory -Force | Out-Null
    }
    
    # Benchmark results collector
    $script:BenchmarkResults = @{
        Timestamp = Get-Date -Format "o"
        TestRun = (Get-Date -Format "yyyyMMdd_HHmmss")
        Results = @{}
    }
    
    function Test-ServiceAvailable {
        <#
        .SYNOPSIS
            Check if a service health endpoint responds.
            Returns $true/$false — used ONLY for -Skip conditions.
            NEVER use this to silently swallow errors inside a test body.
        #>
        param([string]$Url)
        try {
            $response = Invoke-RestMethod -Uri "$Url/health" -Method Get -TimeoutSec 5 -ErrorAction Stop
            return $true
        } catch {
            Write-Warning "Service not available at $Url — tests will be SKIPPED (not silently passed): $_"
            return $false
        }
    }
    
    function Save-BenchmarkResult {
        param(
            [string]$Category,
            [string]$Name,
            [object]$Result
        )
        if (-not $script:BenchmarkResults.Results.ContainsKey($Category)) {
            $script:BenchmarkResults.Results[$Category] = @{}
        }
        $script:BenchmarkResults.Results[$Category][$Name] = $Result
    }
}

AfterAll {
    # Save all benchmark results to file
    $benchmarkFile = Join-Path $script:BenchmarkDir "$($script:BenchmarkResults.TestRun).json"
    $script:BenchmarkResults | ConvertTo-Json -Depth 10 | Set-Content $benchmarkFile
    Write-Host "`n📊 Benchmark results saved: $benchmarkFile" -ForegroundColor Cyan
}

Describe "AitherAccel GPU Optimization Service" -Tag "GPU", "Integration" {
    
    BeforeAll {
        $script:AccelAvailable = Test-ServiceAvailable -Url $script:Endpoints.AitherAccel
    }
    
    Context "Service Health" {
        
        It "Should be running on port 8103" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/health" -Method Get
            $response.status | Should -BeIn @("healthy", "degraded")
        }
        
        It "Should detect GPU hardware" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/gpu/status" -Method Get
            $response.vram_total_mb | Should -BeGreaterThan 0
            $response.name | Should -Not -BeNullOrEmpty
            
            Save-BenchmarkResult -Category "GPU" -Name "Status" -Result $response
        }
        
        It "Should report VRAM availability" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/gpu/status" -Method Get
            $response.vram_free_mb | Should -BeGreaterThan 0
            $response.vram_used_mb | Should -BeGreaterOrEqual 0
        }
        
        It "Should monitor GPU temperature" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/gpu/status" -Method Get
            $response.temperature_c | Should -BeGreaterThan 0
            $response.temperature_c | Should -BeLessThan 100
        }
    }
    
    Context "Model Registry" {
        
        It "Should list available model profiles" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/models" -Method Get
            $response.models | Should -Not -BeNullOrEmpty
            $response.models.Keys.Count | Should -BeGreaterThan 5
            
            Save-BenchmarkResult -Category "Models" -Name "Registry" -Result @{
                count = $response.models.Keys.Count
                available_vram_mb = $response.available_vram_mb
            }
        }
        
        It "Should have LLM model profiles" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/models" -Method Get
            $llmModels = $response.models.PSObject.Properties | Where-Object { $_.Value.model_type -eq "llm" }
            $llmModels.Count | Should -BeGreaterThan 0
        }
        
        It "Should have embedding model profiles" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/models" -Method Get
            $embedModels = $response.models.PSObject.Properties | Where-Object { $_.Value.model_type -eq "embedding" }
            $embedModels.Count | Should -BeGreaterThan 0
        }
        
        It "Should indicate which models fit in VRAM" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/models" -Method Get
            $fitsVram = $response.models.PSObject.Properties | Where-Object { $_.Value.fits_vram -eq $true }
            $fitsVram.Count | Should -BeGreaterThan 0
        }
    }
    
    Context "Optimization Recommendations" {
        
        It "Should provide optimization recommendations" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/recommendations" -Method Get
            $response.gpu_status | Should -Not -BeNullOrEmpty
            $response.optimization_score | Should -BeGreaterOrEqual 0
            $response.optimization_score | Should -BeLessOrEqual 100
            
            Save-BenchmarkResult -Category "Optimization" -Name "Recommendations" -Result $response
        }
        
        It "Should calculate optimization score" -Skip:(-not $script:AccelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/recommendations" -Method Get
            $response.optimization_score | Should -BeOfType [double]
        }
    }
    
    Context "Task Optimization" {
        
        It "Should optimize for code tasks" -Skip:(-not $script:AccelAvailable) {
            $body = @{ task = "complex code analysis"; prefer_speed = $false } | ConvertTo-Json
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/optimize" -Method Post -Body $body -ContentType "application/json"
            $response.model | Should -Not -BeNullOrEmpty
        }
        
        It "Should optimize for quick tasks" -Skip:(-not $script:AccelAvailable) {
            $body = @{ task = "quick chat"; prefer_speed = $true } | ConvertTo-Json
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/optimize" -Method Post -Body $body -ContentType "application/json"
            $response.model | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "AitherParallel Quantization & GPU Monitoring" -Tag "GPU", "Integration" {
    
    BeforeAll {
        $script:ParallelAvailable = Test-ServiceAvailable -Url $script:Endpoints.AitherParallel
    }
    
    Context "Service Health" {
        
        It "Should be running on port 8100" -Skip:(-not $script:ParallelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherParallel)/health" -Method Get
            $response.status | Should -Be "healthy"
        }
    }
    
    Context "GPU Status" {
        
        It "Should report GPU status" -Skip:(-not $script:ParallelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherParallel)/gpu/status" -Method Get
            $response.vram_total_mb | Should -BeGreaterThan 0
            
            Save-BenchmarkResult -Category "Parallel" -Name "GPUStatus" -Result $response
        }
    }
    
    Context "Model Profiles" {
        
        It "Should list model profiles" -Skip:(-not $script:ParallelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherParallel)/models/profiles" -Method Get
            $response.profiles | Should -Not -BeNullOrEmpty
        }
        
        It "Should recommend models for code tasks" -Skip:(-not $script:ParallelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherParallel)/models/recommend?task_type=code" -Method Get
            $response.model | Should -Not -BeNullOrEmpty
            $response.reason | Should -Not -BeNullOrEmpty
            
            Save-BenchmarkResult -Category "Parallel" -Name "CodeModelRecommendation" -Result $response
        }
        
        It "Should recommend models for chat tasks" -Skip:(-not $script:ParallelAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherParallel)/models/recommend?task_type=chat" -Method Get
            $response.model | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "AitherWorkingMemory GPU Embedding Engine" -Tag "GPU", "Integration", "Embedding" {
    
    BeforeAll {
        $script:MemoryAvailable = Test-ServiceAvailable -Url $script:Endpoints.AitherWorkingMemory
    }
    
    Context "Service Health" {
        
        It "Should be running on port 8095" -Skip:(-not $script:MemoryAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherWorkingMemory)/health" -Method Get
            $response.status | Should -Be "healthy"
        }
    }
    
    Context "GPU Embedding Status" {
        
        It "Should report GPU embedding availability" -Skip:(-not $script:MemoryAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherWorkingMemory)/gpu/embedding/status" -Method Get
            # GPU embedding may or may not be available depending on environment
            $response | Should -Not -BeNullOrEmpty
            
            Save-BenchmarkResult -Category "Embedding" -Name "GPUStatus" -Result $response
        }
    }
    
    Context "Embedding Performance Benchmark" {
        
        It "Should benchmark embedding performance" -Skip:(-not $script:MemoryAvailable) {
            $startTime = Get-Date
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherWorkingMemory)/gpu/embedding/benchmark" `
                -Method Post -Body "50" -ContentType "application/json" -TimeoutSec 120
            $duration = (Get-Date) - $startTime
            
            # Should complete in reasonable time
            $duration.TotalSeconds | Should -BeLessThan 120
            
            Save-BenchmarkResult -Category "Embedding" -Name "Benchmark50" -Result @{
                response = $response
                duration_seconds = $duration.TotalSeconds
            }
        }
        
        It "Should show GPU speedup over Ollama" -Skip:(-not $script:MemoryAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherWorkingMemory)/gpu/embedding/benchmark" `
                -Method Post -Body "100" -ContentType "application/json" -TimeoutSec 180
            
            # MUST have both GPU and Ollama results — no silent fallback
            $response.gpu | Should -Not -BeNullOrEmpty -Because "GPU benchmark results are required"
            $response.ollama | Should -Not -BeNullOrEmpty -Because "Ollama benchmark results are required for comparison"
            $response.speedup | Should -BeGreaterThan 1 -Because "GPU should be faster than Ollama"
            Write-Host "  GPU Speedup: $($response.speedup)x" -ForegroundColor Green
            
            Save-BenchmarkResult -Category "Embedding" -Name "Benchmark100" -Result $response
        }
    }
    
    Context "Batch Embedding" {
        
        It "Should perform batch embedding" -Skip:(-not $script:MemoryAvailable) {
            $body = @{
                texts = @(
                    "First test document for embedding"
                    "Second test document for embedding"
                    "Third test document for embedding"
                )
                use_cache = $false
            } | ConvertTo-Json
            
            $startTime = Get-Date
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherWorkingMemory)/gpu/embedding/batch" `
                -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
            $duration = (Get-Date) - $startTime
            
            $response.count | Should -Be 3
            $response.embeddings.Count | Should -Be 3
            
            Save-BenchmarkResult -Category "Embedding" -Name "BatchSmall" -Result @{
                count = $response.count
                latency_ms = $response.latency_ms
                backend = $response.backend
                duration_seconds = $duration.TotalSeconds
            }
        }
    }
    
    Context "Embedding Stats" {
        
        It "Should track embedding statistics" -Skip:(-not $script:MemoryAvailable) {
            $response = Invoke-RestMethod -Uri "$($script:Endpoints.AitherWorkingMemory)/stats" -Method Get
            $response.embedding | Should -Not -BeNullOrEmpty
            
            Save-BenchmarkResult -Category "Embedding" -Name "Stats" -Result $response.embedding
        }
    }
}

Describe "Cross-Service GPU Integration" -Tag "GPU", "Integration" {
    
    BeforeAll {
        $script:AllServicesAvailable = (Test-ServiceAvailable -Url $script:Endpoints.AitherAccel) -and
                                       (Test-ServiceAvailable -Url $script:Endpoints.AitherParallel) -and
                                       (Test-ServiceAvailable -Url $script:Endpoints.AitherWorkingMemory)
    }
    
    Context "Unified GPU Monitoring" {
        
        It "Should have consistent GPU info across services" -Skip:(-not $script:AllServicesAvailable) {
            $accelGpu = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/gpu/status" -Method Get
            $parallelGpu = Invoke-RestMethod -Uri "$($script:Endpoints.AitherParallel)/gpu/status" -Method Get
            
            # Both should see same GPU
            $accelGpu.name | Should -Be $parallelGpu.name
            $accelGpu.vram_total_mb | Should -Be $parallelGpu.vram_total_mb
        }
    }
    
    Context "End-to-End Workflow" {
        
        It "Should complete full GPU optimization workflow" -Skip:(-not $script:AllServicesAvailable) {
            # 1. Get optimal model recommendation
            $recommendation = Invoke-RestMethod -Uri "$($script:Endpoints.AitherAccel)/optimize" `
                -Method Post -Body '{"task": "analyze code", "prefer_speed": false}' -ContentType "application/json"
            $recommendation.model | Should -Not -BeNullOrEmpty
            
            # 2. Verify embedding service is ready
            $embedStatus = Invoke-RestMethod -Uri "$($script:Endpoints.AitherWorkingMemory)/gpu/embedding/status" -Method Get
            $embedStatus | Should -Not -BeNullOrEmpty
            
            # 3. Get overall system stats
            $parallelStats = Invoke-RestMethod -Uri "$($script:Endpoints.AitherParallel)/stats" -Method Get
            $parallelStats | Should -Not -BeNullOrEmpty
            
            Save-BenchmarkResult -Category "Integration" -Name "FullWorkflow" -Result @{
                model_recommendation = $recommendation
                embedding_status = $embedStatus
                parallel_stats = $parallelStats
            }
        }
    }
}

Describe "Benchmark Data Persistence" -Tag "GPU", "Benchmark" {
    
    Context "Benchmark Storage" {
        
        It "Should have benchmark directory" {
            $script:BenchmarkDir | Should -Exist
        }
        
        It "Should collect benchmark results during tests" {
            $serviceFlags = @(
                (Get-Variable -Name AccelAvailable -Scope Script -ValueOnly -ErrorAction SilentlyContinue),
                (Get-Variable -Name ParallelAvailable -Scope Script -ValueOnly -ErrorAction SilentlyContinue),
                (Get-Variable -Name WorkingMemoryAvailable -Scope Script -ValueOnly -ErrorAction SilentlyContinue),
                (Get-Variable -Name AllServicesAvailable -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
            ) | Where-Object { $_ -is [bool] }

            $hasReachableGpuService = $serviceFlags -contains $true
            $benchmarkCategoryCount = $script:BenchmarkResults.Results.Keys.Count

            if ($hasReachableGpuService) {
                $benchmarkCategoryCount | Should -BeGreaterThan 0
            }
            else {
                $benchmarkCategoryCount | Should -Be 0
            }
        }
    }
}
