#Requires -Version 7.0

<#
.SYNOPSIS
    Interactive multi-turn LLM chat in the terminal.

.DESCRIPTION
    Launches an interactive REPL for conversing with an LLM, with persistent
    conversation threading, provider auto-detection, and optional project context.

    All conversations are saved as threads and can be resumed later.

    Built-in commands:
      /quit, /exit    — End the session
      /clear          — Clear screen, keep thread
      /threads        — List recent threads
      /resume <id>    — Switch to an existing thread
      /provider <p>   — Switch provider (ollama, openai, anthropic, azure)
      /model <m>      — Switch model
      /context <file> — Load file content as context for next message
      /system <text>  — Change system prompt

.PARAMETER Provider
    LLM provider to use. Default: auto (cascades through available providers).

.PARAMETER Model
    Model to use. Provider-specific defaults if omitted.

.PARAMETER ThreadId
    Resume an existing thread instead of starting fresh.

.PARAMETER SystemPrompt
    Initial system prompt. Can be changed mid-session with /system.

.PARAMETER Name
    Name for the new thread. Auto-generated if omitted.

.EXAMPLE
    Start-AitherChat
    # Start a new chat session with auto-detected provider

.EXAMPLE
    Start-AitherChat -Provider ollama -Model llama3.2
    # Chat using local Ollama

.EXAMPLE
    Start-AitherChat -ThreadId abc123def456
    # Resume a previous conversation

.NOTES
    Category: AI
    Dependencies: Invoke-AitherLLM, AitherZero.Threads
    Platform: Windows, Linux, macOS
