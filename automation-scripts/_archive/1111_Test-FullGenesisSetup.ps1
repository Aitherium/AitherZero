#Requires -Version 7.0

<#
.SYNOPSIS
    Test and validate full Genesis + 85 services setup
.DESCRIPTION
    This script performs a comprehensive test of the Genesis bootloader
    and validates that all 85 AitherOS services are properly defined and
    ready for deployment.
    
    This script integrates with the AitherZero automation framework and
    uses the existing 0800_Manage-Genesis.ps1 script for Genesis control.
    
    Test Phases:
    1. Environment validation
    2. Dependency check
    3. Genesis startup
    4. Service discovery validation
    5. BMC functionality test
    6. Service boot attempt
    7. Status reporting

.PARAMETER SkipBoot
    Skip the actual service boot phase (useful for quick validation)

.PARAMETER Profile
    Boot profile to use (default: core)

.PARAMETER ShowOutput
    Show verbose output

.NOTES
    Stage: Testing
    Order: 1111
    Dependencies: 0800
    Tags: genesis, testing, integration, services
    
.EXAMPLE
    ./1111_Test-FullGenesisSetup.ps1
    Run full test suite
    
.EXAMPLE
    ./1111_Test-FullGenesisSetup.ps1 -SkipBoot -ShowOutput
    Test Genesis without attempting service boot
#>

[CmdletBinding()]
param(
    [switch]$SkipBoot,
    [string]$Profile = "core",
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# Initialize test state
$script:TestResults = @{
    Passed = 0
    Failed = 0
    Skipped = 0
    Tests = @()
}

# ============================================================================
# Helper Functions
# ============================================================================

function Write-TestHeader {
    param([string]$Message)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = ""
    )
    
    $result = @{
        Name = $TestName
        Passed = $Passed
        Message = $Message
        Timestamp = Get-Date
    }
    
    $script:TestResults.Tests += $result
    
    if ($Passed) {
        $script:TestResults.Passed++
        Write-Host "  ✓ $TestName" -ForegroundColor Green
        if ($Message) {
            Write-Host "    $Message" -ForegroundColor Gray
        }
    } else {
        $script:TestResults.Failed++
        Write-Host "  ✗ $TestName" -ForegroundColor Red
        if ($Message) {
            Write-Host "    $Message" -ForegroundColor Yellow
        }
    }
}

function Write-TestInfo {
    param([string]$Message)
    Write-Host "  ℹ $Message" -ForegroundColor Blue
}

