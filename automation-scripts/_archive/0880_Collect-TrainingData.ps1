<#
.SYNOPSIS
    Collects training data from logs, transcripts, and benchmarks for AI improvement.

.DESCRIPTION
    Harvests operational data for training AI models:
    - PowerShell transcript logs (command patterns, error handling)
    - AitherZero operation logs (timing, success/failure)
    - Agent conversation logs (mailbox messages)
    - Benchmark results (performance metrics)
    - Reasoning traces (CoT data)
    
    Outputs data in formats suitable for:
    - SFT (Supervised Fine-Tuning)
    - DPO (Direct Preference Optimization)
    - RLHF (Reinforcement Learning from Human Feedback)

.PARAMETER DaysBack
    Number of days of history to collect. Default: 7

.PARAMETER OutputPath
    Directory to save processed training data. Default: AitherOS/training-data

.PARAMETER Format
    Output format: jsonl, parquet, or both. Default: jsonl

.PARAMETER IncludeTranscripts
    Include PowerShell transcript logs

.PARAMETER IncludeBenchmarks
    Include benchmark results

.PARAMETER IncludeConversations
    Include agent mailbox conversations

.PARAMETER ShowOutput
    Display detailed output during collection

.EXAMPLE
    ./0880_Collect-TrainingData.ps1 -DaysBack 30 -ShowOutput

.EXAMPLE
    ./0880_Collect-TrainingData.ps1 -IncludeTranscripts -IncludeBenchmarks -Format both

.NOTES
    Script Number: 0880
    Category: AI Training (0800-0899)
    Related: AitherTrainer integration
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$DaysBack = 7,

    [Parameter()]
    [string]$OutputPath = "AitherOS/training-data",

    [Parameter()]
    [ValidateSet("jsonl", "parquet", "both")]
    [string]$Format = "jsonl",

    [Parameter()]
    [switch]$IncludeTranscripts = $true,

    [Parameter()]
    [switch]$IncludeBenchmarks = $true,

    [Parameter()]
    [switch]$IncludeConversations = $true,

    [Parameter()]
    [switch]$IncludeLogs = $true,

    [Parameter()]
    [switch]$ShowOutput
)

# ============================================================================
# INITIALIZATION
# ============================================================================
. "$PSScriptRoot/_init.ps1"

$scriptName = "Collect-TrainingData"
Write-ScriptLog -Message "Starting training data collection..." -Level Information -Component $scriptName

# ============================================================================
# CONFIGURATION
# ============================================================================
$cutoffDate = (Get-Date).AddDays(-$DaysBack)
$outputDir = Join-Path $projectRoot $OutputPath
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Source directories
$transcriptDir = Join-Path $env:USERPROFILE "Documents\PowerShell\Transcripts"
$azerLogsDir = Join-Path $projectRoot "AitherZero\logs"
$benchmarkDir = Join-Path $projectRoot "AitherZero\benchmarks\history"
$agentDir = Join-Path $projectRoot "AitherOS\agents"

# Create output directory
if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

# ============================================================================
# DATA STRUCTURES
# ============================================================================
$trainingData = @{
    metadata = @{
        collected_at = Get-Date -Format "o"
        days_back = $DaysBack
        cutoff_date = $cutoffDate.ToString("o")
        sources = @()
    }
    sft_examples = @()       # Instruction-response pairs
    dpo_pairs = @()          # Preference pairs
    benchmarks = @()         # Performance metrics
    conversations = @()      # Agent dialogues
}

