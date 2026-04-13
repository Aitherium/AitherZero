#Requires -Version 7.0

<#
.SYNOPSIS
    Standalone provider-agnostic LLM client that works without Genesis.

.DESCRIPTION
    Provides direct LLM access with automatic provider fallback:
      1. MicroScheduler:8150 (if AitherOS is running)
      2. Ollama localhost:11434 (local, always available)
      3. OpenAI API (if OPENAI_API_KEY set)
      4. Anthropic API (if ANTHROPIC_API_KEY set)
      5. Azure OpenAI (if AZURE_OPENAI_ENDPOINT + AZURE_OPENAI_KEY set)

    Supports conversation threading via AitherZero.Threads for multi-turn sessions.
    No Genesis dependency — this is the offline/standalone LLM path.

.PARAMETER Prompt
    The prompt or instruction to send.

.PARAMETER Context
    Optional context to prepend (code, logs, etc.).

.PARAMETER Provider
    Force a specific provider instead of auto-cascade.
    Valid: auto, microscheduler, ollama, openai, anthropic, azure.

.PARAMETER Model
    Model name override. Provider-specific defaults used if omitted.

.PARAMETER Effort
    Effort level (1-10). Maps to model tier: 1-2=small, 3-6=mid, 7-10=reasoning.

.PARAMETER ThreadId
    Continue a conversation thread. Creates a new one if -NewThread is set.

.PARAMETER NewThread
    Start a new conversation thread and return messages with thread context.

.PARAMETER SystemPrompt
    System prompt for the conversation. Defaults to a concise assistant prompt.

.PARAMETER MaxTokens
    Maximum tokens in response. Default: 2048.

.PARAMETER Temperature
    Sampling temperature. Default: 0.7.

.PARAMETER Raw
    Return raw API response object instead of extracted text.

.EXAMPLE
    Invoke-AitherLLM -Prompt "Explain async/await in PowerShell"

.EXAMPLE
    Get-Content ./error.log | Invoke-AitherLLM -Prompt "What's wrong here?"

.EXAMPLE
    Invoke-AitherLLM -Prompt "Refactor this" -Context (Get-Content ./script.ps1 -Raw) -Provider ollama -Model llama3.2

.EXAMPLE
    # Multi-turn conversation
    $t = Invoke-AitherLLM -Prompt "Design a REST API for user management" -NewThread
    Invoke-AitherLLM -Prompt "Add pagination to that design" -ThreadId $t.ThreadId

.NOTES
    Category: AI
    Dependencies: None (standalone). Optional: AitherZero.Threads for threading.
    Platform: Windows, Linux, macOS
