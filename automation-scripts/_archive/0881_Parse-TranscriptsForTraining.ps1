<#
.SYNOPSIS
    Parse PowerShell transcripts into rich training data for aither-7b.

.DESCRIPTION
    Extracts high-value training examples from PowerShell transcripts:
    - Command-output pairs (what commands produce what results)
    - Error handling patterns (troubleshooting flows)
    - Multi-step workflows (complex task completion)
    - Git operations (commit patterns, branch management)
    - Service management (startup, health checks, debugging)
    
    Creates structured JSONL for:
    - SFT (Supervised Fine-Tuning): instruction/output pairs
    - CoT (Chain of Thought): multi-step reasoning traces
    - DPO (Direct Preference Optimization): success vs failure pairs

.PARAMETER TranscriptPath
    Path to transcript file(s) or directory. Default: AitherZero/library/logs

.PARAMETER DaysBack
    Number of days of transcripts to process. Default: 7

.PARAMETER OutputPath
    Directory to save training data. Default: training-data/aither-7b/powershell

.PARAMETER MinQuality
    Minimum quality score (0.0-1.0) to include. Default: 0.5

.PARAMETER ShowOutput
    Display detailed processing output

.EXAMPLE
    ./0881_Parse-TranscriptsForTraining.ps1 -ShowOutput

.EXAMPLE
    ./0881_Parse-TranscriptsForTraining.ps1 -DaysBack 30 -MinQuality 0.7

.NOTES
    Script Number: 0881
    Category: AI Training (0800-0899)
    Related: 0880_Collect-TrainingData.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$TranscriptPath,

    [Parameter()]
    [int]$DaysBack = 7,

    [Parameter()]
    [string]$OutputPath = "training-data/aither-7b/powershell",

    [Parameter()]
    [double]$MinQuality = 0.5,

    [Parameter()]
    [switch]$ShowOutput
)

# ============================================================================
# INITIALIZATION
# ============================================================================
. "$PSScriptRoot/_init.ps1"

$scriptName = "Parse-TranscriptsForTraining"
Write-ScriptLog -Message "Starting transcript parsing for training data..." -Level Information -Component $scriptName

# ============================================================================
# CONFIGURATION
# ============================================================================
$cutoffDate = (Get-Date).AddDays(-$DaysBack)
$outputDir = Join-Path $projectRoot $OutputPath
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Default transcript paths
$transcriptDirs = @(
    (Join-Path $projectRoot "AitherZero/library/logs"),
    (Join-Path $projectRoot "AitherZero/logs"),
    (Join-Path $env:USERPROFILE "Documents/PowerShell/Transcripts")
)

if ($TranscriptPath) {
    $transcriptDirs = @($TranscriptPath)
}

# Create output directory
if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

# ============================================================================
# QUALITY SCORING
# ============================================================================
function Get-CommandQualityScore {
    param(
        [string]$Command,
        [string]$Output,
        [bool]$HasError
    )
    
    $score = 0.5  # Base score
    
    # High-value command patterns
    $highValuePatterns = @(
        @{ Pattern = 'git (commit|push|pull|merge|rebase)'; Boost = 0.2 }
        @{ Pattern = 'Invoke-(RestMethod|WebRequest)'; Boost = 0.2 }
        @{ Pattern = 'Start-(Process|Service|Job)'; Boost = 0.15 }
        @{ Pattern = 'docker|kubectl|helm'; Boost = 0.2 }
        @{ Pattern = 'python|pip|npm|pnpm'; Boost = 0.15 }
        @{ Pattern = 'ConvertTo-Json|ConvertFrom-Json'; Boost = 0.1 }
        @{ Pattern = 'Try|Catch|Finally'; Boost = 0.15 }
        @{ Pattern = 'ForEach-Object|Where-Object|Select-Object'; Boost = 0.1 }
        @{ Pattern = 'Import-Module|Install-Module'; Boost = 0.1 }
        @{ Pattern = 'Get-NetTCPConnection|Test-NetConnection'; Boost = 0.15 }
        @{ Pattern = 'AitherZero|Aither'; Boost = 0.1 }
    )
    
    foreach ($pattern in $highValuePatterns) {
        if ($Command -match $pattern.Pattern) {
            $score += $pattern.Boost
        }
    }
    
    # Output quality factors
    if ($Output.Length -gt 50 -and $Output.Length -lt 5000) {
        $score += 0.1  # Meaningful but not excessive output
    }
    
    # Error patterns - valuable for learning troubleshooting
    if ($HasError) {
        $score += 0.15  # Errors are learning opportunities
    }
    
    # Penalize very short/trivial commands
    if ($Command.Length -lt 10 -or $Command -match '^(cd|ls|dir|cls|clear)$') {
        $score -= 0.2
    }
    
    # Cap score
    return [Math]::Min([Math]::Max($score, 0.0), 1.0)
}

