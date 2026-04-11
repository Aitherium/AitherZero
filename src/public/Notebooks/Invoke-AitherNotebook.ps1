#Requires -Version 7.0

<#
.SYNOPSIS
    Executes an Agent Notebook and returns the run handle.

.DESCRIPTION
    Triggers execution of a notebook via Genesis. The notebook cells are
    executed according to the notebook's execution mode (sequential, parallel,
    expedition, dark_factory). Returns the run ID for status polling.

.PARAMETER Id
    The notebook ID to execute.

.PARAMETER Variables
    Optional hashtable of runtime variables to inject into cell interpolation.

.PARAMETER Mode
    Execution mode override (sequential, parallel, expedition, dark_factory).

.PARAMETER Poll
    If set, poll for completion with a spinner animation.

.PARAMETER TimeoutSec
    Polling timeout in seconds (default 300).

.EXAMPLE
    Invoke-AitherNotebook -Id "nb_abc123"

.EXAMPLE
    Invoke-AitherNotebook -Id "nb_abc123" -Variables @{environment="prod"} -Poll

.NOTES
    Category: Notebooks
    Dependencies: Genesis service
    Platform: Cross-platform
#>
function Invoke-AitherNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Id,

        [hashtable]$Variables = @{},

        [ValidateSet("sequential", "parallel", "expedition", "dark_factory")]
        [string]$Mode = "sequential",

        [switch]$Poll,

        [int]$TimeoutSec = 300
    )

    $ctx = Get-AitherLiveContext
    $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }

    $body = @{
        variables = $Variables
        mode      = $Mode
    }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/$Id/execute" `
            -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' `
            -TimeoutSec 30 `
            -ErrorAction Stop

        $runId = $result.run.run_id
        $status = $result.run.status
        Write-Host "  Notebook execution started" -ForegroundColor Cyan
        Write-Host "  Run ID: " -NoNewline -ForegroundColor DarkGray
        Write-Host "$runId" -ForegroundColor Green
        Write-Host "  Status: $status" -ForegroundColor DarkGray

        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'notebook-executed' -Data @{
                notebook_id = $Id
                run_id      = $runId
                mode        = $Mode
                status      = $status
            }
        }

        if ($Poll -and $status -notin @("completed", "failed", "paused")) {
            $spinner = @('|', '/', '-', '\')
            $spinIdx = 0
            $startTime = Get-Date

            Write-Host "  Polling for completion..." -ForegroundColor DarkGray
            while ($true) {
                Start-Sleep -Seconds 2
                $elapsed = ((Get-Date) - $startTime).TotalSeconds
                if ($elapsed -ge $TimeoutSec) {
                    Write-Warning "Polling timed out after ${TimeoutSec}s"
                    break
                }

                try {
                    $runStatus = Invoke-RestMethod -Uri "$GenesisUrl/notebooks/runs/$runId" `
                        -Method GET -TimeoutSec 10 -ErrorAction Stop
                    $status = $runStatus.status

                    $ch = $spinner[$spinIdx % $spinner.Count]
                    Write-Host "`r  $ch $status ($([math]::Round($elapsed))s)" -NoNewline -ForegroundColor DarkGray
                    $spinIdx++

                    if ($status -in @("completed", "failed", "paused")) {
                        Write-Host ""
                        $color = switch ($status) {
                            "completed" { "Green" }
                            "failed"    { "Red" }
                            "paused"    { "Yellow" }
                        }
                        Write-Host "  Final status: $status" -ForegroundColor $color
                        return $runStatus
                    }
                }
                catch {
                    # Retry on transient error
                }
            }
        }

        return $result
    }
    catch {
        Write-Warning "Failed to execute notebook $Id`: $_"
        Write-Host "  Is Genesis running? Check with: Get-AitherStatus" -ForegroundColor Yellow
    }
}
