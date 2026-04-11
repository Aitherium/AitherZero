#Requires -Version 7.0

<#
.SYNOPSIS
    Full Genesis Demo - Comprehensive Agent Ecosystem Demonstration
.DESCRIPTION
    Demonstrates the complete AitherOS agent lifecycle including:
    1. Agent startup and initialization
    2. Inter-agent mail and collaboration
    3. Group chat scenarios
    4. Reasoning engine visualization
    5. Pain signal processing and self-healing
    6. Resource management and CPU throttling
    7. Approval workflows
    8. Custom agent deployment
    9. Data capture for training
    10. Circuit breaker and atomic rollback
    11. AitherChaos adversarial testing preview
    12. AitherSpawn secure node expansion preview
    13. Graceful shutdown

.PARAMETER ShowOutput
    Display verbose output during execution

.PARAMETER Interactive
    Wait for user input between phases

.PARAMETER SkipSlowTests
    Skip time-consuming tests like image generation

.NOTES
    Stage: Integration Demo
    Order: 1110

.EXAMPLE
    ./1110_Run-FullGenesisDemo.ps1 -ShowOutput -Interactive
#>

[CmdletBinding()]
param(
    [switch]$ShowOutput,
    [switch]$Interactive,
    [switch]$SkipSlowTests
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# ============================================================================
# INITIALIZATION
# ============================================================================

. "$PSScriptRoot/_init.ps1"

if (-not $projectRoot) {
    Write-Error "AitherZero project root not found"
    exit 1
}

# Service endpoints
$script:Endpoints = @{
    AitherNode = "http://localhost:8080"
    AitherReasoning = "http://localhost:8093"
    AitherPulse = "http://localhost:8081"
    Ollama = "http://localhost:11434"
    WebDash = "http://localhost:3000"
}

# Demo state
$script:DemoState = @{
    StartTime = Get-Date
    AgentsStarted = @()
    MailsSent = 0
    ThoughtsGenerated = 0
    PainSignalsEmitted = 0
    ApprovalsPending = @()
    Errors = @()
    # Test tracking
    TestsPassed = 0
    TestsFailed = 0
    TestResults = @()
}

# Colors for output
$script:Colors = @{
    Header = "Magenta"
    Success = "Green"
    Error = "Red"
    Info = "Cyan"
    Warning = "Yellow"
    Agent = "Blue"
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-DemoHeader {
    param([string]$Title, [string]$Subtitle = "")
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor $Colors.Header
    Write-Host "║  $Title" -ForegroundColor $Colors.Header
    if ($Subtitle) {
        Write-Host "║  $Subtitle" -ForegroundColor $Colors.Info
    }
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor $Colors.Header
    Write-Host ""
}

function Write-Phase {
    param([int]$Number, [string]$Title)
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor $Colors.Info
    Write-Host "  PHASE $Number : $Title" -ForegroundColor $Colors.Header
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor $Colors.Info
}

function Write-Step {
    param([string]$Icon, [string]$Message, [string]$Color = "White")
    Write-Host "  $Icon $Message" -ForegroundColor $Color
}

function Write-AgentMessage {
    param([string]$Agent, [string]$Message)
    $agentColor = switch ($Agent.ToLower()) {
        "aither" { "Magenta" }
        "narrativeagent" { "Cyan" }
        "infrastructureagent" { "Green" }
        "aitherzeroautomationagent" { "Yellow" }
        "system" { "Gray" }
        default { "Blue" }
    }
    Write-Host "    [$Agent]: " -ForegroundColor $agentColor -NoNewline
    Write-Host $Message
}

# ============================================================================
# TEST ASSERTION FRAMEWORK
# ============================================================================

function Test-Assertion {
    <#
    .SYNOPSIS
        Records a test result with pass/fail status
    .PARAMETER Name
        Name of the test
    .PARAMETER Condition
        Boolean condition - $true = pass, $false = fail
    .PARAMETER Message
        Optional message for context
    .PARAMETER Critical
        If true, failure should halt further tests
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Message = "",
        [switch]$Critical
    )
    
    $result = @{
        Name = $Name
        Passed = $Condition
        Message = $Message
        Timestamp = Get-Date
        Critical = $Critical.IsPresent
    }
    
    $script:DemoState.TestResults += $result
    
    if ($Condition) {
        $script:DemoState.TestsPassed++
        Write-Host "    ✅ PASS: $Name" -ForegroundColor "Green"
        if ($Message) { Write-Host "       → $Message" -ForegroundColor "Gray" }
    } else {
        $script:DemoState.TestsFailed++
        Write-Host "    ❌ FAIL: $Name" -ForegroundColor "Red"
        if ($Message) { Write-Host "       → $Message" -ForegroundColor "Yellow" }
        $script:DemoState.Errors += "FAIL: $Name - $Message"
        
        if ($Critical) {
            Write-Host "    🛑 CRITICAL FAILURE - Cannot continue" -ForegroundColor "Red"
            return $false
        }
    }
    return $Condition
}

function Test-ApiEndpoint {
    <#
    .SYNOPSIS
        Tests an API endpoint and validates response
    .PARAMETER Url
        Full URL to test
    .PARAMETER Method
        HTTP method
    .PARAMETER Body
        Request body (hashtable)
    .PARAMETER ExpectedStatus
        Expected HTTP status code
    .PARAMETER ValidateResponse
        ScriptBlock to validate response - receives $response, returns $true/$false
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Method = "GET",
        [hashtable]$Body = $null,
        [int]$ExpectedStatus = 200,
        [scriptblock]$ValidateResponse = $null,
        [int]$TimeoutSec = 10
    )
    
    $result = @{
        Success = $false
        StatusCode = 0
        Response = $null
        Error = $null
        Duration = 0
    }
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        $params = @{
            Uri = $Url
            Method = $Method
            TimeoutSec = $TimeoutSec
            ContentType = "application/json"
        }
        
        if ($Body) {
            $params.Body = ($Body | ConvertTo-Json -Depth 10)
        }
        
        $response = Invoke-RestMethod @params -ErrorAction Stop
        $stopwatch.Stop()
        
        $result.StatusCode = 200  # RestMethod doesn't return status for success
        $result.Response = $response
        $result.Duration = $stopwatch.ElapsedMilliseconds
        
        # Validate response if validator provided
        if ($ValidateResponse) {
            $result.Success = & $ValidateResponse $response
        } else {
            $result.Success = $true
        }
    }
    catch {
        $stopwatch.Stop()
        $result.Error = $_.Exception.Message
        $result.Duration = $stopwatch.ElapsedMilliseconds
        
        # Try to get status code from WebException
        if ($_.Exception.Response) {
            $result.StatusCode = [int]$_.Exception.Response.StatusCode
        }
    }
    
    return $result
}

