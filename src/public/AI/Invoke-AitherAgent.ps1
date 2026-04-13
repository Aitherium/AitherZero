<#
.SYNOPSIS
    Unified CLI agent interface that uses AitherOS backend services.

.DESCRIPTION
    This function provides a unified interface to interact with AitherOS agents via the backend services.
    It connects to Genesis (port 8001) instead of external CLI tools.

    Infrastructure Intent Auto-Routing:
    When the prompt matches infrastructure patterns (terraform, docker, kubernetes, deploy,
    ec2, rds, vpc, etc.) or -Delegate is set to 'infrastructure', the request is automatically
    routed through the IDI (Intent-Driven Infrastructure) pipeline via Invoke-AitherIDI.
    This gives you: intent classification → resource extraction → live discovery → cost
    projection → execution with approval gates → drift monitoring.

    Use -NoIDI to bypass auto-routing and force the request through the standard agent path.

    DEPRECATED: External CLI tools (Claude, Gemini, Codex) wrappers are deprecated.
    Use this function to interact with AitherOS backend services instead.

.PARAMETER Prompt
    The prompt or instruction to send to the agent.

.PARAMETER Context
    Optional context data (code, logs, etc.) to include.

.PARAMETER ContextFile
    Path to a file whose contents should be used as context.

.PARAMETER Model
    Model to use (e.g., gemini-2.5-flash, gpt-4o). Defaults to orchestrator default.

.PARAMETER Persona
    Persona to use (e.g., aither, terra).

.PARAMETER Delegate
    Delegate to a specific agent (e.g., coder, analyst, infrastructure).
    'infrastructure' routes through the IDI pipeline automatically.

.PARAMETER Stream
    Stream output in real-time.

.PARAMETER OrchestratorUrl
    URL of the Genesis service. Defaults to http://localhost:8001.

.PARAMETER NoIDI
    Bypass infrastructure auto-routing. Forces the request through the standard agent path
    even if the prompt matches infrastructure patterns.

.EXAMPLE
    Invoke-AitherAgent -Prompt "Explain this code" -Context (Get-Content ./script.ps1 -Raw)

.EXAMPLE
    Get-Content ./error.log | Invoke-AitherAgent -Prompt "Analyze this error log"

.EXAMPLE
    Invoke-AitherAgent -Prompt "Write a function" -Delegate coder -Model gemini-2.5-flash

.EXAMPLE
    Invoke-AitherAgent -Prompt "Deploy 3 t3.medium EC2 instances in us-east-1"
    # Auto-routes through IDI pipeline

.EXAMPLE
    Invoke-AitherAgent -Prompt "Spin up a Kubernetes cluster with 5 nodes" -Delegate infrastructure
    # Explicit IDI routing via delegate
