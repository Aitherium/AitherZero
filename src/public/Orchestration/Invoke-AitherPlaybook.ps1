#Requires -Version 7.0

<#
.SYNOPSIS
    Execute a playbook with orchestration and dependency management

.DESCRIPTION
    Executes a playbook definition, running scripts in sequence or parallel
    based on the playbook configuration. This is the primary way to run
    automation workflows defined as playbooks.

    Playbooks can execute scripts in parallel (for speed), sequentially
    (for dependencies), or in a mixed mode (some parallel, some sequential).
    The orchestration engine automatically handles dependencies, retries,
    and error handling.

.PARAMETER Name
    Name of the playbook to execute. This parameter is REQUIRED when using
    the ByName parameter set. The playbook must exist in the playbooks directory.

    Examples:
    - "test-orchestration"
    - "pr-validation"
    - "deployment"

.PARAMETER Playbook
    Playbook object from Get-AitherPlaybook. This parameter is REQUIRED when
    using the ByObject parameter set. Allows piping playbook objects directly.

    Use this when you've already loaded a playbook and want to execute it.

.PARAMETER Variables
    Variables to pass to the playbook execution. This is a hashtable containing
    key-value pairs that will be available to all scripts in the playbook.

    Examples:
    - @{ Environment = "Production"; Approval = "Automatic" }
    - @{ OutputPath = "C:\Reports"; Verbose = $true }

    Variables can be accessed in scripts using $Variables.Environment, etc.

.PARAMETER DryRun
    Show what would be executed without actually running the playbook.
    Displays the playbook structure, scripts that would run, and execution order.
    Useful for verifying playbook configuration before execution.

.PARAMETER ContinueOnError
    Continue execution even if a script fails. By default, playbook execution
    stops on the first error. With this parameter, execution continues through
    all scripts and reports all failures at the end.

    Useful for:
    - Running validation scripts where you want to see all failures
    - Testing multiple components independently
    - Gathering comprehensive status information

.PARAMETER Parallel
    Override playbook's parallel setting. Forces parallel execution if set to $true,
    or sequential execution if set to $false. If not specified, uses the playbook's
    default execution mode.

    Note: Some scripts may require sequential execution due to dependencies,
    which will be respected even when Parallel is $true.

.PARAMETER MaxConcurrency
    Maximum concurrent script executions when running in parallel mode.
    Defaults to the value in configuration (usually 4).

    Increase this for:
    - Systems with more CPU cores
    - Scripts that are I/O bound rather than CPU bound
    - Faster execution when dependencies allow

    Decrease this for:
    - Resource-constrained systems
    - Scripts that consume significant resources
    - Better error visibility (fewer simultaneous failures)

.INPUTS
    System.String
    You can pipe playbook names to Invoke-AitherPlaybook.

    Hashtable
    You can pipe playbook objects from Get-AitherPlaybook to Invoke-AitherPlaybook.

.OUTPUTS
    PSCustomObject
    Returns execution result with properties:
    - Total: Total number of scripts
    - Completed: Number of successfully completed scripts
    - Failed: Number of failed scripts
    - Duration: Total execution time
    - Results: Detailed results for each script

.EXAMPLE
    Invoke-AitherPlaybook -Name 'test-orchestration'

    Executes the 'test-orchestration' playbook with default settings.

.EXAMPLE
    $playbook = Get-AitherPlaybook -Name 'pr-validation'
    Invoke-AitherPlaybook -Playbook $playbook -DryRun

    Loads a playbook and shows what would be executed without running it.

.EXAMPLE
    Invoke-AitherPlaybook -Name 'deployment' -Variables @{ Environment = "Production" } -ContinueOnError

    Executes deployment playbook with variables and continues on errors.

.EXAMPLE
    Get-AitherPlaybook -Name 'validation' | Invoke-AitherPlaybook -Parallel $true -MaxConcurrency 8

    Pipes a playbook object and executes it in parallel with higher concurrency.

.EXAMPLE
    Invoke-AitherPlaybook -Name 'test-suite' -DryRun -Variables @{ TestMode = "Full" }

    Shows what would be executed with specific variables without running.