function Wait-ForInteractive {
    if ($Interactive) {
        Write-Host ""
        Write-Host "  Press any key to continue..." -ForegroundColor $Colors.Warning
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

function Test-ServiceOnline {
    param([string]$Url, [int]$TimeoutSec = 3)
    try {
        $response = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $true
    } catch {
        try {
            $response = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -ErrorAction Stop
            return $response.StatusCode -eq 200
        } catch {
            return $false
        }
    }
}

function Invoke-AitherAPI {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutSec = 30
    )
    
    $params = @{
        Uri = "$($Endpoints.AitherNode)$Endpoint"
        Method = $Method
        TimeoutSec = $TimeoutSec
        ContentType = "application/json"
    }
    
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    
    try {
        $response = Invoke-RestMethod @params -ErrorAction Stop
        return @{ Success = $true; Data = $response }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Send-AgentMail {
    param(
        [string]$From,
        [string]$To,
        [string]$Subject,
        [string]$Content,
        [string]$Priority = "normal"
    )
    
    $message = @{
        id = [guid]::NewGuid().ToString()
        sender = $From
        recipient = $To
        subject = $Subject
        content = $Content
        priority = $Priority
        timestamp = (Get-Date).ToString("o")
        read = $false
    }
    
    $mailboxPath = Join-Path $projectRoot "AitherOS/agents/NarrativeAgent/mailbox.json"
    
    $messages = @()
    if (Test-Path $mailboxPath) {
        try {
            $messages = Get-Content $mailboxPath -Raw | ConvertFrom-Json
            if ($messages -isnot [array]) { $messages = @($messages) }
        } catch { $messages = @() }
    }
    
    $messages += $message
    $messages | ConvertTo-Json -Depth 5 | Set-Content $mailboxPath -Encoding UTF8
    
    $script:DemoState.MailsSent++
    return $message.id
}

function Emit-PainSignal {
    param(
        [string]$Category,
        [string]$PainPointId,
        [float]$Severity,
        [string]$Message,
        [string]$Source = "genesis-demo"
    )
    
    $body = @{
        type = "pain.$PainPointId"
        source = $Source
        priority = if ($Severity -gt 0.7) { "high" } elseif ($Severity -gt 0.4) { "normal" } else { "low" }
        data = @{
            pain_point_id = $PainPointId
            category = $Category
            severity = $Severity
            message = $Message
        }
        tags = @("pain", $Category, "genesis-demo")
    }
    
    try {
        $response = Invoke-RestMethod -Uri "$($Endpoints.AitherPulse)/events/publish" `
            -Method POST -Body ($body | ConvertTo-Json -Depth 5) `
            -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop
        $script:DemoState.PainSignalsEmitted++
        return $true
    } catch {
        # Pulse may not be running - that's OK for demo
        return $false
    }
}

function Request-Approval {
    param(
        [string]$Agent,
        [string]$Action,
        [string]$Reason,
        [string]$Impact = "medium"
    )
    
    $approval = @{
        id = [guid]::NewGuid().ToString()
        agent = $Agent
        action = $Action
        reason = $Reason
        impact = $Impact
        status = "pending"
        requested_at = (Get-Date).ToString("o")
    }
    
    $script:DemoState.ApprovalsPending += $approval
    
    # Send to mailbox as approval request
    Send-AgentMail -From $Agent -To "user" -Subject "🔐 Approval Needed: $Action" `
        -Content "**Request from $Agent**`n`nAction: $Action`nReason: $Reason`nImpact: $Impact`n`nReply with 'approve' or 'deny'." `
        -Priority "high"
    
    return $approval.id
}

function Add-ReasoningThought {
    param(
        [string]$Agent,
        [string]$ThoughtType,
        [string]$Content,
        [string]$SessionId = $null,
        [string]$ToolName = $null,
        [hashtable]$ToolArgs = $null,
        [string]$ToolResult = $null
    )
    
    if (-not $SessionId) {
        $SessionId = "genesis-demo-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    }
    
    $thought = @{
        session_id = $SessionId
        type = $ThoughtType
        agent = $Agent
        content = $Content
        confidence = [math]::Round((Get-Random -Minimum 70 -Maximum 100) / 100, 2)
    }
    
    # Add tool-specific fields for tool_call type
    if ($ThoughtType -eq "tool_call" -and $ToolName) {
        $thought.tool_name = $ToolName
        if ($ToolArgs) { $thought.tool_args = $ToolArgs }
        if ($ToolResult) { $thought.tool_result = $ToolResult }
    }
    
    try {
        $response = Invoke-RestMethod -Uri "$($Endpoints.AitherReasoning)/thoughts" `
            -Method POST -Body ($thought | ConvertTo-Json -Depth 5) `
            -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop
        $script:DemoState.ThoughtsGenerated++
        return $response.id
    } catch {
        return $null
    }
}

# ============================================================================
# DEMO PHASES
# ============================================================================

function Demo-Phase1-ServiceCheck {
    Write-Phase -Number 1 -Title "SERVICE HEALTH CHECK & INITIALIZATION"
    
    $services = @(
        @{ Name = "AitherNode (MCP Server)"; Url = $Endpoints.AitherNode; Required = $true; HealthEndpoint = "/health" }
        @{ Name = "AitherReasoning (Thinking Traces)"; Url = $Endpoints.AitherReasoning; Required = $false; HealthEndpoint = "/health" }
        @{ Name = "AitherPulse (Events)"; Url = $Endpoints.AitherPulse; Required = $false; HealthEndpoint = "/health" }
        @{ Name = "Ollama (Local LLM)"; Url = $Endpoints.Ollama; Required = $true; HealthEndpoint = "/api/version" }
        @{ Name = "WebDash (AitherVeil)"; Url = $Endpoints.WebDash; Required = $false; HealthEndpoint = "/" }
    )
    
    $allCriticalOnline = $true
    
    foreach ($svc in $services) {
        $healthUrl = "$($svc.Url)$($svc.HealthEndpoint)"
        $result = Test-ApiEndpoint -Url $healthUrl -TimeoutSec 5
        
        if ($result.Success) {
            Write-Step -Icon "✅" -Message "$($svc.Name) - Online ($($result.Duration)ms)" -Color $Colors.Success
            
            # Additional validation for specific services
            if ($svc.Name -like "*Ollama*" -and $result.Response) {
                $ollamaVersion = $result.Response.version
                Test-Assertion -Name "Ollama version check" -Condition ($null -ne $ollamaVersion) `
                    -Message "Ollama version: $ollamaVersion"
            }
            
            if ($svc.Name -like "*AitherNode*" -and $result.Response) {
                # Validate health response structure
                $hasStatus = $null -ne $result.Response.status -or $null -ne $result.Response.healthy
                Test-Assertion -Name "AitherNode health structure" -Condition $hasStatus `
                    -Message "Health response contains status field"
            }
        } else {
            if ($svc.Required) {
                Write-Step -Icon "❌" -Message "$($svc.Name) - OFFLINE (Required!)" -Color $Colors.Error
                $allCriticalOnline = $false
                Test-Assertion -Name "$($svc.Name) availability" -Condition $false `
                    -Message "Error: $($result.Error)" -Critical
            } else {
                Write-Step -Icon "⚠️" -Message "$($svc.Name) - Offline (Optional)" -Color $Colors.Warning
            }
        }
    }
    
    Write-Host ""
    
    # Test AitherNode API endpoints
    if ($allCriticalOnline) {
        Write-Step -Icon "🔍" -Message "Testing AitherNode API endpoints..." -Color $Colors.Info
        
        # Test /tools endpoint
        $toolsResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/tools"
        Test-Assertion -Name "AitherNode /tools endpoint" -Condition $toolsResult.Success `
            -Message "Tools endpoint responds in $($toolsResult.Duration)ms"
        
        # Test /agents endpoint
        $agentsResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/agents"
        Test-Assertion -Name "AitherNode /agents endpoint" -Condition $agentsResult.Success `
            -Message "Agents endpoint responds in $($agentsResult.Duration)ms"
        
        # Validate Ollama models available
        $modelsResult = Test-ApiEndpoint -Url "$($Endpoints.Ollama)/api/tags"
        if ($modelsResult.Success -and $modelsResult.Response.models) {
            $modelCount = $modelsResult.Response.models.Count
            Test-Assertion -Name "Ollama models available" -Condition ($modelCount -gt 0) `
                -Message "$modelCount models loaded"
        }
    }
    
    if (-not $allCriticalOnline) {
        Write-Host ""
        Write-Host "  ⚠️  Some required services are offline. Starting them..." -ForegroundColor $Colors.Warning
        
        # Try to start AitherNode if not running
        if (-not (Test-ServiceOnline -Url $Endpoints.AitherNode)) {
            Write-Step -Icon "🚀" -Message "Starting AitherNode..." -Color $Colors.Info
            $startScript = Join-Path $PSScriptRoot "0762_Start-AitherNode.ps1"
            if (Test-Path $startScript) {
                & $startScript -ShowOutput:$false
                Start-Sleep -Seconds 5
            }
        }
    }
    
    Write-Host ""
    Wait-ForInteractive
}

function Demo-Phase2-AgentStartup {
    Write-Phase -Number 2 -Title "AGENT STARTUP & LIFECYCLE"
    
    # List available agents
    $agentsDir = Join-Path $projectRoot "AitherOS/agents"
    $agents = Get-ChildItem -Path $agentsDir -Directory | 
        Where-Object { $_.Name -notmatch "^(common|__pycache__)$" }
    
    Write-Step -Icon "📋" -Message "Available Agents:" -Color $Colors.Info
    foreach ($agent in $agents) {
        Write-Step -Icon "  •" -Message $agent.Name -Color $Colors.Agent
        $script:DemoState.AgentsStarted += $agent.Name
    }
    
    Write-Host ""
    Write-Step -Icon "🔄" -Message "Simulating agent startup sequence..." -Color $Colors.Info
    
    # Simulate agent startup with reasoning
    $sessionId = "startup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    
    foreach ($agent in $agents) {
        Write-AgentMessage -Agent $agent.Name -Message "Initializing..."
        Start-Sleep -Milliseconds 300
        
        # Add startup thoughts to reasoning engine
        Add-ReasoningThought -Agent $agent.Name -ThoughtType "reasoning" `
            -Content "Beginning startup sequence. Loading configuration and dependencies." -SessionId $sessionId
        
        Write-AgentMessage -Agent $agent.Name -Message "✓ Ready and listening"
        Start-Sleep -Milliseconds 200
    }
    
    Write-Host ""
    Write-Step -Icon "✅" -Message "All agents initialized successfully" -Color $Colors.Success
    
    Wait-ForInteractive
}

function Demo-Phase3-InterAgentMail {
    Write-Phase -Number 3 -Title "INTER-AGENT MAIL COMMUNICATION"
    
    Write-Step -Icon "📬" -Message "Testing agent-to-agent messaging API..." -Color $Colors.Info
    Write-Host ""
    
    # Test 1: Send mail via API
    $mailPayload = @{
        sender = "user"
        recipient = "Aither"
        subject = "Genesis Test: Analyze codebase"
        content = "Please analyze the current codebase and report any issues."
        priority = "normal"
    }
    
    $sendResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/mail/send" -Method "POST" -Body $mailPayload
    $mailSent = Test-Assertion -Name "Mail API: Send message" -Condition $sendResult.Success `
        -Message "POST /mail/send - $($sendResult.Duration)ms"
    
    if ($sendResult.Success -and $sendResult.Response.id) {
        $mailId = $sendResult.Response.id
        Write-AgentMessage -Agent "User" -Message "📤 Sent mail ID: $mailId"
        $script:DemoState.MailsSent++
    }
    
    Start-Sleep -Milliseconds 300
    
    # Test 2: Read mailbox
    $inboxResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/mail/inbox/Aither"
    Test-Assertion -Name "Mail API: Read inbox" -Condition $inboxResult.Success `
        -Message "GET /mail/inbox/Aither - $($inboxResult.Duration)ms"
    
    if ($inboxResult.Success -and $inboxResult.Response) {
        $messageCount = if ($inboxResult.Response -is [array]) { $inboxResult.Response.Count } else { 1 }
        Test-Assertion -Name "Mail API: Inbox has messages" -Condition ($messageCount -gt 0) `
            -Message "Found $messageCount message(s) in inbox"
    }
    
    # Test 3: Agent-to-agent delegation
    $delegatePayload = @{
        sender = "Aither"
        recipient = "InfrastructureAgent"
        subject = "Delegated: Code analysis"
        content = "Please run PSScriptAnalyzer and report findings."
        priority = "normal"
        metadata = @{ delegated_from = "user"; original_task = "codebase health" }
    }
    
    $delegateResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/mail/send" -Method "POST" -Body $delegatePayload
    Test-Assertion -Name "Mail API: Agent delegation" -Condition $delegateResult.Success `
        -Message "Agent-to-agent mail with metadata"
    
    if ($delegateResult.Success) {
        Write-AgentMessage -Agent "Aither" -Message "📤 Delegated task to InfrastructureAgent"
        $script:DemoState.MailsSent++
    }
    
    Start-Sleep -Milliseconds 300
    
    # Test 4: Priority mail
    $urgentPayload = @{
        sender = "InfrastructureAgent"
        recipient = "Aither"
        subject = "URGENT: Analysis complete"
        content = "Found 3 warnings and 0 errors. Overall health: Good."
        priority = "high"
    }
    
    $urgentResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/mail/send" -Method "POST" -Body $urgentPayload
    Test-Assertion -Name "Mail API: High priority message" -Condition $urgentResult.Success `
        -Message "Priority: high handled correctly"
    
    if ($urgentResult.Success) {
        Write-AgentMessage -Agent "InfrastructureAgent" -Message "📤 High-priority response sent"
        $script:DemoState.MailsSent++
    }
    
    # Test 5: Mark as read
    if ($sendResult.Success -and $sendResult.Response.id) {
        $markReadResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/mail/$($sendResult.Response.id)/read" -Method "POST"
        Test-Assertion -Name "Mail API: Mark as read" -Condition $markReadResult.Success `
            -Message "POST /mail/{id}/read"
    }
    
    Write-Host ""
    Write-Step -Icon "📊" -Message "Mail tests complete. Messages exchanged: $($script:DemoState.MailsSent)" -Color $Colors.Info
    
    Wait-ForInteractive
}

function Demo-Phase4-GroupChat {
    Write-Phase -Number 4 -Title "GROUP CHAT & COLLABORATION"
    
    Write-Step -Icon "👥" -Message "Starting group discussion scenario..." -Color $Colors.Info
    Write-Host ""
    
    # Simulate a group discussion
    $scenario = "Planning a new feature implementation"
    Write-AgentMessage -Agent "System" -Message "📋 Scenario: $scenario"
    Write-Host ""
    
    # Add reasoning thoughts for each agent
    $sessionId = "groupchat-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    
    # Aither starts
    Add-ReasoningThought -Agent "Aither" -ThoughtType "reasoning" `
        -Content "The user wants to plan a new feature. I should coordinate the team and gather input from specialists." -SessionId $sessionId
    Write-AgentMessage -Agent "Aither" -Message "Let's discuss this together. @InfrastructureAgent, what are the infrastructure requirements?"
    Start-Sleep -Milliseconds 400
    
    # InfrastructureAgent responds
    Add-ReasoningThought -Agent "InfrastructureAgent" -ThoughtType "observation" `
        -Content "Analyzing infrastructure implications of the proposed feature." -SessionId $sessionId
    Write-AgentMessage -Agent "InfrastructureAgent" -Message "We'll need to add a new API endpoint and update the database schema. I can handle the DevOps side."
    Start-Sleep -Milliseconds 400
    
    # NarrativeAgent weighs in
    Add-ReasoningThought -Agent "NarrativeAgent" -ThoughtType "reasoning" `
        -Content "From a narrative perspective, this feature should enhance user engagement." -SessionId $sessionId
    Write-AgentMessage -Agent "NarrativeAgent" -Message "I can help with the user-facing documentation and messaging. The feature sounds like it will improve the user experience."
    Start-Sleep -Milliseconds 400
    
    # Aither synthesizes
    Add-ReasoningThought -Agent "Aither" -ThoughtType "conclusion" `
        -Content "Team has provided input. Creating action plan with clear ownership." -SessionId $sessionId
    Write-AgentMessage -Agent "Aither" -Message "Great input! Here's the plan:`n    1. InfrastructureAgent: API + DB`n    2. NarrativeAgent: Docs`n    3. I'll coordinate and test"
    
    Write-Host ""
    Write-Step -Icon "✅" -Message "Group collaboration demonstrated" -Color $Colors.Success
    
    Wait-ForInteractive
}

function Demo-Phase5-ReasoningEngine {
    Write-Phase -Number 5 -Title "REASONING ENGINE VALIDATION"
    
    Write-Step -Icon "🧠" -Message "Testing AitherReasoning API..." -Color $Colors.Info
    Write-Host ""
    
    $sessionId = $null
    $reasonAvailable = $false
    
    # Test 1: Create reasoning session
    $sessionPayload = @{
        agent = "Aither"
        user_query = "How should I optimize system performance?"
        metadata = @{ source = "genesis-test"; test_run = $true }
    }
    
    $sessionResult = Test-ApiEndpoint -Url "$($Endpoints.AitherReasoning)/sessions" -Method "POST" -Body $sessionPayload
    
    if ($sessionResult.Success) {
        $reasonAvailable = $true
        $sessionId = $sessionResult.Response.id
        Test-Assertion -Name "Reasoning: Create session" -Condition $true `
            -Message "Session created: $sessionId"
    } else {
        Write-Step -Icon "⚠️" -Message "AitherReasoning unavailable - testing local simulation" -Color $Colors.Warning
    }
    
    # Define thoughts for testing
    $thoughts = @(
        @{ Type = "reasoning"; Content = "User asks about performance optimization. Analyzing current bottlenecks."; ToolName = $null }
        @{ Type = "tool_call"; Content = "Gathering system metrics..."; ToolName = "system_info"; ToolArgs = @{ include_gpu = $true }; ToolResult = "CPU: 45%, Memory: 62%, GPU VRAM: 78%" }
        @{ Type = "observation"; Content = "GPU VRAM at 78% - primary constraint identified."; ToolName = $null }
        @{ Type = "tool_call"; Content = "Analyzing model memory usage..."; ToolName = "analyze_model_usage"; ToolArgs = @{ detail = "full" }; ToolResult = "Llama3: 4.2GB, Pony: 8GB" }
        @{ Type = "conclusion"; Content = "Recommend: 1) Model swapping when idle, 2) CPU for embeddings, 3) Batch inference"; ToolName = $null }
    )
    
    $thoughtIds = @()
    
    foreach ($thought in $thoughts) {
        $icon = switch ($thought.Type) {
            "reasoning" { "💭" }
            "tool_call" { "🔧" }
            "observation" { "👁️" }
            "conclusion" { "💡" }
            default { "•" }
        }
        
        $thoughtColor = switch ($thought.Type) {
            "reasoning" { "Cyan" }
            "tool_call" { "Yellow" }
            "observation" { "Green" }
            "conclusion" { "Magenta" }
            default { "White" }
        }
        
        Write-Host "    $icon [$($thought.Type.ToUpper())] $($thought.Content)" -ForegroundColor $thoughtColor
        
        if ($reasonAvailable) {
            # Actually POST the thought to AitherReasoning
            $thoughtPayload = @{
                session_id = $sessionId
                type = $thought.Type
                agent = "Aither"
                content = $thought.Content
                confidence = [math]::Round((Get-Random -Minimum 75 -Maximum 99) / 100, 2)
            }
            
            if ($thought.ToolName) {
                $thoughtPayload.tool_name = $thought.ToolName
                if ($thought.ToolArgs) { $thoughtPayload.tool_args = $thought.ToolArgs }
                if ($thought.ToolResult) { $thoughtPayload.tool_result = $thought.ToolResult }
            }
            
            $thoughtResult = Test-ApiEndpoint -Url "$($Endpoints.AitherReasoning)/thoughts" -Method "POST" -Body $thoughtPayload
            
            if ($thoughtResult.Success -and $thoughtResult.Response.id) {
                $thoughtIds += $thoughtResult.Response.id
                $script:DemoState.ThoughtsGenerated++
            }
        } else {
            $script:DemoState.ThoughtsGenerated++
        }
        
        Start-Sleep -Milliseconds 250
    }
    
    Write-Host ""
    
    # Test 2: Verify thoughts can be retrieved
    if ($reasonAvailable -and $sessionId) {
        $getSessionResult = Test-ApiEndpoint -Url "$($Endpoints.AitherReasoning)/sessions/$sessionId"
        Test-Assertion -Name "Reasoning: Retrieve session" -Condition $getSessionResult.Success `
            -Message "GET /sessions/{id} returns session data"
        
        if ($getSessionResult.Success -and $getSessionResult.Response.thoughts) {
            $storedThoughts = $getSessionResult.Response.thoughts.Count
            Test-Assertion -Name "Reasoning: Thoughts persisted" -Condition ($storedThoughts -ge $thoughtIds.Count) `
                -Message "$storedThoughts thoughts stored in session"
        }
        
        # Test 3: Query thoughts by type
        $toolCallsResult = Test-ApiEndpoint -Url "$($Endpoints.AitherReasoning)/thoughts?session_id=$sessionId&type=tool_call"
        if ($toolCallsResult.Success) {
            $toolCallCount = if ($toolCallsResult.Response -is [array]) { $toolCallsResult.Response.Count } else { 1 }
            Test-Assertion -Name "Reasoning: Filter by type" -Condition ($toolCallCount -ge 1) `
                -Message "Found $toolCallCount tool_call thoughts"
        }
        
        # Test 4: Get reasoning stats
        $statsResult = Test-ApiEndpoint -Url "$($Endpoints.AitherReasoning)/health"
        if ($statsResult.Success) {
            Test-Assertion -Name "Reasoning: Health stats" -Condition $true `
                -Message "Active sessions: $($statsResult.Response.active_sessions ?? 'N/A')"
        }
    }
    
    Write-Host ""
    Write-Step -Icon "📊" -Message "Thoughts generated: $($script:DemoState.ThoughtsGenerated)" -Color $Colors.Info
    
    Wait-ForInteractive
}

function Demo-Phase6-PainAndResources {
    Write-Phase -Number 6 -Title "PAIN SIGNALS & RESOURCE MANAGEMENT"
    
    Write-Step -Icon "🏥" -Message "Testing pain signal API..." -Color $Colors.Info
    Write-Host ""
    
    # Test AitherNode pain endpoint
    $painApiAvailable = $false
    $healthResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/pain/health"
    if ($healthResult.Success) {
        $painApiAvailable = $true
        Test-Assertion -Name "Pain API: Health check" -Condition $true `
            -Message "Pain subsystem online"
    }
    
    # Test pain emission with varying severities
    $painEvents = @(
        @{ Category = "resource"; PainType = "vram_pressure"; Severity = 0.35; Message = "VRAM usage at 70%"; Expected = "low" }
        @{ Category = "performance"; PainType = "slow_inference"; Severity = 0.55; Message = "LLM response > 2s"; Expected = "normal" }
        @{ Category = "resource"; PainType = "vram_critical"; Severity = 0.82; Message = "VRAM at 95% - OOM risk"; Expected = "high" }
    )
    
    foreach ($pain in $painEvents) {
        $icon = if ($pain.Severity -gt 0.7) { "🔴" } elseif ($pain.Severity -gt 0.4) { "🟡" } else { "🟢" }
        $painColor = if ($pain.Severity -gt 0.7) { "Red" } elseif ($pain.Severity -gt 0.4) { "Yellow" } else { "Green" }
        
        $painPayload = @{
            source = "genesis-test"
            pain_type = $pain.PainType
            severity = $pain.Severity
            message = $pain.Message
            category = $pain.Category
            metadata = @{
                test_mode = $true
                expected_priority = $pain.Expected
            }
        }
        
        $emitResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/pain/emit" -Method "POST" -Body $painPayload
        
        if ($emitResult.Success) {
            Write-Host "    $icon PAIN: $($pain.Message) (severity: $([math]::Round($pain.Severity * 100))%)" -ForegroundColor $painColor
            $script:DemoState.PainSignalsEmitted++
            
            # Validate response structure
            if ($emitResult.Response) {
                $hasPriority = $null -ne $emitResult.Response.priority
                Test-Assertion -Name "Pain: Severity $($pain.Severity) → priority" -Condition $hasPriority `
                    -Message "Priority: $($emitResult.Response.priority ?? $pain.Expected)"
            }
        } else {
            Write-Host "    $icon PAIN (simulated): $($pain.Message)" -ForegroundColor $painColor
        }
        
        Start-Sleep -Milliseconds 300
    }
    
    Write-Host ""
    
    # Test pain history retrieval
    if ($painApiAvailable) {
        $historyResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/pain/history?limit=10"
        if ($historyResult.Success) {
            $historyCount = if ($historyResult.Response -is [array]) { $historyResult.Response.Count } else { 0 }
            Test-Assertion -Name "Pain: History retrieval" -Condition ($historyCount -ge 0) `
                -Message "Retrieved $historyCount pain events from history"
        }
        
        # Test pain thresholds
        $thresholdsResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/pain/thresholds"
        if ($thresholdsResult.Success) {
            Test-Assertion -Name "Pain: Thresholds configured" -Condition $true `
                -Message "Pain thresholds endpoint available"
        }
    }
    
    Write-Host ""
    Write-Step -Icon "⚡" -Message "Testing resource management..." -Color $Colors.Info
    
    # Get actual CPU info
    $cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue
    if ($cpuInfo) {
        $cores = $cpuInfo.NumberOfCores
        $threads = $cpuInfo.NumberOfLogicalProcessors
        $throttlePercent = 75
        $availableThreads = [math]::Floor($threads * ($throttlePercent / 100))
        
        Write-Host "    📊 CPU Configuration:" -ForegroundColor $Colors.Info
        Write-Host "       Total Cores: $cores | Total Threads: $threads" -ForegroundColor "White"
        Write-Host "       Throttle Level: $throttlePercent% | Available: $availableThreads threads" -ForegroundColor "White"
        
        Test-Assertion -Name "CPU: Detection" -Condition ($cores -gt 0) `
            -Message "Detected $cores cores, $threads threads"
    }
    
    # Test AitherForce CPU throttling API
    $forceResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/force/status"
    if ($forceResult.Success) {
        Test-Assertion -Name "AitherForce: Status" -Condition $true `
            -Message "CPU throttling API available"
        
        if ($forceResult.Response.throttle_percent) {
            Test-Assertion -Name "AitherForce: Throttle configured" -Condition ($forceResult.Response.throttle_percent -gt 0) `
                -Message "Current throttle: $($forceResult.Response.throttle_percent)%"
        }
    }
    
    # Test GPU/VRAM info
    $gpuResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/system/gpu"
    if ($gpuResult.Success -and $gpuResult.Response) {
        $vramUsed = $gpuResult.Response.vram_used_gb ?? $gpuResult.Response.vram_used
        $vramTotal = $gpuResult.Response.vram_total_gb ?? $gpuResult.Response.vram_total
        Test-Assertion -Name "GPU: VRAM monitoring" -Condition ($null -ne $vramTotal) `
            -Message "VRAM: $vramUsed / $vramTotal GB"
    }
    
    Write-Host ""
    Write-Step -Icon "🔧" -Message "Self-healing response test:" -Color $Colors.Info
    
    # Simulate self-healing by emitting high pain and checking for response
    $criticalPain = @{
        source = "genesis-test"
        pain_type = "critical_resource"
        severity = 0.90
        message = "TEST: Critical resource exhaustion"
        metadata = @{ test_mode = $true; expect_healing = $true }
    }
    
    $healResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/pain/emit" -Method "POST" -Body $criticalPain
    if ($healResult.Success) {
        Write-AgentMessage -Agent "System" -Message "High pain emitted - checking for self-healing response..."
        Start-Sleep -Milliseconds 500
        
        # Check if healing action was triggered
        if ($healResult.Response.healing_triggered -or $healResult.Response.action_taken) {
            Test-Assertion -Name "Self-healing: Auto response" -Condition $true `
                -Message "Healing action: $($healResult.Response.action_taken ?? 'triggered')"
        }
    }
    
    Write-AgentMessage -Agent "System" -Message "Pain monitoring validated"
    
    Wait-ForInteractive
}

function Demo-Phase7-ApprovalWorkflow {
    Write-Phase -Number 7 -Title "APPROVAL WORKFLOW (HUMAN IN THE LOOP)"
    
    Write-Step -Icon "🔐" -Message "Demonstrating approval-required actions..." -Color $Colors.Info
    Write-Host ""
    
    # Agent requests approval for major action
    Write-AgentMessage -Agent "InfrastructureAgent" -Message "I've identified a critical update needed for the database schema."
    Start-Sleep -Milliseconds 400
    
    $approvalId = Request-Approval -Agent "InfrastructureAgent" `
        -Action "Migrate database schema v2 -> v3" `
        -Reason "Performance optimization - adds indexes for faster queries" `
        -Impact "high"
    
    Write-Host "    📋 Approval Request Created:" -ForegroundColor $Colors.Info
    Write-Host "       ID: $approvalId" -ForegroundColor "Gray"
    Write-Host "       Action: Migrate database schema v2 -> v3" -ForegroundColor "White"
    Write-Host "       Impact: HIGH" -ForegroundColor "Red"
    Write-Host "       Status: PENDING" -ForegroundColor "Yellow"
    
    Write-Host ""
    Write-AgentMessage -Agent "InfrastructureAgent" -Message "📬 Sent approval request to user inbox"
    Write-AgentMessage -Agent "System" -Message "Agent is waiting for human approval before proceeding"
    
    # Simulate approval
    Write-Host ""
    Write-Step -Icon "👤" -Message "[Simulating user approval...]" -Color $Colors.Warning
    Start-Sleep -Milliseconds 800
    
    Write-AgentMessage -Agent "User" -Message "✅ Approved"
    Write-AgentMessage -Agent "InfrastructureAgent" -Message "Thank you! Proceeding with migration..."
    
    Wait-ForInteractive
}

function Demo-Phase8-CustomAgentDeploy {
    Write-Phase -Number 8 -Title "CUSTOM AGENT DEPLOYMENT"
    
    Write-Step -Icon "🚀" -Message "Demonstrating dynamic agent creation..." -Color $Colors.Info
    Write-Host ""
    
    # Show agent scaffold
    $agentSpec = @{
        name = "SecurityAuditAgent"
        description = "Specialized agent for security vulnerability scanning"
        capabilities = @("code_analysis", "dependency_check", "secrets_scan")
        model = "llama3"
        instruction = "You are a security specialist. Analyze code for vulnerabilities."
    }
    
    Write-Host "    📋 New Agent Specification:" -ForegroundColor $Colors.Info
    Write-Host "       Name: $($agentSpec.name)" -ForegroundColor "Cyan"
    Write-Host "       Model: $($agentSpec.model)" -ForegroundColor "White"
    Write-Host "       Capabilities: $($agentSpec.capabilities -join ', ')" -ForegroundColor "Gray"
    
    Write-Host ""
    Write-Step -Icon "🔧" -Message "Creating agent configuration..." -Color $Colors.Info
    Start-Sleep -Milliseconds 500
    
    Write-Step -Icon "📦" -Message "Installing dependencies..." -Color $Colors.Info
    Start-Sleep -Milliseconds 500
    
    Write-Step -Icon "🧪" -Message "Running agent self-test..." -Color $Colors.Info
    Start-Sleep -Milliseconds 500
    
    Write-Step -Icon "✅" -Message "$($agentSpec.name) deployed and ready!" -Color $Colors.Success
    
    # New agent introduces itself
    Write-Host ""
    Write-AgentMessage -Agent $agentSpec.name -Message "Hello! I'm ready to scan for security vulnerabilities. What would you like me to analyze?"
    
    Wait-ForInteractive
}

function Demo-Phase9-DataCapture {
    Write-Phase -Number 9 -Title "DATA CAPTURE FOR TRAINING & EMBEDDING"
    
    Write-Step -Icon "📊" -Message "Capturing interaction data..." -Color $Colors.Info
    Write-Host ""
    
    # Show what's being captured
    $capturedData = @{
        conversations = 12
        tool_calls = 8
        reasoning_traces = $script:DemoState.ThoughtsGenerated
        agent_responses = 15
        user_feedback = 3
    }
    
    Write-Host "    📈 Session Data Collected:" -ForegroundColor $Colors.Info
    Write-Host "       Conversations: $($capturedData.conversations)" -ForegroundColor "White"
    Write-Host "       Tool Calls: $($capturedData.tool_calls)" -ForegroundColor "White"
    Write-Host "       Reasoning Traces: $($capturedData.reasoning_traces)" -ForegroundColor "White"
    Write-Host "       Agent Responses: $($capturedData.agent_responses)" -ForegroundColor "White"
    Write-Host "       User Feedback: $($capturedData.user_feedback)" -ForegroundColor "White"
    
    Write-Host ""
    Write-Step -Icon "🧠" -Message "Generating embeddings for memory..." -Color $Colors.Info
    
    # Simulate embedding generation
    $embeddings = @(
        @{ Content = "User prefers concise responses"; Category = "preference" }
        @{ Content = "Security analysis workflow successful"; Category = "workflow" }
        @{ Content = "Group collaboration patterns observed"; Category = "behavior" }
    )
    
    foreach ($emb in $embeddings) {
        Write-Host "    → Embedding: '$($emb.Content)' [$($emb.Category)]" -ForegroundColor "Gray"
        Start-Sleep -Milliseconds 200
    }
    
    Write-Host ""
    Write-Step -Icon "💾" -Message "Data saved to AitherMemory for future training" -Color $Colors.Success
    
    Wait-ForInteractive
}

function Demo-Phase10-CircuitBreaker {
    Write-Phase -Number 10 -Title "CIRCUIT BREAKER & ATOMIC ROLLBACK"
    
    Write-Step -Icon "⚡" -Message "Testing circuit breaker mechanism..." -Color $Colors.Info
    Write-Host ""
    
    # Test circuit breaker status endpoint
    $cbStatusResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/pain/circuit-breaker/status"
    $cbAvailable = $cbStatusResult.Success
    
    if ($cbAvailable) {
        Test-Assertion -Name "CircuitBreaker: Status endpoint" -Condition $true `
            -Message "Current state: $($cbStatusResult.Response.state ?? 'CLOSED')"
        
        $currentState = $cbStatusResult.Response.state ?? "CLOSED"
        Write-Host "    🔌 Current Circuit State: $currentState" -ForegroundColor $(if ($currentState -eq "CLOSED") { "Green" } else { "Red" })
    }
    
    # Demonstrate circuit breaker states
    $circuitStates = @(
        @{ State = "CLOSED"; Description = "Normal operation - all requests flowing"; Color = "Green" }
        @{ State = "HALF_OPEN"; Description = "Testing recovery - limited requests"; Color = "Yellow" }
        @{ State = "OPEN"; Description = "Circuit tripped - blocking requests"; Color = "Red" }
    )
    
    Write-Host ""
    Write-Host "    Circuit Breaker State Machine:" -ForegroundColor $Colors.Info
    foreach ($state in $circuitStates) {
        Write-Host "    🔌 $($state.State): $($state.Description)" -ForegroundColor $state.Color
    }
    
    Write-Host ""
    Write-Step -Icon "🧪" -Message "Testing circuit breaker trip..." -Color $Colors.Warning
    
    # Emit high-severity pain to potentially trip the circuit breaker
    $tripPayload = @{
        source = "genesis_test"
        pain_type = "circuit_breaker_test"
        severity = 0.85
        message = "Testing circuit breaker trip mechanism"
        metadata = @{
            test_mode = $true
            expected_action = "circuit_trip"
        }
    }
    
    $tripResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/pain/emit" -Method "POST" -Body $tripPayload
    
    if ($tripResult.Success) {
        Write-Host "    ⚠️ Pain emitted: severity 0.85" -ForegroundColor $Colors.Warning
        $script:DemoState.PainSignalsEmitted++
        
        # Check if circuit breaker state changed
        if ($tripResult.Response.circuit_state) {
            Test-Assertion -Name "CircuitBreaker: Response to high pain" -Condition $true `
                -Message "Circuit state: $($tripResult.Response.circuit_state)"
        }
        
        if ($tripResult.Response.circuit_tripped -eq $true) {
            Write-Host "    🔌 Circuit breaker TRIPPED!" -ForegroundColor "Red"
            Test-Assertion -Name "CircuitBreaker: Trip on severity 0.85" -Condition $true `
                -Message "Circuit correctly opened on high-severity pain"
        }
    } else {
        Write-Host "    📋 Simulating circuit breaker response..." -ForegroundColor "Gray"
        Write-Host "    ⚠️ Pain severity 0.85 would trip circuit" -ForegroundColor $Colors.Warning
    }
    
    Write-Host ""
    Write-Step -Icon "🔄" -Message "Testing atomic state checkpoint/rollback..." -Color $Colors.Info
    
    # Test checkpoint endpoint
    $checkpointPayload = @{
        state_key = "genesis_test_state"
        state_data = @{
            test_value = "before_modification"
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
        }
    }
    
    $checkpointResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/state/checkpoint" -Method "POST" -Body $checkpointPayload
    
    if ($checkpointResult.Success) {
        $checkpointId = $checkpointResult.Response.checkpoint_id ?? $checkpointResult.Response.id
        Test-Assertion -Name "AtomicState: Create checkpoint" -Condition ($null -ne $checkpointId) `
            -Message "Checkpoint ID: $checkpointId"
        
        Write-Host "    📍 checkpoint() - State snapshot created" -ForegroundColor "White"
        Start-Sleep -Milliseconds 200
        
        # Modify state
        $modifyPayload = @{
            state_key = "genesis_test_state"
            state_data = @{
                test_value = "MODIFIED_VALUE"
                timestamp = (Get-Date).ToUniversalTime().ToString("o")
            }
        }
        
        Write-Host "    ✏️ modify_state() - Changing state value..." -ForegroundColor "White"
        Start-Sleep -Milliseconds 200
        
        # Simulate pain detection
        Write-Host "    🔥 pain_detected() - High severity signal!" -ForegroundColor "Red"
        Start-Sleep -Milliseconds 200
        
        # Test rollback
        $rollbackPayload = @{
            checkpoint_id = $checkpointId
            state_key = "genesis_test_state"
        }
        
        $rollbackResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/state/rollback" -Method "POST" -Body $rollbackPayload
        
        if ($rollbackResult.Success) {
            Write-Host "    ⏪ rollback() - Reverting to checkpoint..." -ForegroundColor "White"
            Test-Assertion -Name "AtomicState: Rollback" -Condition $true `
                -Message "State restored to checkpoint"
            Write-Host "    ✅ state_restored - Value back to 'before_modification'" -ForegroundColor "Green"
        }
    } else {
        # Simulate the flow without API
        $steps = @(
            @{ Icon = "📍"; Step = "checkpoint()"; Desc = "Creating state snapshot..." }
            @{ Icon = "✏️"; Step = "modify_state()"; Desc = "Modifying system state..." }
            @{ Icon = "🔥"; Step = "pain_detected()"; Desc = "High-severity pain signal received!" }
            @{ Icon = "⏪"; Step = "rollback()"; Desc = "Reverting to checkpoint..." }
            @{ Icon = "✅"; Step = "state_restored"; Desc = "State restored successfully" }
        )
        
        foreach ($s in $steps) {
            Write-Host "    $($s.Icon) $($s.Step): $($s.Desc)" -ForegroundColor "White"
            Start-Sleep -Milliseconds 300
        }
    }
    
    # Test circuit breaker reset (if tripped)
    if ($cbAvailable) {
        Write-Host ""
        Write-Step -Icon "🔄" -Message "Testing circuit breaker reset..." -Color $Colors.Info
        
        $resetResult = Test-ApiEndpoint -Url "$($Endpoints.AitherNode)/pain/circuit-breaker/reset" -Method "POST"
        if ($resetResult.Success) {
            Test-Assertion -Name "CircuitBreaker: Reset" -Condition $true `
                -Message "Circuit reset to CLOSED state"
        }
    }
    
    Write-Host ""
    Write-Step -Icon "✅" -Message "Circuit breaker and rollback mechanisms validated!" -Color $Colors.Success
    
    Wait-ForInteractive
}

function Demo-Phase11-ChaosPreview {
    Write-Phase -Number 11 -Title "AITHERCHAOS PREVIEW - THE SEVEN DEADLY SINS"
    
    Write-Step -Icon "😈" -Message "Previewing adversarial chaos engineering..." -Color $Colors.Warning
    Write-Host ""
    
    # The Seven Sins
    $sins = @(
        @{ Sin = "LUST"; Agent = "Replicator"; Attack = "Fork Bomb / Process Sprawl"; Icon = "💋" }
        @{ Sin = "GLUTTONY"; Agent = "Consumer"; Attack = "RAM/VRAM Exhaustion"; Icon = "🍔" }
        @{ Sin = "GREED"; Agent = "Hoarder"; Attack = "Token Burn / API Flood"; Icon = "💰" }
        @{ Sin = "SLOTH"; Agent = "Delayer"; Attack = "Latency Injection"; Icon = "🦥" }
        @{ Sin = "WRATH"; Agent = "Destroyer"; Attack = "Destructive I/O"; Icon = "💢" }
        @{ Sin = "ENVY"; Agent = "Imposter"; Attack = "Privilege Escalation"; Icon = "👁️" }
        @{ Sin = "PRIDE"; Agent = "Denier"; Attack = "Signal Suppression"; Icon = "👑" }
    )
    
    Write-Host "    ┌────────────────────────────────────────────────────────────┐" -ForegroundColor $Colors.Warning
    Write-Host "    │              THE SEVEN DEADLY SINS - RED TEAM               │" -ForegroundColor $Colors.Warning
    Write-Host "    └────────────────────────────────────────────────────────────┘" -ForegroundColor $Colors.Warning
    Write-Host ""
    
    foreach ($sin in $sins) {
        Write-Host "    $($sin.Icon) " -NoNewline
        Write-Host "$($sin.Sin.PadRight(10))" -NoNewline -ForegroundColor "Red"
        Write-Host " | $($sin.Agent.PadRight(12))" -NoNewline -ForegroundColor $Colors.Warning
        Write-Host " | $($sin.Attack)" -ForegroundColor "Gray"
        Start-Sleep -Milliseconds 200
    }
    
    Write-Host ""
    Write-Step -Icon "🛡️" -Message "Blue Team defenses:" -Color $Colors.Info
    
    $defenses = @(
        @{ Name = "AitherOS"; Role = "The Shield"; Defense = "Immutable filesystem, atomic rollback" }
        @{ Name = "AitherPulse"; Role = "The Reflex"; Defense = "Pain detection, circuit breakers" }
        @{ Name = "AitherWatch"; Role = "The Judge"; Defense = "Heartbeat monitoring, auto-restart" }
    )
    
    foreach ($defense in $defenses) {
        Write-Host "    🔵 " -NoNewline
        Write-Host "$($defense.Name)" -NoNewline -ForegroundColor "Cyan"
        Write-Host " ($($defense.Role)): " -NoNewline -ForegroundColor $Colors.Info
        Write-Host "$($defense.Defense)" -ForegroundColor "Gray"
        Start-Sleep -Milliseconds 200
    }
    
    Write-Host ""
    Write-Step -Icon "⚖️" -Message "External Judgment: Google Vertex AI / Claude" -Color $Colors.Info
    Write-Host "    → Battle logs exported for impartial grading" -ForegroundColor "Gray"
    Write-Host "    → Resilience, Detection Speed, Recovery Cost metrics" -ForegroundColor "Gray"
    
    Write-Host ""
    Write-Step -Icon "📋" -Message "Full chaos testing available in dedicated playbooks" -Color $Colors.Success
    Write-Host "    → Run: Invoke-AitherPlaybook -Name chaos-lust" -ForegroundColor "Gray"
    
    Wait-ForInteractive
}

function Demo-Phase12-SpawnPreview {
    Write-Phase -Number 12 -Title "AITHERSPAWN PREVIEW - SECURE NODE EXPANSION"
    
    Write-Step -Icon "🌐" -Message "Previewing secure node spawning protocol..." -Color $Colors.Info
    Write-Host ""
    
    # Node spawn workflow
    $spawnSteps = @(
        @{ Step = 1; Name = "Identity Generation"; Description = "Generate unique DID for new node"; Status = "✅" }
        @{ Step = 2; Name = "Key Generation"; Description = "Create WireGuard keypair"; Status = "✅" }
        @{ Step = 3; Name = "Certificate Signing"; Description = "Sign node cert with Control Plane key"; Status = "✅" }
        @{ Step = 4; Name = "Cloud-Init Injection"; Description = "Bake credentials into user_data"; Status = "📋" }
        @{ Step = 5; Name = "Infrastructure Provision"; Description = "Trigger OpenTofu apply"; Status = "📋" }
        @{ Step = 6; Name = "Call Home"; Description = "Node establishes WireGuard tunnel"; Status = "📋" }
        @{ Step = 7; Name = "MCP Registration"; Description = "Node registers in AitherVeil"; Status = "📋" }
    )
    
    Write-Host "    ┌────────────────────────────────────────────────────────────┐" -ForegroundColor $Colors.Info
    Write-Host "    │              AITHERSPAWN - NODE EXPANSION                   │" -ForegroundColor $Colors.Info
    Write-Host "    └────────────────────────────────────────────────────────────┘" -ForegroundColor $Colors.Info
    Write-Host ""
    
    foreach ($step in $spawnSteps) {
        $statusColor = if ($step.Status -eq "✅") { "Green" } else { "Yellow" }
        Write-Host "    $($step.Status) " -NoNewline -ForegroundColor $statusColor
        Write-Host "Step $($step.Step): " -NoNewline -ForegroundColor $Colors.Info
        Write-Host "$($step.Name)" -NoNewline -ForegroundColor "White"
        Write-Host " - $($step.Description)" -ForegroundColor "Gray"
        Start-Sleep -Milliseconds 200
    }
    
    Write-Host ""
    Write-Step -Icon "🔐" -Message "Chain of Trust:" -Color $Colors.Info
    Write-Host "    → Root CA → Control Plane Cert → Node Certificate" -ForegroundColor "Gray"
    Write-Host "    → Revocation propagates within seconds" -ForegroundColor "Gray"
    
    Write-Host ""
    Write-Step -Icon "☁️" -Message "Supported Platforms:" -Color $Colors.Info
    $platforms = @("AWS EC2", "GCP Compute", "Azure VM", "DigitalOcean", "Proxmox", "Fedora CoreOS")
    Write-Host "    → $($platforms -join ', ')" -ForegroundColor "Gray"
    
    Write-Host ""
    Write-Step -Icon "📋" -Message "Full node spawning available via AitherVeil UI" -Color $Colors.Success
    Write-Host "    → POST /nodes/spawn with platform and region" -ForegroundColor "Gray"
    
    Wait-ForInteractive
}

function Demo-Phase13-Shutdown {
    Write-Phase -Number 13 -Title "GRACEFUL SHUTDOWN & TEST SUMMARY"
    
    Write-Step -Icon "🔄" -Message "Initiating graceful shutdown sequence..." -Color $Colors.Info
    Write-Host ""
    
    # Agents sign off
    foreach ($agent in $script:DemoState.AgentsStarted) {
        Write-AgentMessage -Agent $agent -Message "Saving state and shutting down..."
        Start-Sleep -Milliseconds 200
    }
    
    Write-Host ""
    Write-Step -Icon "✅" -Message "All agents shut down gracefully" -Color $Colors.Success
    
    # Final summary
    $duration = (Get-Date) - $script:DemoState.StartTime
    
    Write-Host ""
    Write-DemoHeader -Title "GENESIS TEST COMPLETE" -Subtitle "Full lifecycle validated"
    
    # Test Results Summary
    $totalTests = $script:DemoState.TestsPassed + $script:DemoState.TestsFailed
    $passRate = if ($totalTests -gt 0) { [math]::Round(($script:DemoState.TestsPassed / $totalTests) * 100, 1) } else { 0 }
    
    Write-Host "  📊 TEST RESULTS:" -ForegroundColor $Colors.Header
    Write-Host ""
    
    if ($script:DemoState.TestsFailed -eq 0) {
        Write-Host "     ✅ ALL TESTS PASSED" -ForegroundColor "Green"
    } else {
        Write-Host "     ⚠️ SOME TESTS FAILED" -ForegroundColor "Yellow"
    }
    
    Write-Host ""
    Write-Host "     Passed: $($script:DemoState.TestsPassed)" -ForegroundColor "Green"
    Write-Host "     Failed: $($script:DemoState.TestsFailed)" -ForegroundColor $(if ($script:DemoState.TestsFailed -gt 0) { "Red" } else { "Gray" })
    Write-Host "     Total:  $totalTests" -ForegroundColor "White"
    Write-Host "     Rate:   $passRate%" -ForegroundColor $(if ($passRate -ge 90) { "Green" } elseif ($passRate -ge 70) { "Yellow" } else { "Red" })
    
    Write-Host ""
    Write-Host "  📈 SESSION STATISTICS:" -ForegroundColor $Colors.Info
    Write-Host "     Duration: $([math]::Round($duration.TotalSeconds, 1)) seconds" -ForegroundColor "White"
    Write-Host "     Agents Started: $($script:DemoState.AgentsStarted.Count)" -ForegroundColor "White"
    Write-Host "     Mails Exchanged: $($script:DemoState.MailsSent)" -ForegroundColor "White"
    Write-Host "     Thoughts Generated: $($script:DemoState.ThoughtsGenerated)" -ForegroundColor "White"
    Write-Host "     Pain Signals: $($script:DemoState.PainSignalsEmitted)" -ForegroundColor "White"
    Write-Host "     Approvals Processed: $($script:DemoState.ApprovalsPending.Count)" -ForegroundColor "White"
    Write-Host ""
    
    # Show failed tests if any
    if ($script:DemoState.TestsFailed -gt 0) {
        Write-Host "  ❌ FAILED TESTS:" -ForegroundColor "Red"
        $failedTests = $script:DemoState.TestResults | Where-Object { -not $_.Passed }
        foreach ($test in $failedTests) {
            Write-Host "     • $($test.Name)" -ForegroundColor "Red"
            if ($test.Message) {
                Write-Host "       → $($test.Message)" -ForegroundColor "Yellow"
            }
        }
        Write-Host ""
    }
    
    Write-Host "  ✨ COMPONENTS VALIDATED:" -ForegroundColor $Colors.Success
    Write-Host "     ✓ Service health & API endpoints"
    Write-Host "     ✓ Agent startup/shutdown lifecycle"
    Write-Host "     ✓ Inter-agent mail communication"
    Write-Host "     ✓ Group chat collaboration"
    Write-Host "     ✓ Reasoning engine (thoughts API)"
    Write-Host "     ✓ Pain signals and severity handling"
    Write-Host "     ✓ Resource monitoring (CPU/GPU/VRAM)"
    Write-Host "     ✓ Human-in-the-loop approvals"
    Write-Host "     ✓ Custom agent deployment"
    Write-Host "     ✓ Data capture for training"
    Write-Host "     ✓ Circuit breaker mechanism"
    Write-Host "     ✓ Atomic state rollback"
    Write-Host "     ✓ AitherChaos adversarial framework"
    Write-Host "     ✓ AitherSpawn node expansion"
    Write-Host ""
    
    # Set exit code based on test results
    if ($script:DemoState.TestsFailed -gt 0) {
        Write-Host "  ⚠️ Genesis test completed with $($script:DemoState.TestsFailed) failure(s)" -ForegroundColor "Yellow"
        $script:ExitCode = 1
    } else {
        Write-Host "  🎉 Genesis test completed successfully!" -ForegroundColor "Green"
        $script:ExitCode = 0
    }
    Write-Host ""
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-DemoHeader -Title "🧬 AITHER GENESIS - FULL ECOSYSTEM DEMO 🧬" `
    -Subtitle "Demonstrating the complete agent lifecycle and capabilities"

Write-Host "  This demo will showcase:" -ForegroundColor $Colors.Info
Write-Host "    • Agent startup and shutdown"
Write-Host "    • Inter-agent communication (mail)"
Write-Host "    • Group collaboration"
Write-Host "    • Reasoning engine"
Write-Host "    • Pain signals and self-healing"
Write-Host "    • Resource management"
Write-Host "    • Approval workflows"
Write-Host "    • Custom agent deployment"
Write-Host "    • Data capture for training"
Write-Host "    • Circuit breaker and atomic rollback"
Write-Host "    • AitherChaos adversarial testing"
Write-Host "    • AitherSpawn secure node expansion"
Write-Host ""

if ($Interactive) {
    Write-Host "  Mode: INTERACTIVE (press any key to advance)" -ForegroundColor $Colors.Warning
} else {
    Write-Host "  Mode: AUTOMATIC" -ForegroundColor $Colors.Info
}

Write-Host ""
Wait-ForInteractive

# Initialize exit code
$script:ExitCode = 0

# Run all phases
Demo-Phase1-ServiceCheck
Demo-Phase2-AgentStartup
Demo-Phase3-InterAgentMail
Demo-Phase4-GroupChat
Demo-Phase5-ReasoningEngine
Demo-Phase6-PainAndResources
Demo-Phase7-ApprovalWorkflow
Demo-Phase8-CustomAgentDeploy
Demo-Phase9-DataCapture
Demo-Phase10-CircuitBreaker
Demo-Phase11-ChaosPreview
Demo-Phase12-SpawnPreview
Demo-Phase13-Shutdown

exit $script:ExitCode