#>
function Start-AitherChat {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('auto', 'microscheduler', 'ollama', 'openai', 'anthropic', 'azure')]
        [string]$Provider = 'auto',

        [Parameter()]
        [string]$Model,

        [Parameter()]
        [string]$ThreadId,

        [Parameter()]
        [string]$SystemPrompt = 'You are a helpful assistant integrated into AitherZero, a PowerShell automation platform. Be concise and practical.',

        [Parameter()]
        [string]$Name
    )

    # ─── Load threading ─────────────────────────────────────────
    $threadMod = Join-Path (Split-Path $PSScriptRoot -Parent) 'private' 'AI' 'AitherZero.Threads.psm1'
    if (Test-Path $threadMod) {
        Import-Module $threadMod -Force -ErrorAction Stop
    } else {
        Write-Error "Threading module not found at $threadMod"
        return
    }

    # ─── Init or resume thread ──────────────────────────────────
    if ($ThreadId) {
        $existingMessages = Get-AitherThreadMessages -ThreadId $ThreadId
        if (-not $existingMessages -and $existingMessages -isnot [array]) {
            Write-Error "Thread $ThreadId not found"
            return
        }
        Write-Host "  Resumed thread $ThreadId ($($existingMessages.Count) messages)" -ForegroundColor DarkGray
    } else {
        $threadName = if ($Name) { $Name } else { "chat-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
        $thread = New-AitherThread -Name $threadName
        $ThreadId = $thread.ThreadId
        # Seed with system prompt
        Add-AitherThreadMessage -ThreadId $ThreadId -Role 'system' -Content $SystemPrompt
        Write-Host "  New thread: $ThreadId" -ForegroundColor DarkGray
    }

    $pendingContext = $null

    # ─── Header ─────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  AitherZero Chat" -ForegroundColor Cyan
    Write-Host "  Provider: $Provider | Model: $(if ($Model) { $Model } else { 'auto' })" -ForegroundColor DarkGray
    Write-Host "  Type /quit to exit, /threads to list, /help for commands" -ForegroundColor DarkGray
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""

    # ─── REPL loop ──────────────────────────────────────────────
    while ($true) {
        try {
            $input = Read-Host "you"
        } catch {
            break
        }

        if ([string]::IsNullOrWhiteSpace($input)) { continue }

        # ─── Slash commands ─────────────────────────────────────
        if ($input.StartsWith('/')) {
            $parts = $input -split '\s+', 2
            $cmd = $parts[0].ToLower()
            $arg = if ($parts.Count -gt 1) { $parts[1] } else { '' }

            switch ($cmd) {
                { $_ -in '/quit', '/exit', '/q' } {
                    Write-Host "`n  Session saved as thread $ThreadId" -ForegroundColor DarkGray
                    return
                }
                '/clear' {
                    Clear-Host
                    Write-Host "  AitherZero Chat | Thread: $ThreadId" -ForegroundColor Cyan
                    Write-Host ""
                    continue
                }
                '/threads' {
                    $threads = Get-AitherThreadList -Limit 10
                    if ($threads) {
                        Write-Host ""
                        foreach ($t in $threads) {
                            $marker = if ($t.ThreadId -eq $ThreadId) { ' *' } else { '  ' }
                            Write-Host "$marker $($t.ThreadId)  $($t.Name)  ($($t.Messages) msgs, $($t.LastActive.ToString('yyyy-MM-dd HH:mm')))" -ForegroundColor $(if ($t.ThreadId -eq $ThreadId) { 'Cyan' } else { 'Gray' })
                        }
                        Write-Host ""
                    } else {
                        Write-Host "  No threads found." -ForegroundColor DarkGray
                    }
                    continue
                }
                '/resume' {
                    if (-not $arg) {
                        Write-Host "  Usage: /resume <thread-id>" -ForegroundColor Yellow
                        continue
                    }
                    $testMessages = Get-AitherThreadMessages -ThreadId $arg
                    if ($testMessages -or $testMessages -is [array]) {
                        $ThreadId = $arg
                        Write-Host "  Switched to thread $ThreadId ($($testMessages.Count) messages)" -ForegroundColor Green
                    } else {
                        Write-Host "  Thread $arg not found" -ForegroundColor Red
                    }
                    continue
                }
                '/provider' {
                    if ($arg -in @('auto', 'microscheduler', 'ollama', 'openai', 'anthropic', 'azure')) {
                        $Provider = $arg
                        Write-Host "  Provider: $Provider" -ForegroundColor Green
                    } else {
                        Write-Host "  Valid providers: auto, microscheduler, ollama, openai, anthropic, azure" -ForegroundColor Yellow
                    }
                    continue
                }
                '/model' {
                    if ($arg) {
                        $Model = $arg
                        Write-Host "  Model: $Model" -ForegroundColor Green
                    } else {
                        Write-Host "  Usage: /model <model-name>" -ForegroundColor Yellow
                    }
                    continue
                }
                '/context' {
                    if ($arg -and (Test-Path $arg)) {
                        $pendingContext = Get-Content -Path $arg -Raw
                        $charCount = $pendingContext.Length
                        Write-Host "  Loaded $charCount chars from $arg (will be sent with next message)" -ForegroundColor Green
                    } elseif ($arg) {
                        Write-Host "  File not found: $arg" -ForegroundColor Red
                    } else {
                        Write-Host "  Usage: /context <file-path>" -ForegroundColor Yellow
                    }
                    continue
                }
                '/system' {
                    if ($arg) {
                        $SystemPrompt = $arg
                        Add-AitherThreadMessage -ThreadId $ThreadId -Role 'system' -Content $arg
                        Write-Host "  System prompt updated" -ForegroundColor Green
                    } else {
                        Write-Host "  Current: $SystemPrompt" -ForegroundColor DarkGray
                    }
                    continue
                }
                '/help' {
                    Write-Host ""
                    Write-Host "  /quit, /exit     End session" -ForegroundColor DarkGray
                    Write-Host "  /clear           Clear screen" -ForegroundColor DarkGray
                    Write-Host "  /threads         List recent threads" -ForegroundColor DarkGray
                    Write-Host "  /resume <id>     Switch to thread" -ForegroundColor DarkGray
                    Write-Host "  /provider <p>    Switch provider" -ForegroundColor DarkGray
                    Write-Host "  /model <m>       Switch model" -ForegroundColor DarkGray
                    Write-Host "  /context <file>  Load file as context" -ForegroundColor DarkGray
                    Write-Host "  /system <text>   Change system prompt" -ForegroundColor DarkGray
                    Write-Host ""
                    continue
                }
                default {
                    Write-Host "  Unknown command: $cmd (try /help)" -ForegroundColor Yellow
                    continue
                }
            }
        }

        # ─── Send message ──────────────────────────────────────────
        $llmParams = @{
            Prompt       = $input
            Provider     = $Provider
            ThreadId     = $ThreadId
            SystemPrompt = $SystemPrompt
            MaxTokens    = 2048
            Temperature  = 0.7
        }
        if ($Model) { $llmParams.Model = $Model }
        if ($pendingContext) {
            $llmParams.Context = $pendingContext
            $pendingContext = $null
        }

        try {
            $result = Invoke-AitherLLM @llmParams

            $responseText = if ($result -is [PSCustomObject] -and $result.Response) {
                $result.Response
            } else {
                [string]$result
            }

            Write-Host ""
            Write-Host $responseText
            Write-Host ""

        } catch {
            Write-Host "  Error: $_" -ForegroundColor Red
            Write-Host ""
        }
    }
}
