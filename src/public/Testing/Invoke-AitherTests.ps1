function Invoke-AitherTests {
    <#
    .SYNOPSIS
        Runs AitherZero unit tests.
    .DESCRIPTION
        Executes Pester tests for the AitherZero module.
        Tests are expected to be in the 'tests' directory of the module.
    .PARAMETER Path
        Override path to tests.
    .PARAMETER OutputPath
        Path to output test results (NUnit XML).
    .PARAMETER PassThru
        Returns Pester result object.
    .PARAMETER CodeCoverage
        Enable code coverage analysis.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$OutputPath,
        [switch]$PassThru,
        [switch]$CodeCoverage
    )

    process {
        $moduleRoot = $PSScriptRoot
        if ($env:AITHERZERO_MODULE_ROOT) {
            $moduleRoot = $env:AITHERZERO_MODULE_ROOT
        }

        # Default test path
        if (-not $Path) {
            $Path = Join-Path $moduleRoot "tests/unit"
        }

        if (-not (Test-Path $Path)) {
            Write-AitherLog -Level Error -Message "Test path not found: $Path" -Source 'Invoke-AitherTests'
            throw "Test path not found: $Path"
        }

        Write-AitherLog -Message "Running tests from: $Path" -Level Information

        # Configure Pester
        $pesterConfig = New-PesterConfiguration
        $pesterConfig.Run.Path = $Path
        $pesterConfig.Run.PassThru = [bool]$PassThru
        $pesterConfig.Output.Verbosity = 'Detailed'

        if ($OutputPath) {
            $pesterConfig.TestResult.Enabled = $true
            $pesterConfig.TestResult.OutputFormat = 'NUnitXml'
            $pesterConfig.TestResult.OutputPath = $OutputPath
        }

        if ($CodeCoverage) {
            $pesterConfig.CodeCoverage.Enabled = $true
            # Coverage for the module source (if available) or the module itself?
            # Since we are building a monolithic psm1, coverage might be tricky if we want per-function coverage.
            # But let's point it to the module root for now, or src if available.
            $srcPath = Join-Path $moduleRoot "src"
            if (Test-Path $srcPath) {
                $pesterConfig.CodeCoverage.Path = $srcPath
            }
        }

        Invoke-Pester -Configuration $pesterConfig
    }
}

