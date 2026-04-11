<#
.SYNOPSIS
    Executes a training job via the AitherTrainer API.

.DESCRIPTION
    Submits a training job to the running AitherTrainer service and monitors progress.
    Supports LoRA, QLoRA, DPO, and full fine-tuning modes.

.PARAMETER TrainingType
    Type of training: lora, qlora, dpo, full

.PARAMETER BaseModel
    Base model to fine-tune (e.g., qwen2.5:7b, llama3:8b)

.PARAMETER DatasetId
    Specific dataset ID to use. If not specified, uses latest available.

.PARAMETER Epochs
    Number of training epochs. Default: 3

.PARAMETER BatchSize
    Training batch size. Default: 4

.PARAMETER LearningRate
    Learning rate. Default: 0.0001

.PARAMETER Wait
    Wait for training to complete (synchronous mode).

.PARAMETER ShowOutput
    Display verbose output during execution.

.EXAMPLE
    ./0782_Run-TrainingJob.ps1 -TrainingType lora -BaseModel "qwen2.5:7b" -ShowOutput

.NOTES
    Script ID: 0782
    Category: AI Services / Training
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("lora", "qlora", "dpo", "full")]
    [string]$TrainingType = "lora",
    
    [Parameter()]
    [string]$BaseModel = "qwen2.5:7b",
    
    [Parameter()]
    [string]$DatasetId,
    
    [Parameter()]
    [int]$Epochs = 3,
    
    [Parameter()]
    [int]$BatchSize = 4,
    
    [Parameter()]
    [double]$LearningRate = 0.0001,
    
    [Parameter()]
    [switch]$Wait,
    
    [Parameter()]
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"

$TrainerUrl = "http://localhost:8107"

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

# Check if trainer is running
try {
    $health = Invoke-RestMethod -Uri "$TrainerUrl/health" -TimeoutSec 5
    Write-Log "AitherTrainer is running (v$($health.version))" -Level Information
} catch {
    Write-Log "AitherTrainer is not running. Start it with: 0779_Start-AitherTrainer.ps1" -Level Error
    exit 1
}

# Build training config
$config = @{
    name = "training_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    base_model = $BaseModel
    training_type = $TrainingType
    epochs = $Epochs
    batch_size = $BatchSize
    learning_rate = $LearningRate
}

if ($DatasetId) {
    $config.dataset_id = $DatasetId
}

Write-Log "Starting training run..." -Level Information
Write-Log "  Type: $TrainingType" -Level Information
Write-Log "  Model: $BaseModel" -Level Information
Write-Log "  Epochs: $Epochs" -Level Information

try {
    # Submit training job
    $body = $config | ConvertTo-Json
    $response = Invoke-RestMethod -Uri "$TrainerUrl/runs" -Method Post -Body $body -ContentType "application/json"
    
    $runId = $response.id
    Write-Log "Training run started: $runId" -Level Success
    
    if ($Wait) {
        Write-Log "Monitoring progress..." -Level Information
        
        do {
            Start-Sleep -Seconds 5
            $status = Invoke-RestMethod -Uri "$TrainerUrl/runs/$runId" -TimeoutSec 10
            
            $progress = [math]::Round($status.progress, 1)
            Write-Log "  Progress: $progress% | Step: $($status.current_step)/$($status.total_steps) | Loss: $($status.loss)" -Level Information
            
        } while ($status.status -in @("pending", "preparing", "training"))
        
        if ($status.status -eq "completed") {
            Write-Log "Training completed successfully!" -Level Success
            Write-Log "  Checkpoint: $($status.checkpoint_path)" -Level Information
        } else {
            Write-Log "Training ended with status: $($status.status)" -Level Warning
            if ($status.error) {
                Write-Log "  Error: $($status.error)" -Level Error
            }
        }
    }
    
    # Output result
    @{
        Success = $true
        RunId = $runId
        Status = $response.status
        TrainerUrl = "$TrainerUrl/runs/$runId"
    } | ConvertTo-Json -Compress
    
} catch {
    Write-Log "Failed to start training: $_" -Level Error
    exit 1
}