function Write-TestWarning {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

# ============================================================================
# Test Functions
# ============================================================================

function Test-Environment {
    Write-TestHeader "PHASE 1: Environment Validation"
    
    # Test PowerShell version
    $psVersion = $PSVersionTable.PSVersion
    Write-TestResult "PowerShell Version" ($psVersion.Major -ge 7) "Version: $psVersion"
    
    # Test repository structure
    $projectRoot = $env:AITHERZERO_ROOT
    if (-not $projectRoot) {
        $projectRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    }
    
    $genesisExists = Test-Path (Join-Path $projectRoot "AitherOS/AitherGenesis/genesis_service.py")
    Write-TestResult "Genesis Service File" $genesisExists
    
    $servicesYamlExists = Test-Path (Join-Path $projectRoot "AitherOS/config/services.yaml")
    Write-TestResult "Services Configuration" $servicesYamlExists
    
    # Test Python
    $pythonExists = $null -ne (Get-Command python3 -ErrorAction SilentlyContinue)
    if ($pythonExists) {
        $pythonVersion = (python3 --version 2>&1) -replace 'Python ', ''
        Write-TestResult "Python 3" $pythonExists "Version: $pythonVersion"
    } else {
        Write-TestResult "Python 3" $false "Python 3 not found"
    }
    
    return $genesisExists -and $servicesYamlExists
}

function Test-Dependencies {
    Write-TestHeader "PHASE 2: Python Dependencies Check"
    
    $requiredPackages = @('aiohttp', 'fastapi', 'uvicorn', 'httpx', 'pydantic', 'pyyaml')
    $allInstalled = $true
    
    foreach ($package in $requiredPackages) {
        try {
            $result = python3 -c "import $package; print($package.__version__)" 2>$null
            $installed = $LASTEXITCODE -eq 0
            Write-TestResult "$package" $installed $(if ($installed) { "Version: $result" } else { "Not installed" })
            $allInstalled = $allInstalled -and $installed
        } catch {
            Write-TestResult "$package" $false "Not installed"
            $allInstalled = $false
        }
    }
    
    if (-not $allInstalled) {
        Write-TestWarning "Some dependencies missing. Install with: pip install aiohttp fastapi uvicorn httpx pydantic pyyaml psutil"
    }
    
    return $allInstalled
}

function Test-GenesisStartup {
    Write-TestHeader "PHASE 3: Genesis Bootloader Startup"
    
    # Use the 0800 script to start Genesis
    $script0800 = Join-Path $PSScriptRoot "0800_Manage-Genesis.ps1"
    
    if (-not (Test-Path $script0800)) {
        Write-TestResult "0800 Script Available" $false "0800_Manage-Genesis.ps1 not found"
        return $false
    }
    
    Write-TestInfo "Starting Genesis using 0800_Manage-Genesis.ps1..."
    
    try {
        & $script0800 -Action Start -ShowOutput:$ShowOutput 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        
        # Test Genesis health
        $health = Invoke-RestMethod -Uri "http://localhost:8001/health" -Method Get -TimeoutSec 5
        $isHealthy = $health.status -eq "healthy"
        
        Write-TestResult "Genesis Started" $isHealthy $(if ($isHealthy) { "Version: $($health.version)" } else { "Not healthy" })
        
        return $isHealthy
    } catch {
        Write-TestResult "Genesis Started" $false $_.Exception.Message
        return $false
    }
}

function Test-ServiceDiscovery {
    Write-TestHeader "PHASE 4: Service Discovery Validation"
    
    try {
        # Get BMC status
        $bmcStatus = Invoke-RestMethod -Uri "http://localhost:8001/bmc/status" -Method Get -TimeoutSec 5
        
        $serviceCount = $bmcStatus.services.total
        $expectedCount = 85
        
        Write-TestResult "Service Count" ($serviceCount -eq $expectedCount) "Found: $serviceCount / Expected: $expectedCount"
        
        # Get service list
        $services = Invoke-RestMethod -Uri "http://localhost:8001/services" -Method Get -TimeoutSec 5
        
        # Categorize services
        $byCategory = $services | Group-Object category | ForEach-Object {
            [PSCustomObject]@{
                Category = $_.Name
                Count = $_.Count
            }
        }
        
        Write-TestInfo "Services by category:"
        foreach ($cat in $byCategory) {
            Write-Host "    $($cat.Category): $($cat.Count)" -ForegroundColor Gray
        }
        
        return $serviceCount -eq $expectedCount
    } catch {
        Write-TestResult "Service Discovery" $false $_.Exception.Message
        return $false
    }
}

function Test-BMCFunctionality {
    Write-TestHeader "PHASE 5: BMC Functionality Test"
    
    try {
        # Test BMC status endpoint
        $bmcStatus = Invoke-RestMethod -Uri "http://localhost:8001/bmc/status" -Method Get -TimeoutSec 5
        Write-TestResult "BMC Status" ($null -ne $bmcStatus.power_state) "Power state: $($bmcStatus.power_state)"
        
        # Test services endpoint
        $services = Invoke-RestMethod -Uri "http://localhost:8001/services" -Method Get -TimeoutSec 5
        Write-TestResult "Services API" ($services.Count -gt 0) "Retrieved $($services.Count) services"
        
        # Test dashboard endpoint
        $dashboard = Invoke-WebRequest -Uri "http://localhost:8001/dashboard" -Method Get -TimeoutSec 5
        Write-TestResult "Dashboard" ($dashboard.StatusCode -eq 200) "HTTP $($dashboard.StatusCode)"
        
        return $true
    } catch {
        Write-TestResult "BMC Functionality" $false $_.Exception.Message
        return $false
    }
}

function Test-ServiceBoot {
    Write-TestHeader "PHASE 6: Service Boot Test"
    
    if ($SkipBoot) {
        Write-TestWarning "Service boot skipped (-SkipBoot flag)"
        $script:TestResults.Skipped++
        return $true
    }
    
    Write-TestInfo "Attempting to boot services with profile: $Profile"
    Write-TestInfo "Note: Full service boot requires Servy/NSSM (Windows) or systemd (Linux)"
    
    try {
        # Use the 0800 script to boot services
        $script0800 = Join-Path $PSScriptRoot "0800_Manage-Genesis.ps1"
        
        & $script0800 -Action Boot -Profile $Profile -ShowOutput:$ShowOutput 2>&1 | Out-Null
        
        Start-Sleep -Seconds 5
        
        # Check status
        $bmcStatus = Invoke-RestMethod -Uri "http://localhost:8001/bmc/status" -Method Get -TimeoutSec 5
        $runningCount = $bmcStatus.services.running
        
        Write-TestInfo "Services running: $runningCount / $($bmcStatus.services.total)"
        
        # In CI/test environments, expect limited services (1-5)
        # In production with Servy/NSSM, expect 70-85 services
        $isCI = $env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true'
        
        if ($isCI) {
            # CI environment - limited services expected
            Write-TestResult "Service Boot (CI)" ($runningCount -ge 1) "Running: $runningCount (Limited in CI - expected)"
            Write-TestWarning "Full service deployment requires Servy/NSSM or systemd"
        } else {
            # Production environment - expect more services
            Write-TestResult "Service Boot" ($runningCount -gt 5) "Running: $runningCount / $($bmcStatus.services.total)"
        }
        
        return $true
    } catch {
        Write-TestResult "Service Boot" $false $_.Exception.Message
        return $false
    }
}

function Show-TestSummary {
    Write-TestHeader "TEST SUMMARY"
    
    $total = $script:TestResults.Passed + $script:TestResults.Failed
    $passRate = if ($total -gt 0) { [math]::Round(($script:TestResults.Passed / $total) * 100, 1) } else { 0 }
    
    Write-Host ""
    Write-Host "  Total Tests:  $total" -ForegroundColor Cyan
    Write-Host "  Passed:       $($script:TestResults.Passed)" -ForegroundColor Green
    Write-Host "  Failed:       $($script:TestResults.Failed)" -ForegroundColor $(if ($script:TestResults.Failed -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Skipped:      $($script:TestResults.Skipped)" -ForegroundColor Yellow
    Write-Host "  Pass Rate:    $passRate%" -ForegroundColor $(if ($passRate -ge 80) { 'Green' } elseif ($passRate -ge 60) { 'Yellow' } else { 'Red' })
    Write-Host ""
    
    # Show Genesis dashboard info
    Write-Host "Genesis Dashboard: http://localhost:8001/dashboard" -ForegroundColor Cyan
    Write-Host "API Documentation: http://localhost:8001/docs" -ForegroundColor Cyan
    Write-Host ""
    
    # Show next steps
    if ($script:TestResults.Failed -eq 0) {
        Write-Host "✅ All tests passed!" -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Yellow
        Write-Host "  • View status:    ./0800_Manage-Genesis.ps1 -Action Status" -ForegroundColor Gray
        Write-Host "  • List services:  ./0800_Manage-Genesis.ps1 -Action Inventory" -ForegroundColor Gray
        Write-Host "  • Stop Genesis:   ./0800_Manage-Genesis.ps1 -Action Stop" -ForegroundColor Gray
    } else {
        Write-Host "⚠️ Some tests failed. Review output above." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "For full production deployment, use:" -ForegroundColor Yellow
        Write-Host "  ./bootstrap.ps1 -Playbook genesis-bootstrap" -ForegroundColor Cyan
    }
    
    Write-Host ""
}

# ============================================================================
# Main Execution
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Genesis + 85 Services - Full Setup Test Suite           ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$startTime = Get-Date

# Run test phases
$envOk = Test-Environment
if (-not $envOk) {
    Write-Host ""
    Write-Host "⛔ Environment validation failed. Cannot continue." -ForegroundColor Red
    exit 1
}

$depsOk = Test-Dependencies
if (-not $depsOk) {
    Write-Host ""
    Write-Host "⚠️ Some dependencies missing. Installing..." -ForegroundColor Yellow
    try {
        python3 -m pip install -q aiohttp fastapi uvicorn httpx pydantic pyyaml psutil python-dotenv
        Write-Host "✓ Dependencies installed" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ Dependency installation failed. Some tests may fail." -ForegroundColor Yellow
    }
}

$genesisOk = Test-GenesisStartup
if (-not $genesisOk) {
    Write-Host ""
    Write-Host "⛔ Genesis startup failed. Cannot continue." -ForegroundColor Red
    Show-TestSummary
    exit 1
}

Test-ServiceDiscovery | Out-Null
Test-BMCFunctionality | Out-Null
Test-ServiceBoot | Out-Null

$elapsed = (Get-Date) - $startTime

Write-Host ""
Write-Host "Test Duration: $($elapsed.TotalSeconds) seconds" -ForegroundColor Gray

Show-TestSummary

# Exit with appropriate code
if ($script:TestResults.Failed -eq 0) {
    exit 0
} else {
    exit 1
}