function Get-WorkflowType {
    param([string]$Command)
    
    switch -Regex ($Command) {
        'git' { return 'git_operations' }
        'docker|kubectl|helm' { return 'container_management' }
        'Start-(Process|Service)|Stop-' { return 'service_management' }
        'python|pip' { return 'python_development' }
        'Invoke-(RestMethod|WebRequest)|curl' { return 'api_interaction' }
        'Get-|Set-|New-|Remove-' { return 'powershell_cmdlet' }
        'AitherZero|Aither' { return 'aitherzero_automation' }
        default { return 'general' }
    }
}

# ============================================================================
# TRANSCRIPT PARSING
# ============================================================================
function Parse-TranscriptFile {
    param(
        [string]$FilePath,
        [datetime]$CutoffDate
    )
    
    $content = Get-Content $FilePath -Raw -ErrorAction Stop
    $examples = @()
    
    # Parse transcript header for metadata
    $metadata = @{
        timestamp = $null
        username = $null
        machine = $null
        psversion = $null
    }
    
    if ($content -match 'Start time: (\d{14})') {
        $metadata.timestamp = [datetime]::ParseExact($matches[1], 'yyyyMMddHHmmss', $null)
        if ($metadata.timestamp -lt $CutoffDate) {
            return @()  # Skip old transcripts
        }
    }
    
    if ($content -match 'Username: (.+)') { $metadata.username = $matches[1].Trim() }
    if ($content -match 'Machine: (.+)') { $metadata.machine = $matches[1].Trim() }
    if ($content -match 'PSVersion: (.+)') { $metadata.psversion = $matches[1].Trim() }
    
    # Split into command blocks
    # Pattern: "Command start time:" followed by "PS>" then the command
    $commandBlocks = [regex]::Matches($content, 
        'Command start time: (\d+)\s*\*+\s*PS[^>]*>\s*(.+?)(?=\*+\s*(?:Command start time|PowerShell transcript))', 
        'Singleline')
    
    foreach ($block in $commandBlocks) {
        $commandTime = $block.Groups[1].Value
        $blockContent = $block.Groups[2].Value
        
        # Clean up escape codes (VS Code terminal sequences)
        $blockContent = $blockContent -replace '\]633;[^]]*\]', ''
        $blockContent = $blockContent -replace '\x1b\[[0-9;]*m', ''
        
        # Split command from output
        $lines = $blockContent -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        
        if ($lines.Count -eq 0) { continue }
        
        $command = $lines[0]
        $output = ($lines | Select-Object -Skip 1) -join "`n"
        
        # Skip trivial commands
        if ($command.Length -lt 5) { continue }
        if ($command -match '^#') { continue }  # Comments
        if ($command -match '^\s*$') { continue }
        
        # Detect errors
        $hasError = $output -match '(Error|Exception|Failed|Cannot|not found|denied)' -or
                   $output -match 'TerminatingError'
        
        $qualityScore = Get-CommandQualityScore -Command $command -Output $output -HasError $hasError
        
        if ($qualityScore -ge $MinQuality) {
            $examples += @{
                id = "ps_$(Get-Random -Maximum 999999)"
                command = $command
                output = $output.Substring(0, [Math]::Min($output.Length, 4000))
                has_error = $hasError
                quality_score = [Math]::Round($qualityScore, 2)
                workflow_type = Get-WorkflowType -Command $command
                timestamp = $commandTime
                metadata = $metadata
                source_file = Split-Path $FilePath -Leaf
            }
        }
    }
    
    return $examples
}

