<#
.SYNOPSIS
    Export training data from AitherSpirit for model fine-tuning.

.DESCRIPTION
    This script exports conversation logs, teachings, and insights from
    AitherSpirit into JSONL format suitable for LLM fine-tuning.

    The export includes:
    - High-quality conversations (based on quality scoring)
    - User-approved teachings
    - Agent-discovered insights
    - Codebase-specific knowledge

.PARAMETER OutputPath
    Path for the output JSONL file.

.PARAMETER MinQuality
    Minimum quality score to include (0.0-1.0). Default: 0.7

.PARAMETER IncludeTeachings
    Include explicit teachings from users.

.PARAMETER IncludeInsights
    Include agent-discovered insights.

.PARAMETER IncludeConversations
    Include logged conversations.

.PARAMETER MaxSamples
    Maximum number of samples to export.

.PARAMETER UseJudge
    Filter through AitherJudge for quality control.

.PARAMETER ShowOutput
    Show detailed export progress.

.EXAMPLE
    .\0852_Export-TrainingData.ps1 -ShowOutput

.EXAMPLE
    .\0852_Export-TrainingData.ps1 -MinQuality 0.8 -UseJudge

.NOTES
    Author: Aitherium
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [double]$MinQuality = 0.7,

    [switch]$IncludeTeachings = $true,

    [switch]$IncludeInsights = $true,

    [switch]$IncludeConversations = $true,

    [Parameter()]
    [int]$MaxSamples = 10000,

    [switch]$UseJudge,

    [switch]$ShowOutput
)

# Initialize
. "$PSScriptRoot/_init.ps1"

Write-ScriptLog "Exporting training data from AitherSpirit" -Level Information

# Set default output path
if (-not $OutputPath) {
    $OutputPath = Join-Path $projectRoot "AitherOS/AitherNode/data/spirit/training_export.jsonl"
}

# Ensure output directory exists
$outputDir = Split-Path $OutputPath -Parent
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Data sources
$spiritDir = Join-Path $projectRoot "AitherOS/AitherNode/data/spirit"
$teachingsFile = Join-Path $spiritDir "teachings.json"
$insightsFile = Join-Path $spiritDir "insights.json"
$conversationsFile = Join-Path $spiritDir "conversations.jsonl"

$exportedSamples = @()
$stats = @{
    teachings = 0
    insights = 0
    conversations = 0
    rejected = 0
}

# Export teachings
if ($IncludeTeachings -and (Test-Path $teachingsFile)) {
    Write-ScriptLog "Processing teachings..."
    $teachings = Get-Content $teachingsFile -Raw | ConvertFrom-Json
    
    foreach ($teaching in $teachings) {
        if ($exportedSamples.Count -ge $MaxSamples) { break }
        
        # Convert to training format
        $sample = @{
            messages = @(
                @{ role = "system"; content = "You are Aither, an AI assistant with deep knowledge of the AitherZero codebase and automation workflows." },
                @{ role = "user"; content = "Remember this: $($teaching.content)" },
                @{ role = "assistant"; content = "I've learned and will remember: $($teaching.content). This knowledge about '$($teaching.tags -join ', ')' will help me assist better in the future." }
            )
            metadata = @{
                source = "teaching"
                strength = $teaching.strength
                created_at = $teaching.created_at
                tags = $teaching.tags
            }
        }
        
        $exportedSamples += $sample
        $stats.teachings++
    }
}

# Export insights
if ($IncludeInsights -and (Test-Path $insightsFile)) {
    Write-ScriptLog "Processing insights..."
    $insights = Get-Content $insightsFile -Raw | ConvertFrom-Json
    
    foreach ($insight in $insights) {
        if ($exportedSamples.Count -ge $MaxSamples) { break }
        if ($insight.strength -lt $MinQuality) { 
            $stats.rejected++
            continue 
        }
        
        $sample = @{
            messages = @(
                @{ role = "system"; content = "You are Aither, an AI assistant that learns from patterns in codebases and workflows." },
                @{ role = "user"; content = "What have you learned about $($insight.context)?" },
                @{ role = "assistant"; content = $insight.content }
            )
            metadata = @{
                source = "insight"
                strength = $insight.strength
                discovered_at = $insight.created_at
            }
        }
        
        $exportedSamples += $sample
        $stats.insights++
    }
}

# Export conversations
if ($IncludeConversations -and (Test-Path $conversationsFile)) {
    Write-ScriptLog "Processing conversations..."
    
    Get-Content $conversationsFile | ForEach-Object {
        if ($exportedSamples.Count -ge $MaxSamples) { return }
        
        try {
            $conv = $_ | ConvertFrom-Json
            
            # Check quality score
            if ($conv.quality_score -lt $MinQuality) {
                $stats.rejected++
                return
            }
            
            $sample = @{
                messages = $conv.messages
                metadata = @{
                    source = "conversation"
                    quality_score = $conv.quality_score
                    agent = $conv.agent
                    timestamp = $conv.timestamp
                }
            }
            
            $exportedSamples += $sample
            $stats.conversations++
        }
        catch {
            # Skip malformed entries
        }
    }
}

# Apply AitherJudge filtering if requested
if ($UseJudge) {
    Write-ScriptLog "Filtering through AitherJudge..."
    
    $judgeUrl = "http://localhost:8089/evaluate"
    $approved = @()
    
    foreach ($sample in $exportedSamples) {
        try {
            $content = ($sample.messages | ForEach-Object { $_.content }) -join "`n"
            
            $body = @{
                content = $content
                content_type = "conversation"
                min_quality = $MinQuality
            } | ConvertTo-Json
            
            $response = Invoke-RestMethod -Uri $judgeUrl -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
            
            if ($response.verdict -eq "approved") {
                $approved += $sample
            } else {
                $stats.rejected++
            }
        }
        catch {
            # If judge not available, include the sample
            $approved += $sample
        }
    }
    
    $exportedSamples = $approved
}

# Write output
Write-ScriptLog "Writing $($exportedSamples.Count) samples to $OutputPath"

$exportedSamples | ForEach-Object {
    $_ | ConvertTo-Json -Compress -Depth 10
} | Set-Content -Path $OutputPath -Encoding UTF8

# Summary
Write-ScriptLog "Export complete:" -Level Success
Write-ScriptLog "  Teachings: $($stats.teachings)"
Write-ScriptLog "  Insights: $($stats.insights)"
Write-ScriptLog "  Conversations: $($stats.conversations)"
Write-ScriptLog "  Rejected: $($stats.rejected)"
Write-ScriptLog "  Total exported: $($exportedSamples.Count)"
Write-ScriptLog "  Output: $OutputPath"

@{
    Success = $true
    OutputPath = $OutputPath
    SampleCount = $exportedSamples.Count
    Stats = $stats
}