# ============================================================================
# TRANSCRIPT COLLECTION
# ============================================================================
if ($IncludeTranscripts -and (Test-Path $transcriptDir)) {
    if ($ShowOutput) { Write-Host "📝 Collecting PowerShell transcripts..." -ForegroundColor Cyan }
    
    $transcripts = Get-ChildItem -Path $transcriptDir -Filter "*.txt" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $cutoffDate }
    
    $processedCount = 0
    foreach ($transcript in $transcripts) {
        try {
            $content = Get-Content $transcript.FullName -Raw -ErrorAction Stop
            
            # Parse transcript into command blocks
            $commands = [regex]::Matches($content, 'PS [^>]+> (.+?)(?=PS [^>]+>|$)', 'Singleline')
            
            foreach ($match in $commands) {
                $command = $match.Groups[1].Value.Trim()
                
                # Skip empty or very short commands
                if ($command.Length -lt 5) { continue }
                
                # Create SFT example
                $trainingData.sft_examples += @{
                    instruction = "Execute this PowerShell command"
                    input = ""
                    output = $command
                    source = "powershell_transcript"
                    timestamp = $transcript.LastWriteTime.ToString("o")
                    quality_score = 0.8  # Base quality score
                }
                $processedCount++
            }
        }
        catch {
            if ($ShowOutput) { Write-Host "  ⚠ Error processing $($transcript.Name): $_" -ForegroundColor Yellow }
        }
    }
    
    $trainingData.metadata.sources += @{
        type = "transcripts"
        count = $processedCount
        path = $transcriptDir
    }
    
    if ($ShowOutput) { Write-Host "  ✓ Processed $processedCount commands from $($transcripts.Count) transcripts" -ForegroundColor Green }
}

# ============================================================================
# BENCHMARK COLLECTION
# ============================================================================
if ($IncludeBenchmarks -and (Test-Path $benchmarkDir)) {
    if ($ShowOutput) { Write-Host "📊 Collecting benchmark results..." -ForegroundColor Cyan }
    
    $benchmarks = Get-ChildItem -Path $benchmarkDir -Filter "*.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $cutoffDate }
    
    foreach ($benchmark in $benchmarks) {
        try {
            $data = Get-Content $benchmark.FullName -Raw | ConvertFrom-Json
            
            $trainingData.benchmarks += @{
                timestamp = $data.Timestamp ?? $benchmark.LastWriteTime.ToString("o")
                test_run = $data.TestRun ?? $benchmark.BaseName
                gpu = $data.GPU ?? @{}
                embedding = $data.Embedding ?? @{}
                models = $data.Models ?? @{}
                results = $data.Results ?? @{}
            }
        }
        catch {
            if ($ShowOutput) { Write-Host "  ⚠ Error processing $($benchmark.Name): $_" -ForegroundColor Yellow }
        }
    }
    
    $trainingData.metadata.sources += @{
        type = "benchmarks"
        count = $benchmarks.Count
        path = $benchmarkDir
    }
    
    if ($ShowOutput) { Write-Host "  ✓ Collected $($benchmarks.Count) benchmark files" -ForegroundColor Green }
}

# ============================================================================
# CONVERSATION COLLECTION
# ============================================================================
if ($IncludeConversations -and (Test-Path $agentDir)) {
    if ($ShowOutput) { Write-Host "💬 Collecting agent conversations..." -ForegroundColor Cyan }
    
    $mailboxFiles = Get-ChildItem -Path $agentDir -Filter "mailbox.json" -Recurse -ErrorAction SilentlyContinue
    
    $conversationCount = 0
    foreach ($mailbox in $mailboxFiles) {
        try {
            $data = Get-Content $mailbox.FullName -Raw | ConvertFrom-Json
            
            if ($data.messages) {
                foreach ($msg in $data.messages) {
                    # Filter by date if timestamp available
                    if ($msg.timestamp) {
                        $msgDate = [datetime]::Parse($msg.timestamp)
                        if ($msgDate -lt $cutoffDate) { continue }
                    }
                    
                    $trainingData.conversations += @{
                        from_agent = $msg.from ?? "unknown"
                        to_agent = $msg.to ?? "unknown"
                        subject = $msg.subject ?? ""
                        body = $msg.body ?? ""
                        timestamp = $msg.timestamp ?? ""
                        agent_path = $mailbox.Directory.Name
                    }
                    $conversationCount++
                }
            }
        }
        catch {
            if ($ShowOutput) { Write-Host "  ⚠ Error processing $($mailbox.FullName): $_" -ForegroundColor Yellow }
        }
    }
    
    $trainingData.metadata.sources += @{
        type = "conversations"
        count = $conversationCount
        path = $agentDir
    }
    
    if ($ShowOutput) { Write-Host "  ✓ Collected $conversationCount agent messages" -ForegroundColor Green }
}

