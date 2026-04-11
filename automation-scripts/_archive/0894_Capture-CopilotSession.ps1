<#
.SYNOPSIS
    Captures GitHub Copilot session data for training data generation.

.DESCRIPTION
    Processes structured session exports from GitHub Copilot conversations and converts
    them to JSONL training data format for aither-7b fine-tuning.
    
    Supports three input methods:
    1. -FromClipboard: Read session data from Windows clipboard
    2. -InputFile: Read from a specified file
    3. -InputJson: Direct JSON string input
    
    Output is written to training-data/chronicle/interactions/ and optionally
    converted to training examples in training-data/aither-7b/conversations/.

.PARAMETER FromClipboard
    Read session data from the Windows clipboard.

.PARAMETER InputFile
    Path to a file containing session data (JSON or aither-session format).

.PARAMETER InputJson
    Direct JSON string input for session data.

.PARAMETER GenerateTraining
    Also generate training examples from the session (default: true).

.PARAMETER ShowOutput
    Display processing output and statistics.

.PARAMETER DryRun
    Parse and validate without writing files.

.EXAMPLE
    # Capture from clipboard after copying session block from Copilot
    .\0894_Capture-CopilotSession.ps1 -FromClipboard -ShowOutput

.EXAMPLE
    # Process a saved session file
    .\0894_Capture-CopilotSession.ps1 -InputFile "session.json" -GenerateTraining

.EXAMPLE
    # Dry run to validate format
    .\0894_Capture-CopilotSession.ps1 -FromClipboard -DryRun -ShowOutput

.NOTES
    Script: 0894_Capture-CopilotSession.ps1
    Category: AI/Training (07xx-08xx range)
    Requires: AitherZero module
    
    Session data format (aither-session):
    {
      "session_id": "copilot-YYYYMMDD-HHMMSS",
      "agent": "github-copilot-claude",
      "model": "claude-opus-4",
      "outcome": "success",
      "quality_score": 0.85,
      ...
    }
#>

[CmdletBinding(DefaultParameterSetName = 'Clipboard')]
param(
    [Parameter(ParameterSetName = 'Clipboard')]
    [switch]$FromClipboard,

    [Parameter(ParameterSetName = 'File')]
    [string]$InputFile,

    [Parameter(ParameterSetName = 'Json')]
    [string]$InputJson,

    [switch]$GenerateTraining = $true,
    [switch]$ShowOutput,
    [switch]$DryRun
)

# Initialize
. "$PSScriptRoot/_init.ps1"

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    if ($ShowOutput) {
        $color = switch ($Type) {
            "Success" { "Green" }
            "Warning" { "Yellow" }
            "Error" { "Red" }
            default { "Cyan" }
        }
        Write-Host $Message -ForegroundColor $color
    }
}

function Parse-AitherSession {
    param([string]$Content)
    
    # Try to extract JSON from aither-session code block
    if ($Content -match '```aither-session\s*\n([\s\S]*?)\n```') {
        $jsonContent = $Matches[1].Trim()
    }
    elseif ($Content -match '```aither-session-quick\s*\n([\s\S]*?)\n```') {
        # Parse quick format
        $lines = $Matches[1].Trim() -split "`n"
        $quickData = @{}
        foreach ($line in $lines) {
            if ($line -match '^(\w+):\s*(.+)$') {
                $key = $Matches[1]
                $value = $Matches[2].Trim()
                # Handle array syntax
                if ($value -match '^\[(.*)\]$') {
                    $value = ($Matches[1] -split ',\s*') | ForEach-Object { $_.Trim() }
                }
                $quickData[$key] = $value
            }
        }
        # Convert to full format
        return @{
            session_id = $quickData.session ?? "copilot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            agent = "github-copilot"
            outcome = $quickData.outcome ?? "success"
            quality_score = [double]($quickData.quality ?? 0.7)
            tags = $quickData.tags ?? @()
            user_query_summary = $quickData.summary ?? ""
            files_modified = $quickData.files ?? @()
            timestamp = (Get-Date).ToString("o")
        }
    }
    elseif ($Content.Trim().StartsWith('{')) {
        # Direct JSON
        $jsonContent = $Content.Trim()
    }
    else {
        throw "Could not find valid aither-session or JSON content in input"
    }
    
    return $jsonContent | ConvertFrom-Json -AsHashtable
}