#>
function Invoke-AitherLLM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Prompt,

        [Parameter(ValueFromPipeline)]
        [string]$Context,

        [Parameter()]
        [ValidateSet('auto', 'microscheduler', 'ollama', 'openai', 'anthropic', 'azure')]
        [string]$Provider = 'auto',

        [Parameter()]
        [string]$Model,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$Effort,

        [Parameter()]
        [string]$ThreadId,

        [Parameter()]
        [switch]$NewThread,

        [Parameter()]
        [string]$SystemPrompt = 'You are a helpful assistant integrated into AitherZero, a PowerShell automation platform.',

        [Parameter()]
        [int]$MaxTokens = 2048,

        [Parameter()]
        [double]$Temperature = 0.7,

        [Parameter()]
        [switch]$Raw
    )

    begin {
        $contextData = @()
    }

    process {
        if ($Context) {
            $contextData += $Context
        }
    }

    end {
        $fullContext = $contextData -join "`n"
        $fullPrompt = if ($fullContext) { "Context:`n$fullContext`n`nTask: $Prompt" } else { $Prompt }

        # ─── Threading ──────────────────────────────────────────────
        $threadingAvailable = $false
        try {
            $threadMod = Join-Path (Split-Path $PSScriptRoot -Parent) 'private' 'AI' 'AitherZero.Threads.psm1'
            if (Test-Path $threadMod) {
                Import-Module $threadMod -Force -ErrorAction Stop
                $threadingAvailable = $true
            }
        } catch {
            Write-Verbose "Threading module not available: $_"
        }

        if ($NewThread -and $threadingAvailable) {
            $thread = New-AitherThread -Name "llm-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            $ThreadId = $thread.ThreadId
            Write-Verbose "Created thread: $ThreadId"
        }

        # ─── Build messages array ──────────────────────────────────
        $messages = @()

        if ($ThreadId -and $threadingAvailable) {
            $messages = ConvertTo-ChatMessages -ThreadId $ThreadId -SystemPrompt $SystemPrompt
            $messages += @{ role = 'user'; content = $fullPrompt }
            Add-AitherThreadMessage -ThreadId $ThreadId -Role 'user' -Content $fullPrompt
        } else {
            $messages += @{ role = 'system'; content = $SystemPrompt }
            $messages += @{ role = 'user'; content = $fullPrompt }
        }

        # ─── Resolve model from effort ─────────────────────────────
        if ($Effort -gt 0 -and -not $Model) {
            $Model = switch ($Effort) {
                { $_ -le 2 } { 'llama3.2' }
                { $_ -le 6 } { 'aither-orchestrator' }
                default      { 'deepseek-r1:14b' }
            }
        }

        # ─── Provider cascade ──────────────────────────────────────
        $result = $null
        $usedProvider = $null
        $providers = if ($Provider -eq 'auto') {
            @('microscheduler', 'ollama', 'openai', 'anthropic')
        } else {
            @($Provider)
        }

        foreach ($prov in $providers) {
            $result = switch ($prov) {
                'microscheduler' { Invoke-MicroSchedulerLLM -Messages $messages -Model $Model -MaxTokens $MaxTokens -Temperature $Temperature }
                'ollama'         { Invoke-OllamaLLM -Messages $messages -Model $Model -MaxTokens $MaxTokens -Temperature $Temperature }
                'openai'         { Invoke-OpenAILLM -Messages $messages -Model $Model -MaxTokens $MaxTokens -Temperature $Temperature }
                'anthropic'      { Invoke-AnthropicLLM -Messages $messages -Model $Model -MaxTokens $MaxTokens -Temperature $Temperature }
                'azure'          { Invoke-AzureOpenAILLM -Messages $messages -Model $Model -MaxTokens $MaxTokens -Temperature $Temperature }
            }

            if ($result) {
                $usedProvider = $prov
                break
            }
        }

        if (-not $result) {
            Write-Error "All LLM providers failed. Tried: $($providers -join ', '). Ensure at least one is available."
            return
        }

        # ─── Extract response text ─────────────────────────────────
        $responseText = switch ($usedProvider) {
            'anthropic' {
                if ($result.content) { ($result.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text }
                else { $result | ConvertTo-Json -Depth 5 }
            }
            default {
                if ($result.choices) { $result.choices[0].message.content }
                elseif ($result.message) { $result.message.content }
                elseif ($result.response) { $result.response }
                else { $result | ConvertTo-Json -Depth 5 }
            }
        }

        # ─── Save assistant reply to thread ────────────────────────
        if ($ThreadId -and $threadingAvailable -and $responseText) {
            $usedModel = if ($result.model) { $result.model } elseif ($Model) { $Model } else { 'unknown' }
            Add-AitherThreadMessage -ThreadId $ThreadId -Role 'assistant' -Content $responseText -Model $usedModel
        }

        # ─── Return ────────────────────────────────────────────────
        if ($Raw) {
            return $result
        }

        if ($ThreadId) {
            return [PSCustomObject]@{
                ThreadId = $ThreadId
                Provider = $usedProvider
                Model    = if ($result.model) { $result.model } elseif ($Model) { $Model } else { 'default' }
                Response = $responseText
            }
        }

        return $responseText
    }
}

# ─── Provider Implementations ───────────────────────────────────────────

function Invoke-MicroSchedulerLLM {
    [CmdletBinding()]
    param($Messages, $Model, $MaxTokens, $Temperature)

    $url = if ($env:AITHER_MICROSCHEDULER_URL) { $env:AITHER_MICROSCHEDULER_URL } else { 'http://localhost:8150' }

    $body = @{
        messages    = $Messages
        max_tokens  = $MaxTokens
        temperature = $Temperature
    }
    if ($Model) { $body.model = $Model }

    try {
        # Quick connectivity check
        $null = Invoke-WebRequest -Uri "$url/health" -Method GET -TimeoutSec 2 -ErrorAction Stop
        $result = Invoke-RestMethod -Uri "$url/v1/chat/completions" -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' -TimeoutSec 120 -ErrorAction Stop
        Write-Verbose "LLM: MicroScheduler responded (model: $($result.model))"
        return $result
    } catch {
        Write-Verbose "LLM: MicroScheduler unavailable at $url — $_"
        return $null
    }
}

