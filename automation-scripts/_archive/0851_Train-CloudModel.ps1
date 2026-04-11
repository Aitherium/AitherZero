<#
.SYNOPSIS
    Train a model using cloud infrastructure (Vertex AI, Lambda Labs, etc.).

.DESCRIPTION
    This script manages cloud-based model training using various providers:
    - Google Vertex AI (Gemini tuning)
    - Lambda Labs (A100/H100 rental)
    - RunPod (On-demand GPU)
    - Hugging Face AutoTrain

.PARAMETER Provider
    Cloud provider to use: vertex, lambda, runpod, autotrain

.PARAMETER DataPath
    Path to the training data file (JSONL format).

.PARAMETER ModelName
    Base model to fine-tune.

.PARAMETER OutputName
    Name for the fine-tuned model.

.PARAMETER Epochs
    Number of training epochs.

.PARAMETER ShowOutput
    Show detailed output.

.EXAMPLE
    .\0851_Train-CloudModel.ps1 -Provider vertex -DataPath "data/training.jsonl"

.EXAMPLE
    .\0851_Train-CloudModel.ps1 -Provider autotrain -ModelName "mistralai/Mistral-7B-v0.1"

.NOTES
    Author: Aitherium
    Requires: Cloud provider credentials configured
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("vertex", "lambda", "runpod", "autotrain")]
    [string]$Provider,

    [Parameter()]
    [string]$DataPath,

    [Parameter()]
    [string]$ModelName,

    [Parameter()]
    [string]$OutputName,

    [Parameter()]
    [int]$Epochs = 3,

    [switch]$ShowOutput
)

# Initialize
. "$PSScriptRoot/_init.ps1"

Write-ScriptLog "Starting cloud model training with $Provider" -Level Information

# Validate data path
if (-not $DataPath) {
    $spiritDataPath = Join-Path $projectRoot "AitherOS/AitherNode/data/spirit/training_export.jsonl"
    if (Test-Path $spiritDataPath) {
        $DataPath = $spiritDataPath
    } else {
        Write-AitherError "No training data specified" -Throw
    }
}

if (-not (Test-Path $DataPath)) {
    Write-AitherError "Training data not found: $DataPath" -Throw
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not $OutputName) {
    $OutputName = "aither-tuned-$timestamp"
}

