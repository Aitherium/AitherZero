# DEPRECATED: This file is deprecated. Use AitherZero/src/public/AI/Invoke-AitherAgent.ps1 instead.
# The new version uses AitherOS backend services instead of external CLI tools.

function Invoke-AitherAgent {
    <#
    .SYNOPSIS
        [DEPRECATED] Unified wrapper for executing AI CLI agents (Gemini, Claude, Codex).
    
    .DESCRIPTION
        [DEPRECATED] This function is deprecated. Use the unified Invoke-AitherAgent in 
        AitherZero/src/public/AI/Invoke-AitherAgent.ps1 which connects to AitherOS backend services.
        
        Provides a consistent PowerShell interface for interacting with various AI CLI tools.
        Supports passing prompts, piping context, and handling tool-specific execution patterns.
    
    .PARAMETER Agent
        The AI agent to invoke (Gemini, Claude, Codex).
    
    .PARAMETER Prompt
        The instruction or query for the agent.
    
    .PARAMETER Context
        Context content to pipe to the agent's standard input.
        If passed via pipeline, this is automatically populated.
    
    .PARAMETER Stream
        Stream output to console in real-time (if supported).
    
    .EXAMPLE
        Invoke-AitherAgent -Agent Gemini -Prompt "Explain this code" -Context (Get-Content ./script.ps1 -Raw)
    
    .EXAMPLE
        Get-Content ./error.log | Invoke-AitherAgent -Agent Claude -Prompt "Analyze this error log"
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('Gemini', 'Claude', 'Codex')]
        [string]$Agent,

        [Parameter(Mandatory, Position = 1)]
        [string]$Prompt,

        [Parameter(ValueFromPipeline)]
        [string]$Context,

        [switch]$Stream
    )

    begin {
        # Determine executable and basic args based on Agent
        $command = ""
        $baseArgs = @()

        switch ($Agent) {
            'Gemini' {
                $command = 'gemini'
                # Gemini pattern: gemini -p "prompt"
                # If piping: echo "context" | gemini -p "prompt"
                $baseArgs += '-p'
                $baseArgs += "`"$Prompt`""
            }
            'Claude' {
                $command = 'claude'
                # Claude pattern: claude -p "prompt"
                $baseArgs += '-p'
                $baseArgs += "`"$Prompt`""
            }
            'Codex' { 
                $command = 'openai'
                # OpenAI CLI pattern (Agent is Codex)
                $baseArgs += 'api'
                $baseArgs += 'chat.completions.create'
                $baseArgs += '-m'
                $baseArgs += 'gpt-4'
                $baseArgs += '-g'
                $baseArgs += 'user'
                $baseArgs += "`"$Prompt`""
            }
        }

        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            Write-Error "CLI tool '$command' for agent '$Agent' not found in PATH."
            return
        }
    }

    process {
        # Prepare ProcessStartInfo
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $command
        $processInfo.Arguments = $baseArgs -join " "
        $processInfo.RedirectStandardOutput = -not $Stream # If streaming, let it write directly to host? 
        # Actually, for capturing output in PS, we usually redirect. 
        # If -Stream is set, we might want to use a different approach or read stream async.
        # For now, let's default to capturing.
        
        $processInfo.RedirectStandardOutput = $true 
        $processInfo.RedirectStandardError = $true
        $processInfo.RedirectStandardInput = $true # Always redirect to allow piping context
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        # Setup Environment Variables if needed (e.g. NONINTERACTIVE)
        # $processInfo.EnvironmentVariables["AITHERZERO_NONINTERACTIVE"] = "1"

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $processInfo

        Write-Verbose "Executing: $command $($processInfo.Arguments)"
        
        if ($p.Start()) {
            # Handle Input (Context)
            if (-not [string]::IsNullOrEmpty($Context)) {
                Write-Verbose "Piping context to agent..."
                $p.StandardInput.WriteLine($Context)
            }
            $p.StandardInput.Close()

            # Handle Output
            if ($Stream) {
                # Real-time streaming logic
                while (-not $p.StandardOutput.EndOfStream) {
                    $line = $p.StandardOutput.ReadLine()
                    Write-Host $line
                }
                $output = "" # Streamed already
            } else {
                $output = $p.StandardOutput.ReadToEnd()
            }
            
            $errorOutput = $p.StandardError.ReadToEnd()
            
            $p.WaitForExit()

            if ($p.ExitCode -ne 0) {
                Write-Error "Agent execution failed (Exit: $($p.ExitCode))`n$errorOutput"
            } else {
                if ($output) { return $output }
            }
        }
    }
}
