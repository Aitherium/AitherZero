#Requires -Version 7.0

<#
.SYNOPSIS
    Submits an async job to the AitherOS Genesis orchestrator.

.DESCRIPTION
    Dispatches a long-running task to the Genesis job queue for asynchronous execution.
    Returns a job ID that can be polled for status. Supports playbook submission,
    agent dispatch, and arbitrary task payloads.

    This enables non-blocking orchestration: submit a job, continue working, and
    check results later.

.PARAMETER Task
    Description of the task to execute.

.PARAMETER Type
    Job type: playbook, agent, script, or custom. Defaults to custom.

.PARAMETER Playbook
    Name of a playbook to run asynchronously (sets Type to 'playbook').

.PARAMETER Agent
    Agent to dispatch (sets Type to 'agent'). E.g., 'demiurge', 'athena'.

.PARAMETER Parameters
    Hashtable of parameters to pass to the job.

.PARAMETER Priority
    Job priority: low, normal, high, critical. Defaults to normal.

.PARAMETER GenesisUrl
    URL of the Genesis service. Defaults to http://localhost:8001.

.PARAMETER Poll
    After submission, poll for completion instead of returning immediately.
    Shows a progress indicator.

.PARAMETER PollInterval
    Poll interval in seconds. Defaults to 5.

.PARAMETER PollTimeout
    Maximum time to poll in seconds. Defaults to 600 (10 minutes).

.EXAMPLE
    Submit-AitherJob -Playbook "deploy-prod" -Parameters @{ Environment = "production" }
    # Submit a deployment playbook asynchronously

.EXAMPLE
    Submit-AitherJob -Agent "demiurge" -Task "Refactor auth module" -Priority high
    # Submit an agent task at high priority

.EXAMPLE
    $job = Submit-AitherJob -Task "Run full test suite" -Type script -Poll
    # Submit and wait for completion

.EXAMPLE
    Submit-AitherJob -Task "Generate monthly report" | ForEach-Object { $_.job_id }
    # Get job ID for later status check

.NOTES
    Category: Orchestration
    Dependencies: AitherOS Genesis (port 8001)
    Platform: Windows, Linux, macOS
#>
function Submit-AitherJob {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Task,

        [Parameter()]
        [ValidateSet('playbook', 'agent', 'script', 'custom')]
        [string]$Type = 'custom',

        [Parameter()]
        [string]$Playbook,

        [Parameter()]
        [string]$Agent,

        [Parameter()]
        [hashtable]$Parameters = @{},

        [Parameter()]
        [ValidateSet('low', 'normal', 'high', 'critical')]
        [string]$Priority = 'normal',

        [Parameter()]
        [string]$GenesisUrl,

        [Parameter()]
        [switch]$Poll,

        [Parameter()]
        [int]$PollInterval = 5,

        [Parameter()]
        [int]$PollTimeout = 600
    )

    if (-not $GenesisUrl) {
        $ctx = Get-AitherLiveContext
        $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }
    }

    # Auto-set type from parameters
    if ($Playbook) { $Type = 'playbook'; if (-not $Task) { $Task = "Run playbook: $Playbook" } }
    if ($Agent) { $Type = 'agent'; if (-not $Task) { $Task = "Agent dispatch: $Agent" } }

    if (-not $Task) {
        Write-Error "Task description is required. Use -Task, -Playbook, or -Agent."
        return
    }

    # Build job payload
    $body = @{
        task       = $Task
        type       = $Type
        priority   = $Priority
        parameters = $Parameters
        source     = 'aitherzero-cli'
        submitted  = (Get-Date).ToUniversalTime().ToString("o")
    }
    if ($Playbook) { $body.playbook = $Playbook }
    if ($Agent) { $body.agent = $Agent }

    try {
        Write-Host "`n  Submitting job: $Task" -ForegroundColor Cyan
        Write-Host "  Type: $Type | Priority: $Priority" -ForegroundColor DarkGray

        $result = Invoke-RestMethod -Uri "$GenesisUrl/api/jobs/submit" `
            -Method POST -Body ($body | ConvertTo-Json -Depth 5 -Compress) `
            -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop

        $jobId = if ($result.job_id) { $result.job_id } elseif ($result.id) { $result.id } else { 'unknown' }
        Write-Host "  Job submitted: $jobId" -ForegroundColor Green

        # Report to Strata
        if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
            Send-AitherStrata -EventType 'job-submitted' -Data @{
                job_id   = $jobId
                type     = $Type
                priority = $Priority
                task     = $Task
            }
        }

        if (-not $Poll) {
            return $result
        }

        # Poll for completion
        Write-Host "  Polling for completion (interval: ${PollInterval}s, timeout: ${PollTimeout}s)" -ForegroundColor DarkGray
        $startTime = [DateTime]::UtcNow
        $spinChars = @('|', '/', '-', '\')
        $spinIdx = 0

        while (([DateTime]::UtcNow - $startTime).TotalSeconds -lt $PollTimeout) {
            Start-Sleep -Seconds $PollInterval

            try {
                $status = Invoke-RestMethod -Uri "$GenesisUrl/api/jobs/$jobId/status" `
                    -Method GET -TimeoutSec 10 -ErrorAction Stop

                $jobStatus = if ($status.status) { $status.status } else { 'unknown' }

                $spin = $spinChars[$spinIdx % 4]
                $spinIdx++
                $elapsed = [math]::Round(([DateTime]::UtcNow - $startTime).TotalSeconds)
                Write-Host "`r  $spin $jobStatus (${elapsed}s)" -NoNewline -ForegroundColor DarkGray

                if ($jobStatus -in @('completed', 'success', 'failed', 'error', 'cancelled')) {
                    Write-Host ""
                    $color = if ($jobStatus -in @('completed', 'success')) { 'Green' } else { 'Red' }
                    Write-Host "  Job $jobStatus" -ForegroundColor $color

                    if ($status.result) {
                        return $status.result
                    }
                    return $status
                }
            }
            catch {
                Write-Verbose "Poll error: $_"
            }
        }

        Write-Warning "  Poll timeout reached ($PollTimeout s). Job $jobId may still be running."
        Write-Warning "  Check status: Invoke-RestMethod '$GenesisUrl/api/jobs/$jobId/status'"
        return $result
    }
    catch {
        Write-Warning "Job submission failed: $_"
        Write-Warning "Is Genesis running at $GenesisUrl?"
        return $null
    }
}