#>
function Invoke-AitherAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Prompt,

        [Parameter(ValueFromPipeline = $true)]
        [string]$Context,

        [Parameter()]
        [string]$ContextFile,

        [Parameter()]
        [switch]$NoIDI,

        [Parameter()]
        [string]$Model,

        [Parameter()]
        [string]$Persona,

        [Parameter()]
        [string]$Delegate,

        [Parameter()]
        [switch]$Stream,

        [Parameter()]
        [string]$OrchestratorUrl,

        [Parameter(HelpMessage = "Effort level (1-10) for direct MicroScheduler routing. 1-2=small model, 3-6=orchestrator, 7-10=reasoning.")]
        [ValidateRange(1, 10)]
        [int]$Effort,

        [Parameter(HelpMessage = "URL of MicroScheduler for direct effort-based routing. Defaults to http://localhost:8150.")]
        [string]$SchedulerUrl
    )

    begin {
        if (-not $OrchestratorUrl) {
            $agentCtx = Get-AitherLiveContext
            $OrchestratorUrl = if ($agentCtx.OrchestratorURL) { $agentCtx.OrchestratorURL } else { "http://localhost:8001" }
        }
        $contextData = @()
        
        # Check if orchestrator is available
        $genesisAvailable = $false
        try {
            $response = Invoke-WebRequest -Uri "$OrchestratorUrl/status" -Method GET -TimeoutSec 5 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $genesisAvailable = $true
            }
        } catch {
            Write-Verbose "Genesis unavailable at $OrchestratorUrl — standalone LLM fallback available"
        }

        if (-not $genesisAvailable) {
            # Fall back to standalone LLM if available
            if (Get-Command -Name Invoke-AitherLLM -ErrorAction SilentlyContinue) {
                Write-Host "`n  Genesis offline — routing through standalone LLM" -ForegroundColor Yellow
                $llmParams = @{ Prompt = $Prompt }
                if ($Effort -gt 0) { $llmParams.Effort = $Effort }
                if ($Model) { $llmParams.Model = $Model }
                return Invoke-AitherLLM @llmParams
            } else {
                Write-Warning "Genesis is not responding and standalone LLM not available."
                Write-Warning "Start services with: Start-AitherOS -Group core"
                return
            }
        }
    }

    process {
        if ($Context) {
            $contextData += $Context
        }
    }

    end {
        # Gather context from file if specified
        if ($ContextFile -and (Test-Path $ContextFile)) {
            $contextData += Get-Content -Path $ContextFile -Raw
        }

        $fullContext = $contextData -join "`n"

        # ─── IDI Auto-Routing ────────────────────────────────────────
        # Check if this is an infrastructure intent that should route through IDI.
        # Triggers: -Delegate infrastructure, or prompt matches infra patterns.
        # Skip if -NoIDI is set.
        $useIDI = $false
        if (-not $NoIDI) {
            if ($Delegate -eq 'infrastructure') {
                $useIDI = $true
                Write-Verbose "IDI: Explicit infrastructure delegation"
            }
            elseif (-not $Delegate) {
                # Auto-detect infrastructure intent using the same patterns as IntentEngine.py
                if (Get-Command -Name Test-InfrastructureIntent -ErrorAction SilentlyContinue) {
                    $useIDI = Test-InfrastructureIntent -Prompt $Prompt
                } else {
                    # Inline fallback if IDI module not loaded yet
                    $infraPatterns = @(
                        '\bterraform\b', '\bdocker\b', '\bkubernetes\b', '\bk8s\b',
                        '\bdeploy\s+\d+', '\binfra(structure)?\b', '\bcluster\b',
                        '\bvm\b', '\bec2\b', '\brds\b', '\bs3\b', '\bvpc\b',
                        '\belb\b', '\beks\b', '\becs\b', '\blambda\b', '\bfargate\b',
                        '\bscale\b.*\binstanc', '\bprovision\b', '\bspin\s+up\b',
                        '\btear\s+down\b', '\bcloud\b.*\b(deploy|provision|create)\b',
                        '\baws\b', '\bazure\b', '\bgcp\b', '\bgke\b', '\baks\b',
                        '\bcontainer\b', '\bpod\b', '\bnamespace\b', '\bhelm\b',
                        '\bload\s*balanc', '\bauto\s*scal', '\bserverless\b',
                        '\bnuke\b.*\bresource', '\borphan\b.*\bresource',
                        '\bcleanup\b.*\binfra', '\bdrift\b.*\bdetect'
                    )
                    foreach ($pattern in $infraPatterns) {
                        if ($Prompt -match $pattern) {
                            $useIDI = $true
                            Write-Verbose "IDI: Auto-detected infrastructure intent (pattern: $pattern)"
                            break
                        }
                    }
                }
            }
        }

        if ($useIDI) {
            # Route through IDI pipeline
            Write-Host "`n  ⚡ Infrastructure intent detected — routing through IDI pipeline" -ForegroundColor Cyan
            Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

            if (-not (Get-Command -Name Invoke-AitherIDI -ErrorAction SilentlyContinue)) {
                Write-Error "IDI module not loaded. Run: Import-Module AitherZero -Force"
                return
            }

            $idiParams = @{
                Prompt = $Prompt
            }

            # Pass through context if present
            if ($fullContext) {
                # Prepend context to the prompt for IDI
                $idiParams.Prompt = "Context:`n$fullContext`n`nTask: $Prompt"
            }

            # Map relevant parameters
            if ($Model) {
                Write-Verbose "IDI: Model preference '$Model' noted (IDI uses effort-based routing)"
            }

            return Invoke-AitherIDI @idiParams
        }

        # ─── Effort-Based Direct Routing ────────────────────────────────
        # When -Effort is specified, route directly to MicroScheduler:8150
        # bypassing Genesis for lower latency. Effort tiers:
        #   1-2  → small model (llama3.2)
        #   3-6  → orchestrator (aither-orchestrator)
        #   7-10 → reasoning model (deepseek-r1:14b)
        if ($Effort -gt 0) {
            if (-not $SchedulerUrl) {
                $SchedulerUrl = "http://localhost:8150"
            }

            Write-Host "`n  Direct routing via MicroScheduler (effort: $Effort)" -ForegroundColor Cyan

            $schedBody = @{
                prompt       = if ($fullContext) { "Context:`n$fullContext`n`nTask: $Prompt" } else { $Prompt }
                effort_level = $Effort
            }
            if ($Model) { $schedBody.model = $Model }
            if ($Persona) { $schedBody.persona = $Persona }

            try {
                $schedResult = Invoke-RestMethod -Uri "$SchedulerUrl/v1/chat/completions" `
                    -Method POST -Body ($schedBody | ConvertTo-Json -Depth 5 -Compress) `
                    -ContentType 'application/json' -TimeoutSec 120 -ErrorAction Stop

                $output = if ($schedResult.choices) {
                    $schedResult.choices[0].message.content
                } elseif ($schedResult.response) {
                    $schedResult.response
                } else {
                    $schedResult | ConvertTo-Json -Depth 5
                }

                # Report to Strata
                if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
                    Send-AitherStrata -EventType 'agent-invocation' -Data @{
                        routing = 'direct-scheduler'
                        effort = $Effort
                        model = if ($schedResult.model) { $schedResult.model } else { 'auto' }
                        prompt_length = $Prompt.Length
                    }
                }

                return $output
            }
            catch {
                Write-Warning "MicroScheduler direct routing failed: $_"
                Write-Warning "Falling back to Genesis agent path..."
                # Fall through to standard path
            }
        }

        # ─── Standard Agent Path ─────────────────────────────────────
        # Build the query
        $query = if ($fullContext) {
            "Context:`n$fullContext`n`nTask: $Prompt"
        } else {
            $Prompt
        }

        # Find aither_cli.py
        $aitherCliPath = Join-Path $PSScriptRoot "..\..\..\AitherOS\aither_cli.py"
        if (-not (Test-Path $aitherCliPath)) {
            # Try alternative paths
            $aitherCliPath = Join-Path $env:AITHEROS_ROOT "aither_cli.py"
            if (-not (Test-Path $aitherCliPath)) {
                Write-Error "aither_cli.py not found. Please ensure AitherOS is properly installed."
                return
            }
        }

        # Build command arguments
        $cliArgs = @()
        if ($Model) {
            $cliArgs += "--model", $Model
        }
        if ($Persona) {
            $cliArgs += "--persona", $Persona
        }
        if ($Delegate) {
            $cliArgs += "--delegate", $Delegate
        }
        if ($Stream) {
            $cliArgs += "--stream"
        }
        if ($OrchestratorUrl -and $OrchestratorUrl -ne "http://localhost:8001") {
            $cliArgs += "--url", $OrchestratorUrl
        }
        
        # Add the query
        $cliArgs += $query

        Write-Verbose "Executing: python $aitherCliPath $($cliArgs -join ' ')"

        try {
            # Execute aither_cli.py
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = "python"
            $processInfo.Arguments = "`"$aitherCliPath`" $($cliArgs -join ' ')"
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo

            if ($process.Start()) {
                if ($Stream) {
                    # Stream output in real-time
                    while (-not $process.StandardOutput.EndOfStream) {
                        $line = $process.StandardOutput.ReadLine()
                        Write-Host $line
                    }
                } else {
                    # Capture output
                    $output = $process.StandardOutput.ReadToEnd()
                    $errorOutput = $process.StandardError.ReadToEnd()
                    
                    $process.WaitForExit()
                    
                    if ($process.ExitCode -ne 0) {
                        Write-Error "Agent execution failed (Exit: $($process.ExitCode))`n$errorOutput"
                    } else {
                        if ($output) { return $output }
                    }
                }
            }
        } catch {
            Write-Error "Failed to invoke Aither agent: $_"
        }
    }
}

# Export handled by build.ps1