function Invoke-OllamaLLM {
    [CmdletBinding()]
    param($Messages, $Model, $MaxTokens, $Temperature)

    $url = if ($env:OLLAMA_HOST) { $env:OLLAMA_HOST } else { 'http://localhost:11434' }
    $ollamaModel = if ($Model -and $Model -ne 'aither-orchestrator') { $Model } else { 'llama3.2' }

    $body = @{
        model    = $ollamaModel
        messages = $Messages
        stream   = $false
        options  = @{
            num_predict = $MaxTokens
            temperature = $Temperature
        }
    }

    try {
        $result = Invoke-RestMethod -Uri "$url/api/chat" -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' -TimeoutSec 120 -ErrorAction Stop
        Write-Verbose "LLM: Ollama responded (model: $ollamaModel)"
        return $result
    } catch {
        Write-Verbose "LLM: Ollama unavailable at $url — $_"
        return $null
    }
}

function Invoke-OpenAILLM {
    [CmdletBinding()]
    param($Messages, $Model, $MaxTokens, $Temperature)

    $apiKey = $env:OPENAI_API_KEY
    if (-not $apiKey) {
        Write-Verbose "LLM: OpenAI skipped — no OPENAI_API_KEY"
        return $null
    }

    $openaiModel = if ($Model -and $Model -notin @('aither-orchestrator', 'llama3.2', 'deepseek-r1:14b')) {
        $Model
    } else { 'gpt-4o-mini' }

    $body = @{
        model       = $openaiModel
        messages    = $Messages
        max_tokens  = $MaxTokens
        temperature = $Temperature
    }

    try {
        $result = Invoke-RestMethod -Uri 'https://api.openai.com/v1/chat/completions' -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' -TimeoutSec 120 -ErrorAction Stop `
            -Headers @{ Authorization = "Bearer $apiKey" }
        Write-Verbose "LLM: OpenAI responded (model: $openaiModel)"
        return $result
    } catch {
        Write-Verbose "LLM: OpenAI failed — $_"
        return $null
    }
}

function Invoke-AnthropicLLM {
    [CmdletBinding()]
    param($Messages, $Model, $MaxTokens, $Temperature)

    $apiKey = $env:ANTHROPIC_API_KEY
    if (-not $apiKey) {
        Write-Verbose "LLM: Anthropic skipped — no ANTHROPIC_API_KEY"
        return $null
    }

    $claudeModel = if ($Model -and $Model -notin @('aither-orchestrator', 'llama3.2', 'deepseek-r1:14b')) {
        $Model
    } else { 'claude-sonnet-4-6' }

    # Anthropic uses separate system param
    $systemMsg = ($Messages | Where-Object { $_.role -eq 'system' } | Select-Object -First 1).content
    $chatMessages = $Messages | Where-Object { $_.role -ne 'system' }

    $body = @{
        model       = $claudeModel
        max_tokens  = $MaxTokens
        temperature = $Temperature
        messages    = @($chatMessages)
    }
    if ($systemMsg) { $body.system = $systemMsg }

    try {
        $result = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' -TimeoutSec 120 -ErrorAction Stop `
            -Headers @{
                'x-api-key'         = $apiKey
                'anthropic-version' = '2023-06-01'
            }
        Write-Verbose "LLM: Anthropic responded (model: $claudeModel)"
        return $result
    } catch {
        Write-Verbose "LLM: Anthropic failed — $_"
        return $null
    }
}

function Invoke-AzureOpenAILLM {
    [CmdletBinding()]
    param($Messages, $Model, $MaxTokens, $Temperature)

    $endpoint = $env:AZURE_OPENAI_ENDPOINT
    $apiKey = $env:AZURE_OPENAI_KEY
    $deployment = if ($Model) { $Model } elseif ($env:AZURE_OPENAI_DEPLOYMENT) { $env:AZURE_OPENAI_DEPLOYMENT } else { 'gpt-4o-mini' }

    if (-not $endpoint -or -not $apiKey) {
        Write-Verbose "LLM: Azure OpenAI skipped — no AZURE_OPENAI_ENDPOINT or AZURE_OPENAI_KEY"
        return $null
    }

    $body = @{
        messages    = $Messages
        max_tokens  = $MaxTokens
        temperature = $Temperature
    }

    $uri = "$endpoint/openai/deployments/$deployment/chat/completions?api-version=2024-02-15-preview"

    try {
        $result = Invoke-RestMethod -Uri $uri -Method POST `
            -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType 'application/json' -TimeoutSec 120 -ErrorAction Stop `
            -Headers @{ 'api-key' = $apiKey }
        Write-Verbose "LLM: Azure OpenAI responded (deployment: $deployment)"
        return $result
    } catch {
        Write-Verbose "LLM: Azure OpenAI failed — $_"
        return $null
    }
}
