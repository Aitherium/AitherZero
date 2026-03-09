#Requires -Modules Pester

$projectRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent
$modulePath = Join-Path $projectRoot "AitherZero/AitherZero.psd1"

Describe "AitherZero Module Structure" -Tag "Unit", "Module" {
    BeforeAll {
        $projectRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent
        $modulePath = Join-Path $projectRoot "AitherZero/AitherZero.psd1"
    }

    Context "Module Loading" {
        It "Module manifest exists at the correct path" {
            $modulePath | Should -Exist
        }

        It "Module can be imported" {
            Import-Module $modulePath -Force -PassThru | Should -Not -BeNullOrEmpty
        }
    }

    Context "Exported Functions" {
        BeforeAll {
            Import-Module $modulePath -Force
        }

        $testCases = @(
            @{ FunctionName = 'Get-AitherProjectRoot' }
            @{ FunctionName = 'Show-AitherDashboard' }
            @{ FunctionName = 'Initialize-AitherDashboard' }
            @{ FunctionName = 'Register-AitherMetrics' }
            @{ FunctionName = 'Write-AitherLog' }
        )

        It "Exports function: <FunctionName>" -TestCases $testCases {
            param($FunctionName)
            Get-Command -Name $FunctionName -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Core Functionality" {
        BeforeAll {
            Import-Module $modulePath -Force
        }

        It "Get-AitherProjectRoot returns a valid path" {
            $root = Get-AitherProjectRoot
            $root | Should -Not -BeNullOrEmpty
            $root | Should -Exist
        }

        It "Initialize-AitherDashboard returns a configuration object" {
            $config = Initialize-AitherDashboard -ProjectPath $projectRoot -OutputPath (Join-Path $projectRoot "AitherZero/library/tests/results")
            $config | Should -BeOfType [System.Collections.Hashtable]
            $config.ProjectPath | Should -Not -BeNullOrEmpty
        }
    }
}
