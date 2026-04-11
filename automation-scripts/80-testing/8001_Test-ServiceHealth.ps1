#Requires -Version 7.0
<#
.SYNOPSIS
    Tests the health of AitherOS services.

.DESCRIPTION
    Performs health checks on running AitherOS services:
    - HTTP endpoint availability
    - Response time measurements
    - Health endpoint validation
    - Service dependencies

.PARAMETER Services
    Specific services to test. If not specified, tests all running services.

.PARAMETER Timeout
    Timeout in seconds for each health check. Default: 10

.PARAMETER Retries
    Number of retries for failed checks. Default: 3

.PARAMETER Json
    Output results as JSON.

.PARAMETER FailFast
    Stop on first failure. Default: $false

.EXAMPLE
    .\9001_Test-ServiceHealth.ps1
    Test all running services.

.EXAMPLE
    .\9001_Test-ServiceHealth.ps1 -Services Genesis,Chronicle -Json
    Test specific services and output JSON.

.NOTES
    Category: testing
    Dependencies: Running services
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [string[]]$Services,
    [int]$Timeout = 10,
    [int]$Retries = 3,
    [switch]$Json,
    [switch]$FailFast
)

$ErrorActionPreference = 'SilentlyContinue'

# Service definitions with expected health behavior
$ServiceDefinitions = @{
    Genesis      = @{ Port = 8001;  Endpoint = "/health"; ExpectedStatus = "healthy" }
    Chronicle    = @{ Port = 8121;  Endpoint = "/health"; ExpectedStatus = "healthy" }
    Veil         = @{ Port = 3000;  Endpoint = "/api/health"; ExpectedStatus = $null }
    Node         = @{ Port = 8090;  Endpoint = "/health"; ExpectedStatus = "healthy" }
    LLM          = @{ Port = 8100;  Endpoint = "/health"; ExpectedStatus = "healthy" }
    Orchestrator = @{ Port = 8767;  Endpoint = "/health"; ExpectedStatus = "healthy" }
    Mind         = @{ Port = 8125;  Endpoint = "/health"; ExpectedStatus = "healthy" }
    Oracle       = @{ Port = 8104;  Endpoint = "/health"; ExpectedStatus = "healthy" }
    Canvas       = @{ Port = 8108;  Endpoint = "/health"; ExpectedStatus = "healthy" }
    Secrets      = @{ Port = 8111;  Endpoint = "/health"; ExpectedStatus = "healthy" }
    Ollama       = @{ Port = 11434; Endpoint = "/api/tags"; ExpectedStatus = $null }
}

function Test-ServiceHealth {
    param(
        [string]$Name,
        [int]$Port,
        [string]$Endpoint,
        [string]$ExpectedStatus,
        [int]$TimeoutSec,
        [int]$RetryCount
    )
    
    $result = @{
        Service = $Name
        Port = $Port
        Endpoint = $Endpoint
        Passed = $false
        ResponseTime = $null
        StatusCode = $null
        HealthStatus = $null
        Error = $null
        Attempts = 0
    }
    
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $result.Attempts = $attempt
        
        try {
            $uri = "http://localhost:$Port$Endpoint"
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            
            $response = Invoke-RestMethod -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop
            
            $sw.Stop()
            $result.ResponseTime = $sw.ElapsedMilliseconds
            $result.StatusCode = 200
            
            # Check for expected status if defined
            if ($ExpectedStatus -and $response.status) {
                $result.HealthStatus = $response.status
                $result.Passed = $response.status -eq $ExpectedStatus
            } else {
                # Any successful response is a pass
                $result.Passed = $true
                $result.HealthStatus = if ($response.status) { $response.status } else { "ok" }
            }
            
            break  # Success, no more retries
            
        } catch {
            $result.Error = $_.Exception.Message
            
            # Check if it's just a slow startup
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds 2
            }
        }
    }
    
    return $result
}

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  AitherOS Service Health Tests" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Determine which services to test
$servicesToTest = if ($Services) {
    $Services | ForEach-Object {
        $name = $_
        if ($ServiceDefinitions.ContainsKey($name)) {
            @{ Name = $name } + $ServiceDefinitions[$name]
        } else {
            Write-Warning "Unknown service: $name"
            $null
        }
    } | Where-Object { $_ }
} else {
    # Test services that appear to be running
    $ServiceDefinitions.GetEnumerator() | ForEach-Object {
        # Quick port check
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("localhost", $_.Value.Port)
            $tcp.Close()
            @{ Name = $_.Key } + $_.Value
        } catch {
            # Port not open, skip
        }
    }
}

if (-not $servicesToTest -or $servicesToTest.Count -eq 0) {
    Write-Warning "No services found to test"
    if (-not $Services) {
        Write-Host "  Tip: Start services first with 4001_Start-Genesis.ps1" -ForegroundColor Gray
    }
    exit 0
}

Write-Host "Testing $($servicesToTest.Count) service(s)..." -ForegroundColor Yellow
Write-Host "  Timeout: ${Timeout}s | Retries: $Retries" -ForegroundColor Gray
Write-Host ""

$results = @()
$failureCount = 0

foreach ($svc in $servicesToTest) {
    Write-Host "Testing: $($svc.Name) (port $($svc.Port))" -ForegroundColor Gray
    
    $result = Test-ServiceHealth `
        -Name $svc.Name `
        -Port $svc.Port `
        -Endpoint $svc.Endpoint `
        -ExpectedStatus $svc.ExpectedStatus `
        -TimeoutSec $Timeout `
        -RetryCount $Retries
    
    $results += $result
    
    if ($result.Passed) {
        Write-Host "  ✓ PASS ($($result.ResponseTime)ms) - $($result.HealthStatus)" -ForegroundColor Green
    } else {
        Write-Host "  ✗ FAIL - $($result.Error)" -ForegroundColor Red
        $failureCount++
        
        if ($FailFast) {
            Write-Host ""
            Write-Warning "Stopping due to -FailFast"
            break
        }
    }
}

# Output
if ($Json) {
    $output = @{
        Timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        TotalTests = $results.Count
        Passed = ($results | Where-Object { $_.Passed }).Count
        Failed = $failureCount
        Results = $results
    }
    Write-Output ($output | ConvertTo-Json -Depth 5)
} else {
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""
    
    $passCount = ($results | Where-Object { $_.Passed }).Count
    
    Write-Host "Test Results:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  ✓ Passed: $passCount" -ForegroundColor Green
    Write-Host "  ✗ Failed: $failureCount" -ForegroundColor $(if ($failureCount -gt 0) { "Red" } else { "Gray" })
    Write-Host "  Total:    $($results.Count)" -ForegroundColor Gray
    
    # Show response time summary
    $avgTime = ($results | Where-Object { $_.ResponseTime } | Measure-Object -Property ResponseTime -Average).Average
    if ($avgTime) {
        Write-Host ""
        Write-Host "  Avg Response: $([math]::Round($avgTime))ms" -ForegroundColor Gray
    }
    
    # Show failures
    if ($failureCount -gt 0) {
        Write-Host ""
        Write-Host "Failed Services:" -ForegroundColor Red
        foreach ($fail in ($results | Where-Object { -not $_.Passed })) {
            Write-Host "  - $($fail.Service): $($fail.Error)" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
}

exit $failureCount
