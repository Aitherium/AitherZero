#Requires -Version 7.0

<#
.SYNOPSIS
    Invokes the AitherOS Swarm Coding Engine from the CLI.

.DESCRIPTION
    Dispatches a coding task to the Swarm Coding Engine, which runs 11 specialized
    LLM agents in a 4-phase pipeline: ARCHITECT -> SWARM (8 parallel) -> REVIEW -> JUDGE.

    Three execution modes:
    - llm (default): Bare LLM calls, text-only output. Fast and cheap.
    - forge: AgentForge dispatch with ReAct loops, tools, sandbox, file I/O. Real execution.
    - plan_only: ARCHITECT phase only, returns structured plan for Claude Code to execute.

.PARAMETER Task
    The coding task description.

.PARAMETER Mode
    Execution mode: llm, forge, or plan_only. Defaults to llm.

.PARAMETER Deliver
    Use the delivery pipeline (package + sandbox test + deliver bundle).
    Only available in forge mode.

.PARAMETER Async
    Submit the task asynchronously and return a job ID.

.PARAMETER GenesisUrl
    URL of the Genesis service. Defaults to http://localhost:8001.

.PARAMETER Timeout
    Timeout in seconds. Defaults to 300 (5 minutes).

.EXAMPLE
    Invoke-AitherSwarm -Task "Add pagination to the /api/users endpoint"
    # Quick LLM-based swarm coding

.EXAMPLE
    Invoke-AitherSwarm -Task "Refactor auth middleware for compliance" -Mode forge -Deliver
    # Full forge dispatch with delivery pipeline

.EXAMPLE
    Invoke-AitherSwarm -Task "Design a caching layer for CodeGraph" -Mode plan_only
    # Get structured plan only

.NOTES
    Category: AI
    Dependencies: AitherOS Genesis (port 8001), SwarmCodingEngine
    Platform: Windows, Linux, macOS
#>
function Invoke-AitherSwarm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Task,

        [Parameter()]
        [ValidateSet('llm', 'forge', 'plan_only')]
        [string]$Mode = 'llm',

        [Parameter()]
        [switch]$Deliver,

        [Parameter()]
        [switch]$Async,

        [Parameter()]
        [string]$GenesisUrl,

        [Parameter()]
        [int]$Timeout = 300
    )

    if (-not $GenesisUrl) {
        $ctx = Get-AitherLiveContext
        $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }
    }

    Write-Host "`n  Swarm Coding Engine" -ForegroundColor Cyan
    Write-Host "  Mode: $Mode" -ForegroundColor DarkGray
    if ($Deliver) { Write-Host "  Delivery pipeline: enabled" -ForegroundColor DarkGray }

    # Choose endpoint
    $endpoint = if ($Deliver -and $Mode -eq 'forge') {
        "$GenesisUrl/swarm/run-and-deliver"
    }
    else {
        "$GenesisUrl/swarm/code/sync"
    }

    $body = @{
        problem = $Task
        mode    = $Mode
    }

    try {
        $startTime = Get-Date

        $result = Invoke-RestMethod -Uri $endpoint `
            -Method POST -Body ($body | ConvertTo-Json -Compress) `
            -ContentType 'application/json' -TimeoutSec $Timeout -ErrorAction Stop

        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

        Write-Host "  Completed in ${elapsed}s" -ForegroundColor Green

        # Display results based on mode
        if ($Mode -eq 'plan_only') {
            Write-Host "`n  Architecture Plan:" -ForegroundColor Cyan
            if ($result.plan) {
                Write-Host ($result.plan | ConvertTo-Json -Depth 5) -ForegroundColor White
            }
            elseif ($result.architect_output) {
                Write-Host $result.architect_output -ForegroundColor White
            }
        }
        else {
            # Show phase summaries
            if ($result.phases) {
                foreach ($phase in $result.phases) {
                    $status = if ($phase.status -eq 'completed') { 'Green' } else { 'Yellow' }
                    Write-Host "  $($phase.name): $($phase.status)" -ForegroundColor $status
                }
            }

            # Show final output
            if ($result.output) {
                Write-Host "`n  Output:" -ForegroundColor Cyan
                Write-Host $result.output -ForegroundColor White
            }
            elseif ($result.judge_verdict) {
                Write-Host "`n  Judge Verdict: $($result.judge_verdict)" -ForegroundColor $(
                    if ($result.judge_verdict -match 'pass|approve') { 'Green' } else { 'Yellow' }
                )
            }
        }

        # Report to Strata
        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'swarm-invocation' -Data @{
                task = $Task
                mode = $Mode
                deliver = $Deliver.IsPresent
                duration_s = $elapsed
                outcome = if ($result.status) { $result.status } else { 'completed' }
            }
        }

        return $result
    }
    catch {
        Write-Warning "Swarm invocation failed: $_"
        Write-Warning "Is Genesis running at $GenesisUrl with SwarmCodingEngine enabled?"
        return $null
    }
}
