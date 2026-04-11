<#
.SYNOPSIS
    Train a local LLM model using LoRA/QLoRA with Unsloth.

.DESCRIPTION
    This script trains a local language model using LoRA (Low-Rank Adaptation)
    or QLoRA (Quantized LoRA) techniques. It uses the Unsloth library for
    2x faster training on consumer GPUs.

    Supports:
    - Mistral 7B
    - Llama 3.1 8B
    - Qwen 2.5 7B/14B
    - Phi-3

.PARAMETER DataPath
    Path to the training data file (JSONL format).

.PARAMETER ModelName
    Base model to fine-tune. Default: mistralai/Mistral-7B-Instruct-v0.3

.PARAMETER OutputDir
    Directory to save the trained model. Default: AitherOS/Library/Models/loras

.PARAMETER Epochs
    Number of training epochs. Default: 3

.PARAMETER LearningRate
    Learning rate for training. Default: 2e-4

.PARAMETER LoraRank
    LoRA rank (lower = less params, faster). Default: 32

.PARAMETER BatchSize
    Training batch size. Default: 2

.PARAMETER GradientAccumulation
    Gradient accumulation steps. Default: 4

.PARAMETER MaxSeqLength
    Maximum sequence length. Default: 2048

.PARAMETER UseQLoRA
    Use 4-bit quantization (QLoRA). Requires less VRAM.

.PARAMETER ShowOutput
    Show detailed training output.

.EXAMPLE
    .\0850_Train-LocalModel.ps1 -DataPath "data/training.jsonl" -ShowOutput

.EXAMPLE
    .\0850_Train-LocalModel.ps1 -ModelName "unsloth/llama-3-8b-Instruct" -Epochs 5 -UseQLoRA

.NOTES
    Author: Aitherium
    Requires: Python 3.10+, CUDA GPU with 12GB+ VRAM
    Install: pip install unsloth transformers datasets peft
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$DataPath,

    [Parameter()]
    [string]$ModelName = "unsloth/mistral-7b-instruct-v0.3-bnb-4bit",

    [Parameter()]
    [string]$OutputDir,

    [Parameter()]
    [int]$Epochs = 3,

    [Parameter()]
    [double]$LearningRate = 2e-4,

    [Parameter()]
    [int]$LoraRank = 32,

    [Parameter()]
    [int]$BatchSize = 2,

    [Parameter()]
    [int]$GradientAccumulation = 4,

    [Parameter()]
    [int]$MaxSeqLength = 2048,

    [switch]$UseQLoRA,

    [switch]$ShowOutput
)

# Initialize
. "$PSScriptRoot/_init.ps1"

Write-ScriptLog "Starting local model training" -Level Information

# Validate environment
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-AitherError "Python not found. Please install Python 3.10+" -Throw
}

# Check CUDA
$cudaAvailable = python -c "import torch; print(torch.cuda.is_available())" 2>$null
if ($cudaAvailable -ne "True") {
    Write-Warning "CUDA not available. Training will be very slow on CPU."
}

# Set default paths
if (-not $OutputDir) {
    $OutputDir = Join-Path $projectRoot "AitherOS/Library/Models/loras"
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

if (-not $DataPath) {
    # Check for exported training data from AitherSpirit
    $spiritDataPath = Join-Path $projectRoot "AitherOS/AitherNode/data/spirit/training_export.jsonl"
    if (Test-Path $spiritDataPath) {
        $DataPath = $spiritDataPath
        Write-ScriptLog "Using AitherSpirit training data: $DataPath"
    } else {
        Write-AitherError "No training data specified. Use -DataPath or export from AitherSpirit" -Throw
    }
}

if (-not (Test-Path $DataPath)) {
    Write-AitherError "Training data not found: $DataPath" -Throw
}

# Count training samples
$sampleCount = (Get-Content $DataPath | Measure-Object -Line).Lines
Write-ScriptLog "Training samples: $sampleCount"

# Create training script
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$modelSlug = ($ModelName -split '/')[-1] -replace '[^a-zA-Z0-9]', '-'
$outputName = "aither-$modelSlug-$timestamp"
$outputPath = Join-Path $OutputDir $outputName

$trainScript = @"
#!/usr/bin/env python3
"""
AitherZero Local Model Training Script
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"""

import os
import json
from datetime import datetime

# Set environment variables before imports
os.environ["CUDA_VISIBLE_DEVICES"] = "0"

print("🧠 AitherZero Local Model Training")
print("=" * 50)

try:
    from unsloth import FastLanguageModel
    from unsloth import is_bfloat16_supported
    print("✅ Unsloth loaded successfully")
except ImportError:
    print("❌ Unsloth not installed. Run: pip install unsloth")
    exit(1)

from datasets import load_dataset
from trl import SFTTrainer
from transformers import TrainingArguments

# Configuration
MODEL_NAME = "$ModelName"
DATA_PATH = r"$DataPath"
OUTPUT_DIR = r"$outputPath"
MAX_SEQ_LENGTH = $MaxSeqLength
LORA_RANK = $LoraRank
EPOCHS = $Epochs
LEARNING_RATE = $LearningRate
BATCH_SIZE = $BatchSize
GRAD_ACCUM = $GradientAccumulation
USE_QLORA = $(if ($UseQLoRA) { "True" } else { "False" })

print(f"Model: {MODEL_NAME}")
print(f"Data: {DATA_PATH}")
print(f"Output: {OUTPUT_DIR}")
print(f"LoRA Rank: {LORA_RANK}")
print(f"Epochs: {EPOCHS}")
print(f"QLoRA: {USE_QLORA}")
print()

# Load model
print("📥 Loading base model...")
model, tokenizer = FastLanguageModel.from_pretrained(
    model_name=MODEL_NAME,
    max_seq_length=MAX_SEQ_LENGTH,
    dtype=None,  # Auto-detect
    load_in_4bit=USE_QLORA,
)

# Add LoRA adapters
print("🔧 Adding LoRA adapters...")
model = FastLanguageModel.get_peft_model(
    model,
    r=LORA_RANK,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                    "gate_proj", "up_proj", "down_proj"],
    lora_alpha=LORA_RANK,
    lora_dropout=0,
    bias="none",
    use_gradient_checkpointing="unsloth",
    random_state=42,
)