switch ($Provider) {
    "vertex" {
        Write-ScriptLog "Using Google Vertex AI for Gemini tuning"
        
        # Check for Google Cloud SDK
        if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
            Write-AitherError "Google Cloud SDK not installed. Run: 0212_Install-GCloudCLI.ps1" -Throw
        }
        
        # Check authentication
        $account = gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>$null
        if (-not $account) {
            Write-AitherError "Not authenticated to Google Cloud. Run: gcloud auth login" -Throw
        }
        Write-ScriptLog "Authenticated as: $account"
        
        # Upload training data to GCS
        $project = gcloud config get-value project 2>$null
        $bucket = "gs://$project-aither-training"
        $gcsDataPath = "$bucket/data/$OutputName.jsonl"
        
        Write-ScriptLog "Uploading training data to GCS..."
        gsutil cp $DataPath $gcsDataPath
        
        # Create tuning job
        $tuningConfig = @{
            displayName = $OutputName
            baseModel = if ($ModelName) { $ModelName } else { "gemini-1.5-flash-002" }
            tunedModelDisplayName = $OutputName
            supervisedTuningSpec = @{
                trainingDatasetUri = $gcsDataPath
                hyperParameters = @{
                    epochCount = $Epochs
                    learningRateMultiplier = 1.0
                }
            }
        } | ConvertTo-Json -Depth 10
        
        $configPath = Join-Path $env:TEMP "tuning_config_$timestamp.json"
        $tuningConfig | Set-Content -Path $configPath
        
        Write-ScriptLog "Starting Vertex AI tuning job..."
        $result = gcloud ai tuning-jobs create --region=us-central1 --config=$configPath 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-ScriptLog "Tuning job created successfully" -Level Success
            Write-ScriptLog "Monitor at: https://console.cloud.google.com/vertex-ai/tuning"
        } else {
            Write-AitherError "Failed to create tuning job: $result" -Throw
        }
        
        Remove-Item $configPath -Force
    }
    
    "lambda" {
        Write-ScriptLog "Using Lambda Labs for GPU training"
        
        $lambdaKey = $env:LAMBDA_API_KEY
        if (-not $lambdaKey) {
            Write-AitherError "LAMBDA_API_KEY not set. Get one at https://cloud.lambdalabs.com" -Throw
        }
        
        # List available instances
        Write-ScriptLog "Checking available GPU instances..."
        $headers = @{ "Authorization" = "Bearer $lambdaKey" }
        
        $instances = Invoke-RestMethod -Uri "https://cloud.lambdalabs.com/api/v1/instance-types" -Headers $headers
        
        # Prefer A100 or H100
        $preferred = $instances.data | Where-Object { 
            $_.name -match "A100|H100" -and $_.regions_with_capacity_available.Count -gt 0 
        } | Select-Object -First 1
        
        if (-not $preferred) {
            Write-Warning "No A100/H100 available. Checking for other GPUs..."
            $preferred = $instances.data | Where-Object { 
                $_.regions_with_capacity_available.Count -gt 0 
            } | Select-Object -First 1
        }
        
        if (-not $preferred) {
            Write-AitherError "No GPU instances available. Try again later." -Throw
        }
        
        Write-ScriptLog "Found available instance: $($preferred.name) at $($preferred.price_cents_per_hour/100)/hr"
        Write-ScriptLog "To launch, use Lambda Labs console or API"
        
        # Create training script to run on Lambda
        $trainScript = @"
#!/bin/bash
# AitherZero Cloud Training Script
# Run this on your Lambda Labs instance

# Install dependencies
pip install unsloth transformers datasets peft trl

# Download training data
# TODO: Add your data download command here

# Run training
python -c "
from unsloth import FastLanguageModel
# ... training code here
"
"@
        
        $scriptPath = Join-Path $projectRoot "tmp/lambda_train_$timestamp.sh"
        $trainScript | Set-Content -Path $scriptPath
        
        Write-ScriptLog "Training script created: $scriptPath"
        Write-ScriptLog "Upload to Lambda instance and run with: bash $scriptPath"
    }
    
    "runpod" {
        Write-ScriptLog "Using RunPod for GPU training"
        
        $runpodKey = $env:RUNPOD_API_KEY
        if (-not $runpodKey) {
            Write-AitherError "RUNPOD_API_KEY not set. Get one at https://runpod.io" -Throw
        }
        
        Write-ScriptLog "RunPod integration requires manual setup"
        Write-ScriptLog "1. Go to https://runpod.io/console/pods"
        Write-ScriptLog "2. Create a pod with unsloth template"
        Write-ScriptLog "3. Upload training data and run 0850_Train-LocalModel.ps1"
    }
    
    "autotrain" {
        Write-ScriptLog "Using Hugging Face AutoTrain"
        
        $hfToken = $env:HF_TOKEN
        if (-not $hfToken) {
            Write-AitherError "HF_TOKEN not set. Get one at https://huggingface.co/settings/tokens" -Throw
        }
        
        # Install autotrain
        Write-ScriptLog "Installing autotrain..."
        pip install autotrain-advanced 2>&1 | Out-Null
        
        $baseModel = if ($ModelName) { $ModelName } else { "mistralai/Mistral-7B-Instruct-v0.3" }
        
        Write-ScriptLog "Starting AutoTrain..."
        $autotrainArgs = @(
            "llm",
            "--train",
            "--model", $baseModel,
            "--data-path", $DataPath,
            "--project-name", $OutputName,
            "--lr", "2e-4",
            "--epochs", $Epochs,
            "--batch-size", "2",
            "--gradient-accumulation", "4",
            "--peft",
            "--quantization", "int4",
            "--push-to-hub",
            "--token", $hfToken
        )
        
        if ($ShowOutput) {
            autotrain @autotrainArgs
        } else {
            $result = autotrain @autotrainArgs 2>&1
        }
        
        if ($LASTEXITCODE -eq 0) {
            Write-ScriptLog "AutoTrain job started successfully" -Level Success
            Write-ScriptLog "Model will be pushed to: huggingface.co/$OutputName"
        } else {
            Write-AitherError "AutoTrain failed" -Throw
        }
    }
}

Write-ScriptLog "Cloud training workflow completed" -Level Success

@{
    Success = $true
    Provider = $Provider
    OutputName = $OutputName
}
