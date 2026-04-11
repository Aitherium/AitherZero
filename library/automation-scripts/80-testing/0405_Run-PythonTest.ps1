#Requires -Version 7.0

<#
.SYNOPSIS
    Execute Python pytest tests for AitherOS
.DESCRIPTION
    Runs Python tests using pytest against the AitherOS test suite.
    Activates the project venv if present, runs pytest with configurable
    options, and captures results in JUnit XML for dashboard integration.

    Exit Codes:
    0   - All tests passed
    1   - One or more tests failed
    2   - Test execution error (pytest not found, venv missing, etc.)

.PARAMETER Path
    Path to test file or directory. Defaults to AitherOS/tests.
.PARAMETER Filter
    Pytest -k filter expression (e.g. "test_eval" or "not integration").
.PARAMETER Marker
    Pytest -m marker expression (e.g. "asyncio", "not integration").
.PARAMETER OutputPath
    Path to write JUnit XML results. Auto-generated if not specified.
.PARAMETER ShowDetail
    Show full pytest output (pytest -v).
.PARAMETER Coverage
    Enable coverage reporting via pytest-cov.
.PARAMETER MaxFail
    Stop after N failures (pytest --maxfail).
.PARAMETER Fast
    Run with -x (stop on first failure) and no coverage.
.PARAMETER PassThru
    Return the pytest exit code instead of throwing on failure.

.EXAMPLE
    # Run all AitherOS Python tests
    pwsh -File 0405_Run-PythonTest.ps1

.EXAMPLE
    # Run a specific test file
    pwsh -File 0405_Run-PythonTest.ps1 -Path AitherOS/tests/test_aither_eval.py

.EXAMPLE
    # Run with filter and stop on first failure
    pwsh -File 0405_Run-PythonTest.ps1 -Filter "test_efficiency" -Fast

.NOTES
    Stage: Testing
    Order: 0405
    Dependencies: 0400
    Tags: testing, python, pytest, aitheros
    AllowParallel: true
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path,
    [string]$Filter,
    [string]$Marker,
    [string]$OutputPath,
    [switch]$ShowDetail,
    [switch]$Coverage,
    [int]$MaxFail = 0,
    [switch]$Fast,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Script metadata
$scriptMetadata = @{
    Stage        = 'Testing'
    Order        = 0405
    Dependencies = @('0400')
    Tags         = @('testing', 'python', 'pytest', 'aitheros')
    RequiresAdmin = $false
    SupportsWhatIf = $true
}

# Initialize AitherZero
. "$PSScriptRoot/../_init.ps1"

if (-not $projectRoot) {
    Write-Error "AitherZero project root not found"
    exit 2
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve Python
# ─────────────────────────────────────────────────────────────────────────────

$aitherOSRoot = Join-Path $projectRoot "AitherOS"

# Try venv first, then system python
$venvPaths = @(
    (Join-Path $projectRoot ".venv/Scripts/python.exe"),   # Windows
    (Join-Path $projectRoot ".venv/bin/python"),            # Linux/Mac
    (Join-Path $aitherOSRoot ".venv/Scripts/python.exe"),
    (Join-Path $aitherOSRoot ".venv/bin/python")
)

$pythonCmd = $null
foreach ($vp in $venvPaths) {
    if (Test-Path $vp) {
        $pythonCmd = $vp
        break
    }
}

if (-not $pythonCmd) {
    # Fall back to system Python
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $pythonCmd) {
        $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    }
}

if (-not $pythonCmd) {
    Write-Error "Python not found. Install Python 3.10+ or create a venv at $projectRoot/.venv"
    exit 2
}

Write-Host "[PYTHON] Using: $pythonCmd" -ForegroundColor Cyan

# Verify pytest is available
$pytestCheck = & $pythonCmd -m pytest --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "pytest not found. Install with: pip install pytest pytest-asyncio"
    exit 2
}
Write-Host "[PYTEST] $($pytestCheck | Select-Object -First 1)" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────────────────
# Resolve test path
# ─────────────────────────────────────────────────────────────────────────────

if (-not $Path) {
    $Path = Join-Path $aitherOSRoot "tests"
}

# Allow relative paths from project root
if (-not [System.IO.Path]::IsPathRooted($Path)) {
    $Path = Join-Path $projectRoot $Path
}

if (-not (Test-Path $Path)) {
    Write-Error "Test path not found: $Path"
    exit 2
}

Write-Host "[TESTS]  Path: $Path" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────────────────
# Build pytest arguments
# ─────────────────────────────────────────────────────────────────────────────

$pytestArgs = @('-m', 'pytest', $Path)

# Verbosity
if ($ShowDetail -or $Fast) {
    $pytestArgs += '-v'
}

# Output format — always show short tracebacks
$pytestArgs += '--tb=short'