# ============================================================================
# TRAINING DATA GENERATION
# ============================================================================
function Convert-ToSFTExample {
    param([hashtable]$Example)
    
    $instruction = switch ($Example.workflow_type) {
        'git_operations' { "Execute this Git command and explain the output:" }
        'service_management' { "Run this service management command:" }
        'api_interaction' { "Make this API request:" }
        'python_development' { "Execute this Python-related command:" }
        'aitherzero_automation' { "Run this AitherZero automation:" }
        default { "Execute this PowerShell command:" }
    }
    
    if ($Example.has_error) {
        $instruction = "Troubleshoot this command (it produced an error):"
    }
    
    return @{
        instruction = $instruction
        input = $Example.command
        output = if ($Example.output.Length -gt 0) { $Example.output } else { "[Command completed successfully with no output]" }
        quality = $Example.quality_score
        workflow = $Example.workflow_type
        source = "powershell_transcript"
        timestamp = $Example.timestamp
    }
}

function Convert-ToCoTExample {
    param([hashtable[]]$Examples)
    
    # Group consecutive commands that form a workflow
    $workflows = @()
    $currentWorkflow = @()
    $currentType = $null
    
    foreach ($ex in $Examples) {
        if ($currentType -eq $null -or $ex.workflow_type -eq $currentType) {
            $currentWorkflow += $ex
            $currentType = $ex.workflow_type
        } else {
            if ($currentWorkflow.Count -ge 2) {
                $workflows += ,@($currentWorkflow)
            }
            $currentWorkflow = @($ex)
            $currentType = $ex.workflow_type
        }
    }
    
    if ($currentWorkflow.Count -ge 2) {
        $workflows += ,@($currentWorkflow)
    }
    
    $cotExamples = @()
    foreach ($wf in $workflows) {
        $steps = $wf | ForEach-Object { 
            "Step: $($_.command)`nResult: $($_.output.Substring(0, [Math]::Min($_.output.Length, 500)))"
        }
        
        $cotExamples += @{
            task = "Complete this $($wf[0].workflow_type) workflow"
            reasoning = $steps -join "`n---`n"
            conclusion = "Workflow completed with $($wf.Count) steps"
            quality = ($wf | Measure-Object -Property quality_score -Average).Average
            source = "powershell_transcript_cot"
        }
    }
    
    return $cotExamples
}

# ============================================================================
# MAIN PROCESSING
# ============================================================================
$allExamples = @()
$processedFiles = 0

foreach ($dir in $transcriptDirs) {
    if (-not (Test-Path $dir)) {
        if ($ShowOutput) { Write-Host "  ⚠ Directory not found: $dir" -ForegroundColor Yellow }
        continue
    }
    
    if ($ShowOutput) { Write-Host "📂 Processing: $dir" -ForegroundColor Cyan }
    
    $transcripts = Get-ChildItem -Path $dir -Filter "*.log" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'transcript' -and $_.LastWriteTime -gt $cutoffDate }
    
    foreach ($transcript in $transcripts) {
        try {
            $examples = Parse-TranscriptFile -FilePath $transcript.FullName -CutoffDate $cutoffDate
            $allExamples += $examples
            $processedFiles++
            
            if ($ShowOutput -and $examples.Count -gt 0) {
                Write-Host "  ✓ $($transcript.Name): $($examples.Count) examples" -ForegroundColor Green
            }
        }
        catch {
            if ($ShowOutput) { Write-Host "  ✗ $($transcript.Name): $_" -ForegroundColor Red }
        }
    }
}

