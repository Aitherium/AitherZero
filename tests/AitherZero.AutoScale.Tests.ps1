#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for AitherZero AutoScale module functions.
.DESCRIPTION
    Unit tests for the AutoScale PowerShell module: policy management,
    scaling actions, metric collection, provider detection, and history.
#>

Describe "AitherZero AutoScale Module" -Tag "Integration", "AutoScale" {

    BeforeAll {
        $projectRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
        $modulePath = Join-Path $projectRoot "AitherZero" "AitherZero.psd1"

        # Import the module
        if (Test-Path $modulePath) {
            Import-Module $modulePath -Force -ErrorAction SilentlyContinue
        }

        # Source individual files if module not built yet
        $autoScaleDir = Join-Path $projectRoot "AitherZero" "src" "public" "AutoScale"
        if (Test-Path $autoScaleDir) {
            Get-ChildItem -Path $autoScaleDir -Filter "*.ps1" | ForEach-Object {
                . $_.FullName
            }
        }
    }

    Context "Module Function Exports" {

        $expectedFunctions = @(
            @{ FunctionName = 'Get-AitherScaleStatus' }
            @{ FunctionName = 'New-AitherScalePolicy' }
            @{ FunctionName = 'Set-AitherScalePolicy' }
            @{ FunctionName = 'Invoke-AitherScaleAction' }
            @{ FunctionName = 'Get-AitherScaleMetric' }
            @{ FunctionName = 'Watch-AitherScale' }
            @{ FunctionName = 'Get-AitherScaleHistory' }
            @{ FunctionName = 'Get-AitherCloudProvider' }
        )

        It "Function <FunctionName> exists" -TestCases $expectedFunctions {
            param($FunctionName)
            Get-Command $FunctionName -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Function <FunctionName> has CmdletBinding" -TestCases $expectedFunctions {
            param($FunctionName)
            $cmd = Get-Command $FunctionName -ErrorAction SilentlyContinue
            if ($cmd) {
                $cmd.CmdletBinding | Should -Be $true
            }
        }
    }

    Context "Get-AitherScaleStatus" {

        It "Returns a result even when agent is unavailable" {
            # Without a running AutoScale agent, should fall back gracefully
            $result = Get-AitherScaleStatus -ErrorAction SilentlyContinue 2>$null
            # Should return something (even in fallback mode)
            $result | Should -Not -BeNullOrEmpty -Because "Should fall back to Docker inspection"
        }

        It "Accepts -Target parameter" {
            $cmd = Get-Command Get-AitherScaleStatus
            $cmd.Parameters.Keys | Should -Contain 'Target'
        }

        It "Accepts -IncludeMetrics switch" {
            $cmd = Get-Command Get-AitherScaleStatus
            $cmd.Parameters.Keys | Should -Contain 'IncludeMetrics'
        }

        It "Accepts -Raw switch" {
            $cmd = Get-Command Get-AitherScaleStatus
            $cmd.Parameters.Keys | Should -Contain 'Raw'
        }
    }

    Context "New-AitherScalePolicy" {

        It "Has mandatory Id and Target parameters" {
            $cmd = Get-Command New-AitherScalePolicy
            $cmd.Parameters['Id'].Attributes.Mandatory | Should -Contain $true
            $cmd.Parameters['Target'].Attributes.Mandatory | Should -Contain $true
        }

        It "Validates Provider parameter set" {
            $cmd = Get-Command New-AitherScalePolicy
            $validateSet = $cmd.Parameters['Provider'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet.ValidValues | Should -Contain 'docker'
            $validateSet.ValidValues | Should -Contain 'aws'
            $validateSet.ValidValues | Should -Contain 'azure'
            $validateSet.ValidValues | Should -Contain 'gcp'
            $validateSet.ValidValues | Should -Contain 'hyperv'
        }

        It "Validates Template parameter set" {
            $cmd = Get-Command New-AitherScalePolicy
            $validateSet = $cmd.Parameters['Template'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet.ValidValues | Should -Contain 'cpu-reactive'
            $validateSet.ValidValues | Should -Contain 'cloud-burst'
            $validateSet.ValidValues | Should -Contain 'gpu-workload'
            $validateSet.ValidValues | Should -Contain 'pain-responsive'
        }

        It "Supports ShouldProcess" {
            $cmd = Get-Command New-AitherScalePolicy
            $cmd.Parameters.Keys | Should -Contain 'WhatIf'
            $cmd.Parameters.Keys | Should -Contain 'Confirm'
        }
    }

    Context "Invoke-AitherScaleAction" {

        It "Has mandatory Target and Direction parameters" {
            $cmd = Get-Command Invoke-AitherScaleAction
            $cmd.Parameters['Target'].Attributes.Mandatory | Should -Contain $true
            $cmd.Parameters['Direction'].Attributes.Mandatory | Should -Contain $true
        }

        It "Validates Direction to Up or Down" {
            $cmd = Get-Command Invoke-AitherScaleAction
            $validateSet = $cmd.Parameters['Direction'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet.ValidValues | Should -Contain 'Up'
            $validateSet.ValidValues | Should -Contain 'Down'
        }

        It "Supports DryRun switch" {
            $cmd = Get-Command Invoke-AitherScaleAction
            $cmd.Parameters.Keys | Should -Contain 'DryRun'
        }

        It "Supports ShouldProcess" {
            $cmd = Get-Command Invoke-AitherScaleAction
            $cmd.Parameters.Keys | Should -Contain 'WhatIf'
        }
    }

    Context "Get-AitherScaleMetric" {

        It "Accepts optional Target parameter" {
            $cmd = Get-Command Get-AitherScaleMetric
            $cmd.Parameters.Keys | Should -Contain 'Target'
            $cmd.Parameters['Target'].Attributes.Mandatory | Should -Not -Contain $true
        }

        It "Validates Metric parameter set" {
            $cmd = Get-Command Get-AitherScaleMetric
            $validateSet = $cmd.Parameters['Metric'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet.ValidValues | Should -Contain 'cpu_percent'
            $validateSet.ValidValues | Should -Contain 'memory_percent'
            $validateSet.ValidValues | Should -Contain 'gpu_util'
            $validateSet.ValidValues | Should -Contain 'pain_level'
        }

        It "Has Summary switch" {
            $cmd = Get-Command Get-AitherScaleMetric
            $cmd.Parameters.Keys | Should -Contain 'Summary'
        }
    }

    Context "Get-AitherCloudProvider" {

        It "Returns results even without agent (env detection fallback)" {
            $result = Get-AitherCloudProvider -ErrorAction SilentlyContinue 2>$null
            $result | Should -Not -BeNullOrEmpty -Because "Docker should always be detected"
        }

        It "Always includes Docker as a provider" {
            $result = Get-AitherCloudProvider -ErrorAction SilentlyContinue 2>$null
            $dockerProvider = $result | Where-Object { $_.Name -eq 'docker' }
            $dockerProvider | Should -Not -BeNullOrEmpty
        }
    }

    Context "Get-AitherScaleHistory" {

        It "Accepts Target, Direction, and Limit parameters" {
            $cmd = Get-Command Get-AitherScaleHistory
            $cmd.Parameters.Keys | Should -Contain 'Target'
            $cmd.Parameters.Keys | Should -Contain 'Direction'
            $cmd.Parameters.Keys | Should -Contain 'Limit'
        }

        It "Validates Limit range (1-500)" {
            $cmd = Get-Command Get-AitherScaleHistory
            $validateRange = $cmd.Parameters['Limit'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $validateRange | Should -Not -BeNullOrEmpty
        }

        It "Returns gracefully when agent unavailable" {
            $result = Get-AitherScaleHistory -ErrorAction SilentlyContinue 2>$null
            # Should return empty array or null — not throw
            { Get-AitherScaleHistory -ErrorAction SilentlyContinue 2>$null } | Should -Not -Throw
        }
    }

    Context "Watch-AitherScale" {

        It "Has Interval and Duration parameters" {
            $cmd = Get-Command Watch-AitherScale
            $cmd.Parameters.Keys | Should -Contain 'Interval'
            $cmd.Parameters.Keys | Should -Contain 'Duration'
        }

        It "Validates Interval range (5-600)" {
            $cmd = Get-Command Watch-AitherScale
            $validateRange = $cmd.Parameters['Interval'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $validateRange | Should -Not -BeNullOrEmpty
        }

        It "Has Quiet switch" {
            $cmd = Get-Command Watch-AitherScale
            $cmd.Parameters.Keys | Should -Contain 'Quiet'
        }
    }

    Context "Automation Script" {

        It "4009_Invoke-AutoScale.ps1 exists" {
            $scriptPath = Join-Path $projectRoot "AitherZero" "library" "automation-scripts" "40-lifecycle" "4009_Invoke-AutoScale.ps1"
            Test-Path $scriptPath | Should -Be $true
        }

        It "Script has required Action parameter" {
            $scriptPath = Join-Path $projectRoot "AitherZero" "library" "automation-scripts" "40-lifecycle" "4009_Invoke-AutoScale.ps1"
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Action'
            $content | Should -Match 'Status.*Scale.*Watch.*Policy.*Metrics.*History.*Providers'
        }
    }
}

Describe "AitherAutoScale Python Agent" -Tag "Integration", "AutoScale", "Python" {

    BeforeAll {
        $projectRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
    }

    Context "Service File Structure" {

        It "AitherAutoScale.py exists" {
            $agentPath = Join-Path $projectRoot "AitherOS" "services" "agents" "AitherAutoScale.py"
            Test-Path $agentPath | Should -Be $true
        }

        It "Uses _bootstrap import pattern" {
            $agentPath = Join-Path $projectRoot "AitherOS" "services" "agents" "AitherAutoScale.py"
            $content = Get-Content $agentPath -Raw
            $content | Should -Match 'import services\._bootstrap'
        }

        It "Uses AitherService pattern" {
            $agentPath = Join-Path $projectRoot "AitherOS" "services" "agents" "AitherAutoScale.py"
            $content = Get-Content $agentPath -Raw
            $content | Should -Match 'AitherService'
            $content | Should -Match 'setup_lifecycle'
        }

        It "Registers on port 8797" {
            $agentPath = Join-Path $projectRoot "AitherOS" "services" "agents" "AitherAutoScale.py"
            $content = Get-Content $agentPath -Raw
            $content | Should -Match '8797'
        }

        It "Has health endpoint" {
            $agentPath = Join-Path $projectRoot "AitherOS" "services" "agents" "AitherAutoScale.py"
            $content = Get-Content $agentPath -Raw
            $content | Should -Match '/health'
        }

        It "Integrates with Atlas" {
            $agentPath = Join-Path $projectRoot "AitherOS" "services" "agents" "AitherAutoScale.py"
            $content = Get-Content $agentPath -Raw
            $content | Should -Match 'ATLAS_URL'
            $content | Should -Match 'blast.radius'
        }

        It "Integrates with Demiurge" {
            $agentPath = Join-Path $projectRoot "AitherOS" "services" "agents" "AitherAutoScale.py"
            $content = Get-Content $agentPath -Raw
            $content | Should -Match 'DEMIURGE_URL'
            $content | Should -Match 'request-infrastructure'
        }

        It "Uses MicroScheduler for LLM (never bypasses)" {
            $agentPath = Join-Path $projectRoot "AitherOS" "services" "agents" "AitherAutoScale.py"
            $content = Get-Content $agentPath -Raw
            $content | Should -Match 'MICROSCHEDULER_URL'
            $content | Should -Match 'v1/chat/completions'
        }
    }

    Context "Autoscale Package Structure" {

        It "autoscale/__init__.py exists" {
            $initPath = Join-Path $projectRoot "AitherOS" "services" "agents" "autoscale" "__init__.py"
            Test-Path $initPath | Should -Be $true
        }

        It "autoscale/engine.py exists" {
            $enginePath = Join-Path $projectRoot "AitherOS" "services" "agents" "autoscale" "engine.py"
            Test-Path $enginePath | Should -Be $true
        }

        It "autoscale/policies.py exists" {
            $policiesPath = Join-Path $projectRoot "AitherOS" "services" "agents" "autoscale" "policies.py"
            Test-Path $policiesPath | Should -Be $true
        }

        It "autoscale/providers.py exists" {
            $providersPath = Join-Path $projectRoot "AitherOS" "services" "agents" "autoscale" "providers.py"
            Test-Path $providersPath | Should -Be $true
        }

        It "autoscale/metrics.py exists" {
            $metricsPath = Join-Path $projectRoot "AitherOS" "services" "agents" "autoscale" "metrics.py"
            Test-Path $metricsPath | Should -Be $true
        }
    }

    Context "Configuration Entries" {

        It "services.yaml has AutoScale entry" {
            $servicesPath = Join-Path $projectRoot "AitherOS" "config" "services.yaml"
            $content = Get-Content $servicesPath -Raw
            $content | Should -Match 'AutoScale:'
            $content | Should -Match 'port: 8797'
        }

        It "agent_cards.yaml has autoscale entry" {
            $cardsPath = Join-Path $projectRoot "AitherOS" "config" "agent_cards.yaml"
            $content = Get-Content $cardsPath -Raw
            $content | Should -Match 'autoscale:'
            $content | Should -Match 'auto_scale'
            $content | Should -Match 'cloud_provisioning'
        }
    }
}