function Convert-ToTrainingExample {
    param([hashtable]$Session)
    
    $example = @{
        id = "aither-conv-$($Session.session_id)"
        type = "conversation"
        source = "copilot_session"
        messages = @()
        metadata = @{
            quality_score = $Session.quality_score ?? 0.7
            domain = "aitherzero"
            tags = $Session.tags ?? @()
            outcome = $Session.outcome ?? "success"
            timestamp = $Session.timestamp ?? (Get-Date).ToString("o")
            model = $Session.model ?? "unknown"
            agent = $Session.agent ?? "github-copilot"
        }
    }
    
    # Add system message
    $example.messages += @{
        role = "system"
        content = "You are Aither, an expert AI coding agent for the AitherZero platform. You help with PowerShell automation, Python AI agents, and system architecture."
    }
    
    # Convert highlights to messages if available
    if ($Session.conversation_highlights) {
        foreach ($highlight in $Session.conversation_highlights) {
            $example.messages += @{
                role = "user"
                content = $highlight.user
            }
            $example.messages += @{
                role = "assistant"
                content = $highlight.assistant
            }
        }
    }
    else {
        # Use summary as single turn
        $example.messages += @{
            role = "user"
            content = $Session.user_query_summary ?? "Unknown request"
        }
        $example.messages += @{
            role = "assistant"
            content = "Session completed with outcome: $($Session.outcome). Key decisions: $($Session.key_decisions -join '; ')"
        }
    }
    
    return $example
}

# Main execution
try {
    Write-Status "🎯 Copilot Session Capture" "Info"
    Write-Status "=" * 50 "Info"
    
    # Get input content
    $content = $null
    switch ($PSCmdlet.ParameterSetName) {
        'Clipboard' {
            Write-Status "📋 Reading from clipboard..." "Info"
            $content = Get-Clipboard -Raw
            if ([string]::IsNullOrWhiteSpace($content)) {
                throw "Clipboard is empty. Copy an aither-session block first."
            }
        }
        'File' {
            Write-Status "📄 Reading from file: $InputFile" "Info"
            if (-not (Test-Path $InputFile)) {
                throw "Input file not found: $InputFile"
            }
            $content = Get-Content $InputFile -Raw
        }
        'Json' {
            Write-Status "📝 Using direct JSON input" "Info"
            $content = $InputJson
        }
    }
    
    # Parse session data
    Write-Status "🔍 Parsing session data..." "Info"
    $sessionData = Parse-AitherSession -Content $content
    
    # Generate session ID if not present
    if (-not $sessionData.session_id) {
        $sessionData.session_id = "copilot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }
    
    # Add timestamp if not present
    if (-not $sessionData.timestamp) {
        $sessionData.timestamp = (Get-Date).ToString("o")
    }
    
    Write-Status "✅ Parsed session: $($sessionData.session_id)" "Success"
    Write-Status "   Agent: $($sessionData.agent ?? 'unknown')" "Info"
    Write-Status "   Outcome: $($sessionData.outcome ?? 'unknown')" "Info"
    Write-Status "   Quality: $($sessionData.quality_score ?? 'N/A')" "Info"
    
    if ($DryRun) {
        Write-Status "`n🔸 DRY RUN - No files written" "Warning"
        Write-Status "Session data:" "Info"
        $sessionData | ConvertTo-Json -Depth 10 | Write-Host
        exit 0
    }
    
    # Ensure output directories exist
    $chroniclePath = Join-Path $projectRoot "AitherOS/training-data/chronicle/interactions"
    $trainingPath = Join-Path $projectRoot "AitherOS/training-data/aither-7b/conversations"
    
    New-Item -ItemType Directory -Path $chroniclePath -Force | Out-Null
    New-Item -ItemType Directory -Path $trainingPath -Force | Out-Null
    
    # Write raw session to chronicle
    $sessionFile = Join-Path $chroniclePath "$($sessionData.session_id).json"
    $sessionData | ConvertTo-Json -Depth 10 | Set-Content $sessionFile -Encoding UTF8
    Write-Status "📁 Saved session: $sessionFile" "Success"
    
    # Generate training example if requested
    if ($GenerateTraining) {
        Write-Status "`n🧠 Generating training example..." "Info"
        $trainingExample = Convert-ToTrainingExample -Session $sessionData
        
        $trainingFile = Join-Path $trainingPath "$($sessionData.session_id).jsonl"
        $trainingExample | ConvertTo-Json -Depth 10 -Compress | Set-Content $trainingFile -Encoding UTF8
        Write-Status "📁 Saved training data: $trainingFile" "Success"
    }
    
    Write-Status "`n✅ Session capture complete!" "Success"
    exit 0
}
catch {
    Write-Status "❌ Error: $($_.Exception.Message)" "Error"
    if ($ShowOutput) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    exit 1
}
