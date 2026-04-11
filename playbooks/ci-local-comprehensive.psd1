@{
    Name = "ci-local-comprehensive"
    Description = "Runs the full CI/CD pipeline locally, mirroring GitHub Actions"
    Steps = @(
        @{
            Name = "Bootstrap Environment"
            Script = "bootstrap.ps1"
            Arguments = "-Mode New -InstallProfile Minimal -NonInteractive"
            Condition = "Always"
        },
        @{
            Name = "Validate Syntax"
            Script = "AitherZero/library/automation-scripts/0906_Validate-Syntax.ps1"
            Arguments = "-All"
            Condition = "Success"
        },
        @{
            Name = "Run PSScriptAnalyzer"
            Script = "AitherZero/library/automation-scripts/0903_Run-PSScriptAnalyzer.ps1"
            Arguments = "-OutputPath ./library/reports/psscriptanalyzer-results.json"
            Condition = "Success"
        },
        @{
            Name = "Run Unit Tests"
            Script = "AitherZero/library/automation-scripts/0901_Run-UnitTests.ps1"
            Arguments = "-OutputPath ./library/reports -CI"
            Condition = "Success"
        },
        @{
            Name = "Generate Code Coverage"
            Script = "AitherZero/library/automation-scripts/0905_Generate-Coverage.ps1"
            Arguments = "-OutputPath ./library/reports/coverage-summary.json"
            Condition = "Success"
        },
        @{
            Name = "Profile Module Performance"
            Script = "AitherZero/library/automation-scripts/0916_Profile-ModulePerformance.ps1"
            Arguments = "-OutputPath ./library/reports/performance-profile.json"
            Condition = "Success"
        },
        @{
            Name = "Build AitherZero Module"
            Script = "AitherZero/build.ps1"
            Arguments = "-OutputPath ./bin"
            Condition = "Success"
        },
        @{
            Name = "Generate Dashboard"
            Script = "AitherZero/library/automation-scripts/0990_Generate-WebDashboard.ps1"
            Arguments = "-BranchName 'local-dev' -CommitHash 'local' -OutputPath './public'"
            Condition = "Success"
        }
    )
}