# ============================================================================
# LOG COLLECTION
# ============================================================================
if ($IncludeLogs -and (Test-Path $azerLogsDir)) {
    if ($ShowOutput) { Write-Host "📋 Collecting AitherZero logs..." -ForegroundColor Cyan }
    
    $logFiles = Get-ChildItem -Path $azerLogsDir -Filter "*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $cutoffDate }
    
    $logEntries = 0
    foreach ($logFile in $logFiles) {
        try {
            $lines = Get-Content $logFile.FullName -ErrorAction Stop
            
            foreach ($line in $lines) {
                # Parse log entries (format: [LEVEL] Component: Message)
                if ($line -match '^\[(\w+)\]\s+(.+?):\s+(.+)$') {
                    $level = $matches[1]
                    $component = $matches[2]
                    $message = $matches[3]
                    
                    # Create training examples from errors (learning from mistakes)
                    if ($level -in @("ERROR", "WARN")) {
                        $trainingData.sft_examples += @{
                            instruction = "Identify and fix this error"
                            input = $message
                            output = "Error in $component - investigate and resolve"
                            source = "aitherzero_logs"
                            quality_score = 0.7
                        }
                        $logEntries++
                    }
                }
            }
        }
        catch {
            if ($ShowOutput) { Write-Host "  ⚠ Error processing $($logFile.Name): $_" -ForegroundColor Yellow }
        }
    }
    
    $trainingData.metadata.sources += @{
        type = "logs"
        count = $logEntries
        path = $azerLogsDir
    }
    
    if ($ShowOutput) { Write-Host "  ✓ Processed $logEntries log entries from $($logFiles.Count) files" -ForegroundColor Green }
}

# ============================================================================
# OUTPUT GENERATION
# ============================================================================
if ($ShowOutput) { Write-Host "`n💾 Saving training data..." -ForegroundColor Cyan }

# Calculate totals
$totalSFT = $trainingData.sft_examples.Count
$totalDPO = $trainingData.dpo_pairs.Count
$totalBenchmarks = $trainingData.benchmarks.Count
$totalConversations = $trainingData.conversations.Count

$trainingData.metadata.totals = @{
    sft_examples = $totalSFT
    dpo_pairs = $totalDPO
    benchmarks = $totalBenchmarks
    conversations = $totalConversations
}

# Save as JSONL (one JSON object per line - standard for LLM training)
if ($Format -in @("jsonl", "both")) {
    $sftFile = Join-Path $outputDir "sft_${timestamp}.jsonl"
    $trainingData.sft_examples | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $sftFile
    
    $benchmarkFile = Join-Path $outputDir "benchmarks_${timestamp}.jsonl"
    $trainingData.benchmarks | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } | Set-Content $benchmarkFile
    
    $conversationFile = Join-Path $outputDir "conversations_${timestamp}.jsonl"
    $trainingData.conversations | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $conversationFile
    
    # Save full metadata
    $metadataFile = Join-Path $outputDir "metadata_${timestamp}.json"
    $trainingData.metadata | ConvertTo-Json -Depth 10 | Set-Content $metadataFile
    
    if ($ShowOutput) {
        Write-Host "  ✓ SFT examples: $sftFile" -ForegroundColor Green
        Write-Host "  ✓ Benchmarks: $benchmarkFile" -ForegroundColor Green
        Write-Host "  ✓ Conversations: $conversationFile" -ForegroundColor Green
        Write-Host "  ✓ Metadata: $metadataFile" -ForegroundColor Green
    }
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║              TRAINING DATA COLLECTION COMPLETE                ║" -ForegroundColor Magenta
Write-Host "╠═══════════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "║  SFT Examples:    $($totalSFT.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║  DPO Pairs:       $($totalDPO.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║  Benchmarks:      $($totalBenchmarks.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║  Conversations:   $($totalConversations.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║                                                               ║" -ForegroundColor Magenta
Write-Host "║  Output: $OutputPath" -ForegroundColor Magenta
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

Write-ScriptLog -Message "Training data collection complete. SFT: $totalSFT, Benchmarks: $totalBenchmarks, Conversations: $totalConversations" -Level Information -Component $scriptName

exit 0