# JUnit XML results
if (-not $OutputPath) {
    $resultsDir = Join-Path $projectRoot "AitherZero/library/tests/results"
    if (-not (Test-Path $resultsDir)) {
        New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $resultsDir "PythonTests-$timestamp.xml"
}
$pytestArgs += @('--junitxml', $OutputPath)

# Filter expression
if ($Filter) {
    $pytestArgs += @('-k', $Filter)
}

# Marker expression
if ($Marker) {
    $pytestArgs += @('-m', $Marker)
}

# Fast mode: stop on first failure
if ($Fast) {
    $pytestArgs += '-x'
}

# Max failures
if ($MaxFail -gt 0) {
    $pytestArgs += @('--maxfail', $MaxFail.ToString())
}

# Coverage
if ($Coverage -and -not $Fast) {
    $pytestArgs += @('--cov', $aitherOSRoot, '--cov-report', 'term-missing')
}

# ─────────────────────────────────────────────────────────────────────────────
# Run
# ─────────────────────────────────────────────────────────────────────────────

$divider = '─' * 70
Write-Host ""
Write-Host $divider -ForegroundColor DarkGray
Write-Host "  PYTEST: AitherOS Python Tests" -ForegroundColor White
Write-Host $divider -ForegroundColor DarkGray
Write-Host ""

$startTime = Get-Date

if ($PSCmdlet.ShouldProcess($Path, "Run pytest")) {
    # Run from AitherOS root so imports resolve correctly
    Push-Location $aitherOSRoot
    try {
        & $pythonCmd @pytestArgs
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "[DRYRUN] Would run: $pythonCmd $($pytestArgs -join ' ')" -ForegroundColor Yellow
    $exitCode = 0
}

$elapsed = (Get-Date) - $startTime

# ─────────────────────────────────────────────────────────────────────────────
# Results
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host $divider -ForegroundColor DarkGray

if ($exitCode -eq 0) {
    Write-Host "  [PASS] All tests passed ($([math]::Round($elapsed.TotalSeconds, 1))s)" -ForegroundColor Green
}
elseif ($exitCode -eq 1) {
    Write-Host "  [FAIL] Some tests failed ($([math]::Round($elapsed.TotalSeconds, 1))s)" -ForegroundColor Red
}
elseif ($exitCode -eq 5) {
    # pytest exit code 5 = no tests collected
    Write-Host "  [WARN] No tests collected ($([math]::Round($elapsed.TotalSeconds, 1))s)" -ForegroundColor Yellow
    $exitCode = 0
}
else {
    Write-Host "  [ERROR] pytest exited with code $exitCode ($([math]::Round($elapsed.TotalSeconds, 1))s)" -ForegroundColor Red
}

if (Test-Path $OutputPath) {
    Write-Host "  Results: $OutputPath" -ForegroundColor DarkGray
}

Write-Host $divider -ForegroundColor DarkGray
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# Dashboard metrics (if available)
# ─────────────────────────────────────────────────────────────────────────────

if (Get-Command Initialize-AitherDashboard -ErrorAction SilentlyContinue) {
    try {
        Initialize-AitherDashboard -ProjectPath $projectRoot -OutputPath "AitherZero/library/reports"

        $metrics = @{
            PythonTestsRun     = $true
            PythonTestExitCode = $exitCode
            PythonTestDuration = [math]::Round($elapsed.TotalSeconds, 2)
            PythonTestPath     = $Path
            Timestamp          = (Get-Date -Format 'o')
        }

        # Parse JUnit XML for counts if available
        if (Test-Path $OutputPath) {
            try {
                [xml]$junit = Get-Content $OutputPath -Raw
                $suite = $junit.testsuites.testsuite | Select-Object -First 1
                if ($suite) {
                    $metrics.PythonTestTotal   = [int]$suite.tests
                    $metrics.PythonTestFailed  = [int]$suite.failures
                    $metrics.PythonTestErrors  = [int]$suite.errors
                    $metrics.PythonTestSkipped = [int]$suite.skipped
                    $metrics.PythonTestPassed  = $metrics.PythonTestTotal - $metrics.PythonTestFailed - $metrics.PythonTestErrors - $metrics.PythonTestSkipped
                }
            }
            catch {
                Write-Host "  [WARN] Could not parse JUnit XML: $_" -ForegroundColor Yellow
            }
        }

        Register-AitherMetrics -Category 'PythonTests' -Metrics $metrics
        Export-AitherMetrics -OutputFile "metrics/python-test-metrics.json" -ShowOutput:$false
    }
    catch {
        # Dashboard not critical
        Write-Host "  [WARN] Dashboard metrics not recorded: $_" -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Exit
# ─────────────────────────────────────────────────────────────────────────────

if ($PassThru) {
    return $exitCode
}

if ($exitCode -ne 0) {
    exit $exitCode
}