# Load dataset
print("📊 Loading training data...")

def load_jsonl_dataset(path):
    """Load JSONL dataset in chat format."""
    data = []
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            try:
                item = json.loads(line.strip())
                # Convert to chat format if needed
                if 'messages' in item:
                    # Already in chat format
                    data.append(item)
                elif 'instruction' in item and 'output' in item:
                    # Alpaca format
                    data.append({
                        'messages': [
                            {'role': 'user', 'content': item['instruction']},
                            {'role': 'assistant', 'content': item['output']}
                        ]
                    })
                elif 'prompt' in item and 'response' in item:
                    # Simple format
                    data.append({
                        'messages': [
                            {'role': 'user', 'content': item['prompt']},
                            {'role': 'assistant', 'content': item['response']}
                        ]
                    })
            except:
                continue
    return data

raw_data = load_jsonl_dataset(DATA_PATH)
print(f"Loaded {len(raw_data)} training samples")

# Format for training
def format_chat(example):
    """Format chat messages for training."""
    messages = example.get('messages', [])
    text = tokenizer.apply_chat_template(messages, tokenize=False)
    return {'text': text}

from datasets import Dataset
dataset = Dataset.from_list(raw_data)
dataset = dataset.map(format_chat)

print(f"Formatted dataset: {len(dataset)} samples")

# Training arguments
print("🏋️ Starting training...")
training_args = TrainingArguments(
    output_dir=OUTPUT_DIR,
    per_device_train_batch_size=BATCH_SIZE,
    gradient_accumulation_steps=GRAD_ACCUM,
    warmup_steps=10,
    num_train_epochs=EPOCHS,
    learning_rate=LEARNING_RATE,
    fp16=not is_bfloat16_supported(),
    bf16=is_bfloat16_supported(),
    logging_steps=10,
    save_strategy="epoch",
    optim="adamw_8bit",
    weight_decay=0.01,
    lr_scheduler_type="linear",
    seed=42,
)

trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=dataset,
    dataset_text_field="text",
    max_seq_length=MAX_SEQ_LENGTH,
    dataset_num_proc=2,
    packing=False,
    args=training_args,
)

# Train
train_result = trainer.train()

# Save model
print("💾 Saving model...")
model.save_pretrained(OUTPUT_DIR)
tokenizer.save_pretrained(OUTPUT_DIR)

# Save training metadata
metadata = {
    "base_model": MODEL_NAME,
    "trained_at": datetime.now().isoformat(),
    "epochs": EPOCHS,
    "samples": len(dataset),
    "lora_rank": LORA_RANK,
    "training_loss": train_result.training_loss,
}
with open(os.path.join(OUTPUT_DIR, "training_metadata.json"), 'w') as f:
    json.dump(metadata, f, indent=2)

print()
print("=" * 50)
print("✅ Training complete!")
print(f"📁 Model saved to: {OUTPUT_DIR}")
print(f"📉 Final loss: {train_result.training_loss:.4f}")
print()
print("To use the trained model:")
print(f'  model, tokenizer = FastLanguageModel.from_pretrained("{OUTPUT_DIR}")')
"@

# Save and run training script
$scriptPath = Join-Path $env:TEMP "aither_train_$timestamp.py"
$trainScript | Set-Content -Path $scriptPath -Encoding UTF8

Write-ScriptLog "Training script created: $scriptPath"
Write-ScriptLog "Starting training with configuration:"
Write-ScriptLog "  Model: $ModelName"
Write-ScriptLog "  Data: $DataPath ($sampleCount samples)"
Write-ScriptLog "  Output: $outputPath"
Write-ScriptLog "  LoRA Rank: $LoraRank"
Write-ScriptLog "  Epochs: $Epochs"
Write-ScriptLog "  QLoRA: $UseQLoRA"

# Run training
$pythonArgs = @($scriptPath)

try {
    if ($ShowOutput) {
        python @pythonArgs
    } else {
        $result = python @pythonArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-AitherError "Training failed: $result" -Throw
        }
    }
    
    Write-ScriptLog "Training completed successfully!" -Level Success
    Write-ScriptLog "Model saved to: $outputPath"
    
    # Return result
    @{
        Success = $true
        ModelPath = $outputPath
        Samples = $sampleCount
        Epochs = $Epochs
    }
}
catch {
    Write-AitherError "Training failed: $_" -Throw
}
finally {
    # Cleanup
    if (Test-Path $scriptPath) {
        Remove-Item $scriptPath -Force
    }
}
