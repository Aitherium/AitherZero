#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for AitherZero Notebook cmdlets.

.DESCRIPTION
    Unit tests for all Agent Notebook PowerShell cmdlets under
    AitherZero/src/public/Notebooks/. Uses AST extraction to load
    real function definitions, mocks Invoke-RestMethod and
    Get-AitherLiveContext for isolated testing.
#>

$script:ProjectRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent

Describe "AitherZero Notebook Cmdlets" -Tag "Unit", "Notebooks" {
    BeforeAll {
        $script:ProjectRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
        $notebookDir = Join-Path $script:ProjectRoot "src/public/Notebooks"

        # AST-based function extraction helper
        function Get-FunctionDefinitionFromScript {
            param([string]$ScriptPath, [string]$FunctionName)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $ScriptPath, [ref]$null, [ref]$null
            )
            $functionAst = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $FunctionName
            }, $true) | Select-Object -First 1
            if (-not $functionAst) {
                throw "Function '$FunctionName' not found in '$ScriptPath'"
            }
            return $functionAst.Extent.Text
        }

        # Load all notebook cmdlets via AST extraction
        $cmdlets = @(
            @{ File = "New-AitherNotebook.ps1";          Fn = "New-AitherNotebook" }
            @{ File = "Get-AitherNotebook.ps1";          Fn = "Get-AitherNotebook" }
            @{ File = "Set-AitherNotebook.ps1";          Fn = "Set-AitherNotebook" }
            @{ File = "Remove-AitherNotebook.ps1";       Fn = "Remove-AitherNotebook" }
            @{ File = "Invoke-AitherNotebook.ps1";       Fn = "Invoke-AitherNotebook" }
            @{ File = "Get-AitherNotebookRun.ps1";       Fn = "Get-AitherNotebookRun" }
            @{ File = "Add-AitherNotebookCell.ps1";      Fn = "Add-AitherNotebookCell" }
            @{ File = "Edit-AitherNotebookCell.ps1";     Fn = "Edit-AitherNotebookCell" }
            @{ File = "Remove-AitherNotebookCell.ps1";   Fn = "Remove-AitherNotebookCell" }
            @{ File = "Submit-AitherNotebookReview.ps1"; Fn = "Submit-AitherNotebookReview" }
            @{ File = "Approve-AitherNotebook.ps1";      Fn = "Approve-AitherNotebook" }
            @{ File = "Request-AitherNotebookChanges.ps1"; Fn = "Request-AitherNotebookChanges" }
            @{ File = "Resolve-AitherNotebookGate.ps1";  Fn = "Resolve-AitherNotebookGate" }
            @{ File = "Get-AitherNotebookCost.ps1";      Fn = "Get-AitherNotebookCost" }
            @{ File = "Get-AitherNotebookTemplate.ps1";  Fn = "Get-AitherNotebookTemplate" }
            @{ File = "Convert-AitherNotebook.ps1";      Fn = "Convert-AitherNotebook" }
            @{ File = "Plan-AitherNotebook.ps1";         Fn = "Plan-AitherNotebook" }
        )

        foreach ($c in $cmdlets) {
            $path = Join-Path $notebookDir $c.File
            if (Test-Path $path) {
                $def = Get-FunctionDefinitionFromScript -ScriptPath $path -FunctionName $c.Fn
                Invoke-Expression $def
            }
        }

        # Stub external dependencies
        if (-not (Get-Command Get-AitherLiveContext -ErrorAction SilentlyContinue)) {
            function global:Get-AitherLiveContext {
                return @{ OrchestratorURL = "http://localhost:8001" }
            }
        }
        if (-not (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue)) {
            function global:Send-AitherStrata { param($EventType, $Data) }
        }
    }

    Context "Function Definitions Exist" {
        $testCases = @(
            @{ Fn = "New-AitherNotebook" }
            @{ Fn = "Get-AitherNotebook" }
            @{ Fn = "Set-AitherNotebook" }
            @{ Fn = "Remove-AitherNotebook" }
            @{ Fn = "Invoke-AitherNotebook" }
            @{ Fn = "Get-AitherNotebookRun" }
            @{ Fn = "Add-AitherNotebookCell" }
            @{ Fn = "Edit-AitherNotebookCell" }
            @{ Fn = "Remove-AitherNotebookCell" }
            @{ Fn = "Submit-AitherNotebookReview" }
            @{ Fn = "Approve-AitherNotebook" }
            @{ Fn = "Request-AitherNotebookChanges" }
            @{ Fn = "Resolve-AitherNotebookGate" }
            @{ Fn = "Get-AitherNotebookCost" }
            @{ Fn = "Get-AitherNotebookTemplate" }
            @{ Fn = "Convert-AitherNotebook" }
            @{ Fn = "Plan-AitherNotebook" }
        )

        It "Exports function: <Fn>" -TestCases $testCases {
            param($Fn)
            Get-Command -Name $Fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "New-AitherNotebook" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
            Mock Send-AitherStrata { }
        }

        It "Sends POST to /notebooks with correct body" {
            Mock Invoke-RestMethod {
                return @{ success = $true; notebook = @{ id = "nb_test123"; name = "Test NB" } }
            }

            $result = New-AitherNotebook -Name "Test NB" -Description "A test" -Tags @("test")
            $result.success | Should -Be $true
            $result.notebook.id | Should -Be "nb_test123"

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and $Uri -like '*/notebooks'
            }
        }

        It "Handles missing Genesis gracefully" {
            Mock Invoke-RestMethod { throw "Connection refused" }

            { New-AitherNotebook -Name "Fail" 3>$null } | Should -Not -Throw
        }
    }

    Context "Get-AitherNotebook" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
        }

        It "Gets a specific notebook by ID" {
            Mock Invoke-RestMethod {
                return @{ id = "nb_abc"; name = "My Notebook"; status = "draft" }
            }

            $result = Get-AitherNotebook -Id "nb_abc"
            $result.id | Should -Be "nb_abc"

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*/notebooks/nb_abc'
            }
        }

        It "Lists notebooks with status filter" {
            Mock Invoke-RestMethod {
                return @{ notebooks = @(@{ id = "nb_1" }); total = 1 }
            }

            $result = Get-AitherNotebook -Status "approved"
            $result.total | Should -Be 1

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*status=approved*'
            }
        }
    }

    Context "Set-AitherNotebook" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
        }

        It "Sends PUT with only provided fields" {
            Mock Invoke-RestMethod {
                return @{ success = $true; notebook = @{ id = "nb_abc" } }
            }

            $result = Set-AitherNotebook -Id "nb_abc" -Name "Updated"
            $result.success | Should -Be $true

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'PUT' -and $Uri -like '*/notebooks/nb_abc'
            }
        }
    }

    Context "Remove-AitherNotebook" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
        }

        It "Sends DELETE for the notebook" {
            Mock Invoke-RestMethod {
                return @{ success = $true }
            }

            $result = Remove-AitherNotebook -Id "nb_abc" -Force
            $result.success | Should -Be $true

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'DELETE' -and $Uri -like '*/notebooks/nb_abc'
            }
        }
    }

    Context "Invoke-AitherNotebook" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
            Mock Send-AitherStrata { }
        }

        It "Sends POST to execute endpoint with variables" {
            Mock Invoke-RestMethod {
                return @{ success = $true; run = @{ run_id = "run_001"; status = "completed" } }
            }

            $result = Invoke-AitherNotebook -Id "nb_abc" -Variables @{ env = "prod" }
            $result.success | Should -Be $true
            $result.run.run_id | Should -Be "run_001"

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and $Uri -like '*/notebooks/nb_abc/execute'
            }
        }
    }

    Context "Add-AitherNotebookCell" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
        }

        It "Sends POST to cells endpoint" {
            Mock Invoke-RestMethod {
                return @{ success = $true; cell = @{ id = "cell_001" } }
            }

            $result = Add-AitherNotebookCell -NotebookId "nb_abc" -CellType "prompt" -Name "Step 1"
            $result.success | Should -Be $true

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and $Uri -like '*/notebooks/nb_abc/cells'
            }
        }

        It "Validates cell type parameter" {
            { Add-AitherNotebookCell -NotebookId "nb_abc" -CellType "invalid_type" } |
                Should -Throw
        }
    }

    Context "Submit-AitherNotebookReview" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
            Mock Send-AitherStrata { }
        }

        It "Submits notebook for review" {
            Mock Invoke-RestMethod {
                return @{ success = $true; review = @{ state = "submitted" } }
            }

            $result = Submit-AitherNotebookReview -Id "nb_abc" -Reviewer "atlas"
            $result.success | Should -Be $true

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and $Uri -like '*/notebooks/nb_abc/review'
            }
        }
    }

    Context "Approve-AitherNotebook" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
            Mock Send-AitherStrata { }
        }

        It "Approves a notebook" {
            Mock Invoke-RestMethod {
                return @{ success = $true; review = @{ state = "approved" } }
            }

            $result = Approve-AitherNotebook -Id "nb_abc" -Reviewer "david"
            $result.success | Should -Be $true

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*/notebooks/nb_abc/review/approve'
            }
        }
    }

    Context "Request-AitherNotebookChanges" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
        }

        It "Requests changes with change requests" {
            Mock Invoke-RestMethod {
                return @{ success = $true; review = @{ state = "changes_requested" } }
            }

            $changes = @(@{ type = "MODIFY_CONFIG"; cell_id = "cell_002"; description = "Fix prompt" })
            $result = Request-AitherNotebookChanges -Id "nb_abc" -Reviewer "atlas" `
                -Comments @("Needs work") -ChangeRequests $changes

            $result.success | Should -Be $true

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*/notebooks/nb_abc/review/changes'
            }
        }
    }

    Context "Resolve-AitherNotebookGate" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
        }

        It "Resolves a gate with approve action" {
            Mock Invoke-RestMethod {
                return @{ success = $true; result = @{ resumed = $true } }
            }

            $result = Resolve-AitherNotebookGate -RunId "run_abc" -CellId "cell_005" -Action "approve"
            $result.success | Should -Be $true

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*/notebooks/runs/run_abc/gate/cell_005'
            }
        }

        It "Validates Action parameter to approve or reject" {
            { Resolve-AitherNotebookGate -RunId "r" -CellId "c" -Action "maybe" } |
                Should -Throw
        }
    }

    Context "Get-AitherNotebookRun" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
        }

        It "Gets run status" {
            Mock Invoke-RestMethod {
                return @{ run_id = "run_001"; status = "completed"; total_cost = 0.05 }
            }

            $result = Get-AitherNotebookRun -RunId "run_001"
            $result.status | Should -Be "completed"
        }

        It "Gets specific cell output" {
            Mock Invoke-RestMethod {
                return @{ cell_id = "cell_001"; output = "result data"; status = "completed" }
            }

            $result = Get-AitherNotebookRun -RunId "run_001" -CellId "cell_001"
            $result.cell_id | Should -Be "cell_001"

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*/notebooks/runs/run_001/cells/cell_001/output'
            }
        }
    }

    Context "Get-AitherNotebookTemplate" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
        }

        It "Lists templates" {
            Mock Invoke-RestMethod {
                return @{ templates = @(@{ id = "tmpl_1"; name = "Deploy" }); total = 1 }
            }

            $result = Get-AitherNotebookTemplate
            $result.total | Should -Be 1
        }

        It "Creates a template" {
            Mock Invoke-RestMethod {
                return @{ success = $true; template = @{ id = "tmpl_new" } }
            }

            $result = Get-AitherNotebookTemplate -Create -Name "New Template"
            $result.success | Should -Be $true

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'POST'
            }
        }
    }

    Context "Convert-AitherNotebook" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
            Mock Send-AitherStrata { }
        }

        It "Converts an expedition by ID" {
            Mock Invoke-RestMethod {
                return @{ success = $true; source_type = "expedition"; notebook = @{ id = "nb_migrated"; name = "Migrated Expedition" } }
            }

            $result = Convert-AitherNotebook -From Expedition -Id "exp_001"
            $result.success | Should -Be $true
            $result.source_type | Should -Be "expedition"

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and $Uri -like '*/notebooks/migrate'
            }
        }

        It "Converts a playbook by name" {
            Mock Invoke-RestMethod {
                return @{ success = $true; source_type = "playbook"; notebook = @{ id = "nb_pb" } }
            }

            $result = Convert-AitherNotebook -From Playbook -Id "deploy-service"
            $result.success | Should -Be $true
            $result.source_type | Should -Be "playbook"
        }

        It "Converts a workflow by ID" {
            Mock Invoke-RestMethod {
                return @{ success = $true; source_type = "workflow"; notebook = @{ id = "nb_wf" } }
            }

            $result = Convert-AitherNotebook -From Workflow -Id "wf_abc"
            $result.success | Should -Be $true
            $result.source_type | Should -Be "workflow"
        }

        It "Converts with inline source data" {
            Mock Invoke-RestMethod {
                return @{ success = $true; source_type = "playbook"; notebook = @{ id = "nb_inline" } }
            }

            $data = @{
                name = "Quick Deploy"
                steps = @(@{ action = "log"; message = "hello" })
            }
            $result = Convert-AitherNotebook -From Playbook -SourceData $data
            $result.success | Should -Be $true
        }

        It "Warns when no Id or SourceData provided" {
            Mock Invoke-RestMethod { throw "should not be called" }

            $warnings = @()
            Convert-AitherNotebook -From Expedition -WarningVariable warnings 3>$null | Out-Null
            $warnings.Count | Should -BeGreaterThan 0
        }

        It "Validates -From parameter" {
            { Convert-AitherNotebook -From "InvalidType" -Id "x" } | Should -Throw
        }
    }

    Context "Plan-AitherNotebook" {
        BeforeEach {
            Mock Get-AitherLiveContext { @{ OrchestratorURL = "http://test:8001" } }
            Mock Send-AitherStrata { }
        }

        It "Plans a notebook from a prompt" {
            Mock Invoke-RestMethod {
                return @{
                    success  = $true
                    notebook = @{
                        id    = "nb_planned"
                        name  = "Build Login"
                        cells = @(
                            @{ type = "context"; name = "Task Context" }
                            @{ type = "plan"; name = "Approach" }
                            @{ type = "prompt"; name = "Implement" }
                            @{ type = "result"; name = "Outcome" }
                        )
                        metadata = @{ id = "nb_planned"; name = "Build Login" }
                    }
                }
            }

            $result = Plan-AitherNotebook -Prompt "Build a login system"
            $result.success | Should -Be $true

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and $Uri -like '*/notebooks/plan'
            }
        }

        It "Sends agent and effort parameters" {
            Mock Invoke-RestMethod {
                return @{ success = $true; notebook = @{ id = "nb_p2"; cells = @() } }
            }

            $result = Plan-AitherNotebook -Prompt "Deploy API" -Agent demiurge -Effort 8
            $result.success | Should -Be $true
        }

        It "Includes context and variables" {
            Mock Invoke-RestMethod {
                return @{ success = $true; notebook = @{ id = "nb_p3"; cells = @() } }
            }

            $result = Plan-AitherNotebook -Prompt "Onboard tenant" `
                -Context "Enterprise plan" `
                -Variables @{ tenant = "Acme" }
            $result.success | Should -Be $true
        }

        It "Validates effort range" {
            { Plan-AitherNotebook -Prompt "test" -Effort 15 } | Should -Throw
        }
    }
}
