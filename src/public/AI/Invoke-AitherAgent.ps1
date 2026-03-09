<#
.SYNOPSIS
    Unified CLI agent interface that uses AitherOS backend services.

.DESCRIPTION
    This function provides a unified interface to interact with AitherOS agents via the backend services.
    It connects to Genesis (port 8001) instead of external CLI tools.
    
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
    Delegate to a specific agent (e.g., coder, analyst).

.PARAMETER Stream
    Stream output in real-time.

.PARAMETER OrchestratorUrl
    URL of the Genesis service. Defaults to http://localhost:8001.

.EXAMPLE
    Invoke-AitherAgent -Prompt "Explain this code" -Context (Get-Content ./script.ps1 -Raw)

.EXAMPLE
    Get-Content ./error.log | Invoke-AitherAgent -Prompt "Analyze this error log"

.EXAMPLE
    Invoke-AitherAgent -Prompt "Write a function" -Delegate coder -Model gemini-2.5-flash
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
        [string]$Model,

        [Parameter()]
        [string]$Persona,

        [Parameter()]
        [string]$Delegate,

        [Parameter()]
        [switch]$Stream,

        [Parameter()]
        [string]$OrchestratorUrl
    )

    begin {
        if (-not $OrchestratorUrl) {
            $agentCtx = Get-AitherLiveContext
            $OrchestratorUrl = if ($agentCtx.OrchestratorURL) { $agentCtx.OrchestratorURL } else { "http://localhost:8001" }
        }
        $contextData = @()
        
        # Check if orchestrator is available
        try {
            $response = Invoke-WebRequest -Uri "$OrchestratorUrl/status" -Method GET -TimeoutSec 5 -ErrorAction Stop
            if ($response.StatusCode -ne 200) {
                Write-Warning "Genesis is not responding. Start it with: Start-AitherOS -Group core"
                return
            }
        } catch {
            Write-Warning "Cannot connect to Genesis at $OrchestratorUrl. Start it with: Start-AitherOS -Group core"
            Write-Warning "Error: $_"
            return
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
        $args = @()
        if ($Model) {
            $args += "--model", $Model
        }
        if ($Persona) {
            $args += "--persona", $Persona
        }
        if ($Delegate) {
            $args += "--delegate", $Delegate
        }
        if ($Stream) {
            $args += "--stream"
        }
        if ($OrchestratorUrl -and $OrchestratorUrl -ne "http://localhost:8001") {
            $args += "--url", $OrchestratorUrl
        }
        
        # Add the query
        $args += $query

        Write-Verbose "Executing: python $aitherCliPath $($args -join ' ')"

        try {
            # Execute aither_cli.py
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = "python"
            $processInfo.Arguments = "`"$aitherCliPath`" $($args -join ' ')"
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