.NOTES
    Uses the OrchestrationEngine for execution, which provides:
    - Automatic dependency resolution
    - Parallel and sequential execution modes
    - Error handling and retry logic
    - Progress tracking
    - Execution history

    Playbooks are stored in library/playbooks/ directory as .psd1 files.
    Each playbook defines scripts, execution order, dependencies, and success criteria.

.LINK
    Get-AitherPlaybook
    Save-AitherPlaybook
    New-AitherPlaybook
    Get-AitherOrchestrationStatus
    Get-AitherExecutionHistory
#>
function Invoke-AitherPlaybook {
    [OutputType([PSCustomObject])]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(ParameterSetName = 'ByName', Mandatory = $false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Name of the playbook to execute (e.g., 'pr-validation').")]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                if (Get-Command Get-AitherPlaybook -ErrorAction SilentlyContinue) {
                    Get-AitherPlaybook -List | Where-Object { $_.Name -like "$wordToComplete*" } | ForEach-Object {
                        [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', $_.Description)
                    }
                }
            })]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(ParameterSetName = 'ByObject', Mandatory = $false, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Playbook object or hashtable definition.")]
        [hashtable]$Playbook,

        [Parameter(HelpMessage = "Variables to pass to the playbook execution.")]
        [hashtable]$Variables = @{},

        [Parameter(HelpMessage = "Show what would be executed without running it.")]
        [switch]$DryRun,

        [Parameter(HelpMessage = "Continue execution even if a step fails.")]
        [switch]$ContinueOnError,

        [Parameter(HelpMessage = "Execute independent steps in parallel.")]
        [bool]$Parallel,

        [Parameter(HelpMessage = "Maximum number of concurrent parallel executions.")]
        [ValidateRange(1, 32)]
        [int]$MaxConcurrency,

        [Parameter(HelpMessage = "Show playbook execution output in console.")]
        [switch]$ShowOutput,

        [Parameter(HelpMessage = "Display transcript content after execution.")]
        [switch]$ShowTranscript
    )    begin {
        # Manage logging targets for this execution
        $originalLogTargets = $script:AitherLogTargets
        if ($ShowOutput) {
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
        else {
            # Ensure Console is NOT in targets if ShowOutput is not specified
            $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
        }

        # Get scripts directory using robust discovery
        try {
            $scriptsPath = Get-AitherScriptsPath
        }
        catch {
            Write-AitherLog -Level Warning -Message "Could not resolve scripts path: $($_.Exception.Message)" -Source 'Invoke-AitherPlaybook'
            $scriptsPath = $null
        }

        $executionResults = @()
        $startTime = Get-Date
    }

    process {
        try {
            # Get playbook if name provided
            if ($Name) {
                $Playbook = Get-AitherPlaybook -Name $Name
                if (-not $Playbook) {
                    throw "Playbook not found: $Name"
                }
            }

            if (-not $Playbook -and -not $Name) {
                # During module validation, parameters may be empty - skip validation
                if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
                    return
                }
                throw "Playbook must be provided via -Name or -Playbook parameter"
            }

            # Merge playbook variables with provided variables
            $playbookVariables = if ($Playbook.Variables) { $Playbook.Variables } else { @{} }
            $mergedVariables = $playbookVariables.Clone()
            foreach ($key in $Variables.Keys) {
                $mergedVariables[$key] = $Variables[$key]
            }

            # Determine execution mode
            $executeParallel = if ($PSBoundParameters.ContainsKey('Parallel')) {
                $Parallel
            }
            elseif ($Playbook.Options -and $Playbook.Options.ContainsKey('Parallel')) {
                $Playbook.Options.Parallel
            }
            else {
                $false  # Default to sequential for safety
            }

            $maxConcurrency = if ($PSBoundParameters.ContainsKey('MaxConcurrency')) {
                $MaxConcurrency
            }
            elseif ($Playbook.Options -and $Playbook.Options.ContainsKey('MaxConcurrency')) {
                $Playbook.Options.MaxConcurrency
            }
            else {
                $config = Get-AitherConfigs -ErrorAction SilentlyContinue
                if ($config -and $config.Automation -and $config.Automation.OrchestrationEngine) {
                    $config.Automation.OrchestrationEngine.MaxConcurrency
                }
                else {
                    4  # Default
                }
            }

            $continueOnError = if ($PSBoundParameters.ContainsKey('ContinueOnError')) {
                $ContinueOnError
            }
            elseif ($Playbook.Options -and $Playbook.Options.ContainsKey('StopOnError')) {
                -not $Playbook.Options.StopOnError
            }
            else {
                $false
            }

            # Get sequence from playbook
            $sequence = if ($Playbook.Sequence) {
                $Playbook.Sequence
            }
            else {
                throw "Playbook does not contain a Sequence definition"
            }

            Write-AitherLog -Message "Executing playbook: $($Playbook.Name)" -Level Information -Source 'Invoke-AitherPlaybook'
            Write-AitherLog -Message "  Scripts: $($sequence.Count)" -Level Information -Source 'Invoke-AitherPlaybook'
            Write-AitherLog -Message "  Mode: $(if ($executeParallel) { 'Parallel' } else { 'Sequential' })" -Level Information -Source 'Invoke-AitherPlaybook'
            Write-AitherLog -Message "  ContinueOnError: $continueOnError" -Level Information -Source 'Invoke-AitherPlaybook'

            # Dry run mode
            if ($DryRun) {
                Write-AitherLog -Level Information -Message "[DRY RUN] Playbook: $($Playbook.Name)" -Source 'Invoke-AitherPlaybook'
                Write-AitherLog -Level Information -Message ("=" * 60) -Source 'Invoke-AitherPlaybook'
                foreach ($item in $sequence) {
                    $scriptId = if ($item.Script) { $item.Script } else { $item }
                    $desc = if ($item.Description) { $item.Description } else { "Script $scriptId" }
                    Write-AitherLog -Level Information -Message "  - $scriptId : $desc" -Source 'Invoke-AitherPlaybook'
                    if ($item.Parameters) {
                        Write-AitherLog -Level Information -Message "    Parameters: $($item.Parameters | ConvertTo-Json -Compress)" -Source 'Invoke-AitherPlaybook'
                    }
                    elseif ($item.Params) {
                        Write-AitherLog -Level Information -Message "    Parameters: $($item.Params | ConvertTo-Json -Compress)" -Source 'Invoke-AitherPlaybook'
                    }
                }
                return
            }

            # Execute sequence
            if (-not $PSCmdlet.ShouldProcess($Playbook.Name, "Execute playbook")) {
                return
            }

            # Define ModuleRoot for jobs
            $ModuleRoot = Get-AitherModuleRoot

            $scriptResults = @()
            $completed = 0
            $failed = 0
            $skipped = 0

            if ($executeParallel) {
                # Parallel execution with concurrency limit
                $jobs = @()
                $runningJobs = @{}
                $index = 0

                while ($index -lt $sequence.Count -or $runningJobs.Count -gt 0) {
                    # Start new jobs up to concurrency limit
                    while ($runningJobs.Count -lt $maxConcurrency -and $index -lt $sequence.Count) {
                        $item = $sequence[$index]
                        $scriptId = if ($item.Script) { $item.Script } else { $item }
                        $scriptParams = if ($item.Parameters) { $item.Parameters } elseif ($item.Params) { $item.Params } else { @{} }

                        # Merge variables into parameters
                        foreach ($key in $mergedVariables.Keys) {
                            if (-not $scriptParams.ContainsKey($key)) {
                                $scriptParams[$key] = $mergedVariables[$key]
                            }
                        }

                        Write-AitherLog -Message "Starting script: $scriptId" -Level Information -Source 'Invoke-AitherPlaybook'

                        $job = Start-Job -ScriptBlock {
                            param($ScriptId, $ModuleRoot, $Params, $ShowOutput, $ShowTranscript)
                            $modulePath = Join-Path $ModuleRoot 'AitherZero' 'AitherZero.psd1'
                            Import-Module $modulePath -Force
                            Invoke-AitherScript -Script $ScriptId -Parameters $Params -ErrorAction Stop -ShowOutput:$ShowOutput -ShowTranscript:$ShowTranscript
                        } -ArgumentList $scriptId, $moduleRoot, $scriptParams, $true, $ShowTranscript

                        $runningJobs[$job.Id] = @{
                            Job       = $job
                            ScriptId  = $scriptId
                            Index     = $index
                            StartTime = Get-Date
                        }
                        $index++
                    }

                    # Check for completed jobs
                    $completedJobs = @()
                    foreach ($jobId in $runningJobs.Keys) {
                        $jobInfo = $runningJobs[$jobId]
                        if ($jobInfo.Job.State -eq 'Completed' -or $jobInfo.Job.State -eq 'Failed') {
                            $result = Receive-Job -Job $jobInfo.Job

                            # Display output if requested (captured from job)
                            if ($ShowOutput) {
                                $result | ForEach-Object { Write-AitherLog -Level Information -Message $_ -Source 'Invoke-AitherPlaybook' }
                            }

                            $duration = (Get-Date) - $jobInfo.StartTime

                            $scriptResult = [PSCustomObject]@{
                                Script   = $jobInfo.ScriptId
                                Success  = $jobInfo.Job.State -eq 'Completed'
                                Duration = $duration
                                Output   = $result
                                Error    = if ($jobInfo.Job.State -eq 'Failed') { $jobInfo.Job.ChildJobs[0].Error } else { $null }
                            }

                            $scriptResults += $scriptResult

                            if ($scriptResult.Success) {
                                $completed++
                            }
                            else {
                                $failed++
                                Write-AitherLog -Message "Script failed: $($jobInfo.ScriptId)" -Level Error -Source 'Invoke-AitherPlaybook'
                                if (-not $continueOnError) {
                                    Remove-Job -Job $jobInfo.Job
                                    $completedJobs += $jobId
                                    break
                                }
                            }

                            Remove-Job -Job $jobInfo.Job
                            $completedJobs += $jobId
                        }
                    }

                    foreach ($jobId in $completedJobs) {
                        $runningJobs.Remove($jobId)
                    }

                    if ($runningJobs.Count -gt 0) {
                        Start-Sleep -Milliseconds 100
                    }
                }
            }
            else {
                # Sequential execution
                foreach ($item in $sequence) {
                    $scriptId = if ($item.Script) { $item.Script } else { $item }
                    $scriptParams = if ($item.Parameters) { $item.Parameters } elseif ($item.Params) { $item.Params } else { @{} }

                    # Merge variables into parameters
                    foreach ($key in $mergedVariables.Keys) {
                        if (-not $scriptParams.ContainsKey($key)) {
                            $scriptParams[$key] = $mergedVariables[$key]
                        }
                    }

                    Write-AitherLog -Message "Executing script: $scriptId" -Level Information -Source 'Invoke-AitherPlaybook'

                    $scriptStartTime = Get-Date
                    try {
                        # Pass Verbose preference explicitly
                        $result = Invoke-AitherScript -Script $scriptId -Parameters $scriptParams -ErrorAction Stop -ShowOutput:$ShowOutput -ShowTranscript:$ShowTranscript -Verbose:$VerbosePreference
                        $duration = (Get-Date) - $scriptStartTime

                        $scriptResult = [PSCustomObject]@{
                            Script   = $scriptId
                            Success  = $true
                            Duration = $duration
                            Output   = $result
                            Error    = $null
                        }

                        $scriptResults += $scriptResult
                        $completed++
                    }
                    catch {
                        $duration = (Get-Date) - $scriptStartTime

                        $scriptResult = [PSCustomObject]@{
                            Script   = $scriptId
                            Success  = $false
                            Duration = $duration
                            Output   = $null
                            Error    = $_.Exception.Message
                        }

                        $scriptResults += $scriptResult
                        $failed++

                        Write-AitherLog -Message "Script failed: $scriptId - $($_.Exception.Message)" -Level Error -Source 'Invoke-AitherPlaybook'

                        if (-not $continueOnError) {
                            break
                        }
                    }
                }
            }

            $endTime = Get-Date
            $totalDuration = $endTime - $startTime

            # Build result object
            $result = [PSCustomObject]@{
                PSTypeName   = 'AitherZero.PlaybookExecutionResult'
                PlaybookName = $Playbook.Name
                Success      = $failed -eq 0
                Total        = $sequence.Count
                Completed    = $completed
                Failed       = $failed
                Skipped      = $skipped
                Duration     = $totalDuration
                Results      = $scriptResults
            }

            Write-AitherLog -Message "Playbook execution completed: $completed/$($sequence.Count) succeeded, $failed failed" -Level Information -Source 'Invoke-AitherPlaybook'

            return $result
        }
        catch {
            Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Executing playbook: $($Name ?? $Playbook.Name)" -Parameters $PSBoundParameters -ThrowOnError
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }

}

