#Requires -Version 7.0

<#
.SYNOPSIS
    Generates an Agent Notebook from a natural-language prompt.

.DESCRIPTION
    Calls the Genesis POST /notebooks/plan endpoint to have the LLM
    decompose a task description into structured notebook cells. This
    is how agents CREATE notebooks — the notebook IS the plan.

    The LLM analyzes the prompt and generates:
    - Context cells (scope, constraints, domain knowledge)
    - Plan cells (overall strategy)
    - Execution cells (prompts, tool calls, delegations)
    - Checkpoint cells (human review gates)
    - Result cells (outcome records)

.PARAMETER Prompt
    Natural-language description of the task to plan.

.PARAMETER Agent
    Agent identity for planning. Default: atlas (project planner).

.PARAMETER Effort
    Effort level 1-10 for planning depth. Higher = more detailed cells.

.PARAMETER Context
    Additional context to include in the planning prompt.

.PARAMETER Variables
    Pre-defined variables as a hashtable.

.PARAMETER Model
    Optional model override for the planning LLM call.

.EXAMPLE
    Plan-AitherNotebook -Prompt "Build a login system with OAuth2 support"

.EXAMPLE
    Plan-AitherNotebook -Prompt "Deploy the new API to production" -Agent demiurge -Effort 8

.EXAMPLE
    Plan-AitherNotebook -Prompt "Review PR #142 for security issues" -Context "Repository: AitherOS, Language: Python" -Effort 6

.EXAMPLE
    Plan-AitherNotebook -Prompt "Onboard new tenant" -Variables @{ tenant_name = "Acme Corp"; plan = "enterprise" }

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Plan-AitherNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Prompt,

        [string]$Agent = "atlas",

        [ValidateRange(1, 10)]
        [int]$Effort = 5,

        [string]$Context = "",

        [hashtable]$Variables = @{},

        [string]$Model = ""
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{
        prompt = $Prompt
        agent  = $Agent
        effort = $Effort
    }
    if ($Context) {
        $body.context = $Context
    }
    if ($Variables.Count -gt 0) {
        $body.variables = $Variables
    }
    if ($Model) {
        $body.model = $Model
    }

    Write-Host "  Planning notebook..." -ForegroundColor DarkGray -NoNewline

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/plan" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 60 `
            -ErrorAction Stop

        Write-Host " done" -ForegroundColor Green

        # Extract notebook info
        $nb = $result.notebook
        $nbId = if ($nb.id) { $nb.id } elseif ($nb.metadata.id) { $nb.metadata.id } else { "?" }
        $nbName = if ($nb.name) { $nb.name } elseif ($nb.metadata.name) { $nb.metadata.name } else { "Planned Notebook" }
        $cellCount = if ($nb.cells) { $nb.cells.Count } else { 0 }

        Write-Host "  Notebook: $nbId" -ForegroundColor Cyan
        Write-Host "  Name:     $nbName" -ForegroundColor White
        Write-Host "  Cells:    $cellCount" -ForegroundColor DarkGray
        Write-Host "  Agent:    $Agent (effort $Effort)" -ForegroundColor DarkGray

        # Show cell summary
        if ($nb.cells -and $nb.cells.Count -gt 0) {
            Write-Host ""
            foreach ($cell in $nb.cells) {
                $type = if ($cell.type) { $cell.type } else { "?" }
                $name = if ($cell.name) { $cell.name } else { "Unnamed" }
                $typeColor = switch ($type) {
                    "context"    { "DarkCyan" }
                    "plan"       { "Yellow" }
                    "prompt"     { "White" }
                    "tool_call"  { "Green" }
                    "checkpoint" { "Magenta" }
                    "result"     { "Cyan" }
                    default      { "Gray" }
                }
                Write-Host "    [$type]" -ForegroundColor $typeColor -NoNewline
                Write-Host " $name" -ForegroundColor White
            }
        }

        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'notebook-planned' -Data @{
                notebook_id = $nbId
                prompt      = $Prompt.Substring(0, [Math]::Min(200, $Prompt.Length))
                agent       = $Agent
                effort      = $Effort
                cell_count  = $cellCount
            }
        }

        return $result
    }
    catch {
        Write-Host " failed" -ForegroundColor Red
        Write-Error "Planning failed: $($_.Exception.Message)"
    }
}
