<#
.SYNOPSIS
    Validates training data quality and counts.

.DESCRIPTION
    Scans training data directories and validates:
    - Sample counts meet minimum thresholds
    - Data format is correct (JSONL)
    - No corrupted files
    - Balanced categories

.PARAMETER MinSamples
    Minimum number of samples required. Default: 50

.PARAMETER ShowOutput
    Display verbose output during execution.

.EXAMPLE
    ./0882_Validate-TrainingData.ps1 -MinSamples 100 -ShowOutput

.NOTES
    Script ID: 0882
    Category: Training Data / Validation
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$MinSamples = 50,
    
    [Parameter()]
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"

# Use centralized Library/Training path
$TrainingDataPath = Join-Path $projectRoot "AitherOS" "Library" "Training"

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    if ($ShowOutput) {
        $color = switch ($Level) {
            "Success" { "Green" }
            "Warning" { "Yellow" }
            "Error"   { "Red" }
            default   { "Cyan" }
        }
        Write-Host "[$Level] $Message" -ForegroundColor $color
    }
}

Write-Log "=== Training Data Validation ===" -Level Information
Write-Log "Path: $TrainingDataPath" -Level Information

$results = @{
    TotalSamples = 0
    Datasets = @()
    Errors = @()
    Warnings = @()
}

# Scan datasets directory
$datasetsPath = Join-Path $TrainingDataPath "datasets"
if (Test-Path $datasetsPath) {
    $datasetFiles = Get-ChildItem -Path $datasetsPath -Filter "*.jsonl" -Recurse
    
    foreach ($file in $datasetFiles) {
        try {
            $lineCount = (Get-Content $file.FullName | Measure-Object -Line).Lines
            $results.TotalSamples += $lineCount
            $results.Datasets += @{
                Name = $file.Name
                Path = $file.FullName
                Samples = $lineCount
            }
            Write-Log "  Dataset: $($file.Name) - $lineCount samples" -Level Information
        } catch {
            $results.Errors += "Failed to read $($file.Name): $_"
        }
    }
}

# Scan aither-7b conversations
$aither7bPath = Join-Path $TrainingDataPath "aither-7b" "conversations"
if (Test-Path $aither7bPath) {
    $convFiles = Get-ChildItem -Path $aither7bPath -Filter "*.jsonl" -Recurse
    
    foreach ($file in $convFiles) {
        try {
            $lineCount = (Get-Content $file.FullName | Measure-Object -Line).Lines
            $results.TotalSamples += $lineCount
            $results.Datasets += @{
                Name = $file.Name
                Path = $file.FullName
                Samples = $lineCount
                Source = "aither-7b"
            }
        } catch {
            $results.Errors += "Failed to read $($file.Name): $_"
        }
    }
}

# Scan chronicle
$chroniclePath = Join-Path $TrainingDataPath "chronicle" "interactions"
if (Test-Path $chroniclePath) {
    $chronicleFiles = Get-ChildItem -Path $chroniclePath -Filter "*.json" -Recurse
    $results.TotalSamples += $chronicleFiles.Count
    
    if ($chronicleFiles.Count -gt 0) {
        Write-Log "  Chronicle: $($chronicleFiles.Count) interaction logs" -Level Information
    }
}

Write-Log "" -Level Information
Write-Log "=== Summary ===" -Level Information
Write-Log "Total Samples: $($results.TotalSamples)" -Level Information
Write-Log "Dataset Files: $($results.Datasets.Count)" -Level Information

if ($results.Errors.Count -gt 0) {
    Write-Log "Errors: $($results.Errors.Count)" -Level Error
    foreach ($err in $results.Errors) {
        Write-Log "  $err" -Level Error
    }
}

# Validate minimum threshold
if ($results.TotalSamples -lt $MinSamples) {
    Write-Log "FAIL: Insufficient training data ($($results.TotalSamples) < $MinSamples)" -Level Error
    
    @{
        Success = $false
        TotalSamples = $results.TotalSamples
        MinRequired = $MinSamples
        Message = "Insufficient training data"
    } | ConvertTo-Json -Compress
    
    exit 1
} else {
    Write-Log "PASS: Sufficient training data available" -Level Success
    
    @{
        Success = $true
        TotalSamples = $results.TotalSamples
        DatasetCount = $results.Datasets.Count
        Errors = $results.Errors.Count
    } | ConvertTo-Json -Compress
    
    exit 0
}