if ($ShowOutput) {
    Write-Host "`n📊 Total examples extracted: $($allExamples.Count) from $processedFiles files" -ForegroundColor Magenta
}

# ============================================================================
# OUTPUT GENERATION
# ============================================================================
if ($allExamples.Count -gt 0) {
    # Generate SFT examples
    $sftExamples = $allExamples | ForEach-Object { Convert-ToSFTExample $_ }
    $sftFile = Join-Path $outputDir "sft_powershell_${timestamp}.jsonl"
    $sftExamples | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $sftFile
    
    if ($ShowOutput) {
        Write-Host "`n💾 Saved: $sftFile" -ForegroundColor Green
        Write-Host "   SFT examples: $($sftExamples.Count)" -ForegroundColor Gray
    }
    
    # Generate CoT examples (multi-step workflows)
    $cotExamples = Convert-ToCoTExample -Examples $allExamples
    if ($cotExamples.Count -gt 0) {
        $cotFile = Join-Path $outputDir "cot_powershell_${timestamp}.jsonl"
        $cotExamples | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $cotFile
        
        if ($ShowOutput) {
            Write-Host "💾 Saved: $cotFile" -ForegroundColor Green
            Write-Host "   CoT examples: $($cotExamples.Count)" -ForegroundColor Gray
        }
    }
    
    # Generate error examples for DPO (learning from mistakes)
    $errorExamples = $allExamples | Where-Object { $_.has_error }
    if ($errorExamples.Count -gt 0) {
        $errorFile = Join-Path $outputDir "errors_powershell_${timestamp}.jsonl"
        $errorExamples | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } | Set-Content $errorFile
        
        if ($ShowOutput) {
            Write-Host "💾 Saved: $errorFile" -ForegroundColor Green
            Write-Host "   Error examples: $($errorExamples.Count)" -ForegroundColor Gray
        }
    }
    
    # Save raw examples for inspection
    $rawFile = Join-Path $outputDir "raw_transcript_${timestamp}.json"
    @{
        metadata = @{
            generated_at = Get-Date -Format "o"
            days_back = $DaysBack
            min_quality = $MinQuality
            files_processed = $processedFiles
            total_examples = $allExamples.Count
        }
        examples = $allExamples | Select-Object -First 100  # Sample for inspection
    } | ConvertTo-Json -Depth 10 | Set-Content $rawFile
}

# ============================================================================
# SUMMARY
# ============================================================================
$summary = @{
    files_processed = $processedFiles
    total_examples = $allExamples.Count
    sft_examples = $sftExamples.Count
    cot_examples = $cotExamples.Count
    error_examples = $errorExamples.Count
    avg_quality = if ($allExamples.Count -gt 0) { 
        [Math]::Round(($allExamples | Measure-Object -Property quality_score -Average).Average, 2) 
    } else { 0 }
}

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║          TRANSCRIPT PARSING COMPLETE                          ║" -ForegroundColor Magenta
Write-Host "╠═══════════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "║  Files Processed:   $($summary.files_processed.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║  Total Examples:    $($summary.total_examples.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║  SFT Examples:      $($summary.sft_examples.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║  CoT Workflows:     $($summary.cot_examples.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║  Error Examples:    $($summary.error_examples.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║  Avg Quality:       $($summary.avg_quality.ToString().PadLeft(6))" -ForegroundColor Magenta
Write-Host "║                                                               ║" -ForegroundColor Magenta
Write-Host "║  Output: $OutputPath" -ForegroundColor Magenta
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

Write-ScriptLog -Message "Transcript parsing complete. Examples: $($summary.total_examples), Avg Quality: $($summary.avg_quality)" -Level Information -Component $scriptName

exit 0
