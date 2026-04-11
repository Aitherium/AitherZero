# Nemotron Competition Training Playbook
# End-to-end: provision GPU -> train -> benchmark -> download -> cleanup
#
# Usage:
#   Invoke-AitherPlaybook -Name nemotron-training
#   Invoke-AitherPlaybook -Name nemotron-training -Variables @{ Epochs = 2; LearningRate = '5e-5'; GpuType = 'H100' }
#   Invoke-AitherPlaybook -Name nemotron-training -Variables @{ Profile = 'fast' }

@{
    Name        = 'nemotron-training'
    Description = 'Train Nemotron competition LoRA on cloud GPU via AitherComet, benchmark with vLLM, download results'
    Version     = '1.0.0'
    Author      = 'Aitherium'
    Tags        = @('training', 'nemotron', 'kaggle', 'competition', 'gpu', 'vast.ai')

    # =========================================================================
    # Profiles — pick a preset or override individual params
    # =========================================================================
    Profiles = @{
        default = @{
            Description = 'Run 2 proven config (A100 80GB, 2 epochs, packing)'
            Variables = @{
                GpuType        = 'A100_80GB'
                MinVramGB      = 80
                MaxPricePerHour = 4.00
                Epochs         = 2
                LearningRate   = '5e-5'
                BatchSize      = 4
                GradAccum      = 4
                MaxLength      = 2048
                Packing        = $true
                LoraAlpha      = 16
            }
        }
        fast = @{
            Description = 'H100 SXM with flash-attn for ~2x speed'
            Variables = @{
                GpuType        = 'H100_SXM'
                MinVramGB      = 80
                MaxPricePerHour = 6.00
                Epochs         = 2
                LearningRate   = '5e-5'
                BatchSize      = 8
                GradAccum      = 2
                MaxLength      = 2048
                Packing        = $true
                LoraAlpha      = 16
                FlashAttn      = $true
            }
        }
        experimental = @{
            Description = 'Run 3 experimental: early stopping, expanded data'
            Variables = @{
                GpuType        = 'H100_SXM'
                MinVramGB      = 80
                MaxPricePerHour = 6.00
                Epochs         = 3
                LearningRate   = '3e-5'
                BatchSize      = 4
                GradAccum      = 4
                MaxLength      = 2048
                Packing        = $true
                LoraAlpha      = 16
                EarlyStopPatience = 3
                CheckpointEval = $true
            }
        }
        run3 = @{
            Description = 'Run 3: <think> data, early stopping, multi-seed'
            Variables = @{
                GpuType        = 'H100_SXM'
                MinVramGB      = 80
                MaxPricePerHour = 6.00
                Epochs         = 3
                LearningRate   = '3e-5'
                BatchSize      = 4
                GradAccum      = 4
                MaxLength      = 2048
                Packing        = $true
                LoraAlpha      = 16
                FlashAttn      = $true
                EarlyStopPatience = 3
                CheckpointEval = $true
                ValidationSplit = 0.05
            }
        }
    }

    DefaultProfile = 'default'

    # =========================================================================
    # Parameters
    # =========================================================================
    Parameters = @{
        Profile = @{
            Type        = 'string'
            Description = 'Training profile (default, fast, experimental, run3)'
            Required    = $false
            Default     = 'default'
            ValidateSet = @('default', 'fast', 'experimental', 'run3')
        }
        DatasetPath = @{
            Type        = 'string'
            Description = 'Path to training JSONL (uses latest competition corpus if not set)'
            Required    = $false
        }
        RunId = @{
            Type        = 'string'
            Description = 'Run identifier (auto-generated if not set)'
            Required    = $false
        }
        SkipBenchmark = @{
            Type        = 'bool'
            Description = 'Skip post-training benchmark'
            Required    = $false
            Default     = $false
        }
        KeepInstance = @{
            Type        = 'bool'
            Description = 'Keep GPU instance alive after completion (for debugging)'
            Required    = $false
            Default     = $false
        }
    }

    # =========================================================================
    # Variables (merged with profile + user overrides)
    # =========================================================================
    Variables = @{
        BaseModel      = 'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16'
        LoraRank       = 32
        LoraDropout    = 0.05
        WarmupRatio    = 0.15
        LrScheduler    = 'cosine'
        SaveSteps      = 200
        TargetModules  = '.*\.(in_proj|out_proj|q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)$'
        GpuBlacklist   = 'B200,B100'
        MinDiskGB      = 400
        GenesisUrl     = 'http://localhost:8001'
        CometUrl       = 'http://localhost:8126'
        AdapterBaseDir = 'AitherOS/Library/Training/adapters'
        RunsDir        = 'AitherOS/Library/Training/runs'
        ScriptsDir     = 'AitherOS/Library/Training/scripts'
    }

    # =========================================================================
    # Sequence
    # =========================================================================
    Sequence = @(
        # Phase 1: Generate run ID and prepare data
        @{
            Script      = 'Inline'
            Description = 'Initialize run and prepare training data'
            Phase       = 'prepare'
            InlineBlock = {
                param($Vars)
                $runId = if ($Vars.RunId) { $Vars.RunId } else { "nemotron_run_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
                $Vars.RunId = $runId
                Write-Host "Run ID: $runId"

                # Build training data if no path given
                if (-not $Vars.DatasetPath) {
                    $resp = Invoke-RestMethod -Uri "$($Vars.GenesisUrl)/training/pipeline/competition/prepare-data" -Method POST -ContentType 'application/json'
                    $Vars.DatasetPath = $resp.dataset_path
                    Write-Host "Prepared $($resp.total_examples) training examples"
                }
                return @{ RunId = $runId; DatasetPath = $Vars.DatasetPath }
            }
        }

        # Phase 2: Provision GPU via AitherComet
        @{
            Script      = 'Inline'
            Description = 'Provision cloud GPU via AitherComet'
            Phase       = 'provision'
            Timeout     = 600
            InlineBlock = {
                param($Vars)
                $body = @{
                    service_name     = "nemotron-training-$($Vars.RunId)"
                    target           = 'CLOUD_GPU'
                    template         = 'training'
                    gpu_spec         = @{
                        min_vram_gb    = $Vars.MinVramGB
                        gpu_preference = $Vars.GpuType
                        gpu_blacklist  = $Vars.GpuBlacklist
                    }
                    disk_gb          = $Vars.MinDiskGB
                    max_price_per_hour = $Vars.MaxPricePerHour
                    env_vars         = @{ BASE_MODEL = $Vars.BaseModel }
                } | ConvertTo-Json -Depth 5

                $deploy = Invoke-RestMethod -Uri "$($Vars.CometUrl)/deploy" -Method POST -Body $body -ContentType 'application/json'
                $Vars.InstanceId = $deploy.instance_id
                $Vars.SshHost    = $deploy.ssh_host
                $Vars.SshPort    = $deploy.ssh_port
                $Vars.DeployId   = $deploy.deployment_id
                Write-Host "Instance $($deploy.instance_id) at $($deploy.ssh_host):$($deploy.ssh_port)"
                return $deploy
            }
        }

        # Phase 3: Setup deps (mamba-ssm, causal-conv1d)
        @{
            Script      = 'Inline'
            Description = 'Install mamba-ssm and causal-conv1d on instance'
            Phase       = 'setup'
            Timeout     = 900
            InlineBlock = {
                param($Vars)
                $sshCmd = "ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -p $($Vars.SshPort) root@$($Vars.SshHost)"
                & bash -c "$sshCmd 'pip install mamba-ssm causal-conv1d --no-build-isolation 2>&1 | tail -5'"
            }
        }

        # Phase 4: Upload data + training script
        @{
            Script      = 'Inline'
            Description = 'Upload training data and script'
            Phase       = 'upload'
            Timeout     = 300
            InlineBlock = {
                param($Vars)
                $scpCmd = "scp -o StrictHostKeyChecking=no -P $($Vars.SshPort)"
                & bash -c "$scpCmd $($Vars.DatasetPath) root@$($Vars.SshHost):/workspace/training.jsonl"

                # Generate training script with current params
                $body = @{
                    base_model     = $Vars.BaseModel
                    lora_rank      = $Vars.LoraRank
                    lora_alpha     = $Vars.LoraAlpha
                    lora_dropout   = $Vars.LoraDropout
                    learning_rate  = $Vars.LearningRate
                    epochs         = $Vars.Epochs
                    batch_size     = $Vars.BatchSize
                    grad_accum     = $Vars.GradAccum
                    max_length     = $Vars.MaxLength
                    packing        = $Vars.Packing
                    warmup_ratio   = $Vars.WarmupRatio
                    lr_scheduler   = $Vars.LrScheduler
                    save_steps     = $Vars.SaveSteps
                    target_modules = $Vars.TargetModules
                    flash_attn     = ($Vars.FlashAttn -eq $true)
                } | ConvertTo-Json -Depth 3

                $resp = Invoke-RestMethod -Uri "$($Vars.GenesisUrl)/training/pipeline/competition/generate-script" -Method POST -Body $body -ContentType 'application/json'
                & bash -c "$scpCmd $($resp.script_path) root@$($Vars.SshHost):/workspace/train.py"
                Write-Host "Uploaded data + script"
            }
        }

        # Phase 5: Run training
        @{
            Script      = 'Inline'
            Description = 'Execute training on cloud GPU'
            Phase       = 'train'
            Timeout     = 259200  # 72h
            InlineBlock = {
                param($Vars)
                $sshCmd = "ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -p $($Vars.SshPort) root@$($Vars.SshHost)"

                # Start training
                & bash -c "$sshCmd 'nohup python3 /workspace/train.py > /workspace/train.log 2>&1 &'"
                Write-Host "Training started"

                # Poll until complete
                $maxWait = 259200  # 72h
                $interval = 60
                $elapsed = 0
                while ($elapsed -lt $maxWait) {
                    Start-Sleep -Seconds $interval
                    $elapsed += $interval
                    $status = & bash -c "$sshCmd 'cat /workspace/train_status.txt 2>/dev/null'" 2>$null
                    if ($status -match 'COMPLETED') {
                        Write-Host "Training completed: $status"
                        return @{ status = 'completed'; elapsed_hours = [math]::Round($elapsed / 3600, 1) }
                    }
                    if ($status -match 'FAILED') {
                        throw "Training failed: $status"
                    }
                    $progress = & bash -c "$sshCmd 'cat /workspace/train_progress.json 2>/dev/null'" 2>$null
                    if ($progress) {
                        $p = $progress | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($p) { Write-Host "Step $($p.step)/$($p.total_steps) loss=$($p.loss) epoch=$($p.epoch)" }
                    }
                }
                throw "Training timed out after ${maxWait}s"
            }
        }

        # Phase 6: Benchmark (optional)
        @{
            Script      = 'Inline'
            Description = 'Run vLLM benchmark on trained adapter'
            Phase       = 'benchmark'
            Timeout     = 7200
            Condition   = '{{SkipBenchmark}} -ne $true'
            InlineBlock = {
                param($Vars)
                $scpCmd = "scp -o StrictHostKeyChecking=no -P $($Vars.SshPort)"
                $sshCmd = "ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -p $($Vars.SshPort) root@$($Vars.SshHost)"

                & bash -c "$scpCmd $($Vars.ScriptsDir)/bench_vllm.py root@$($Vars.SshHost):/workspace/bench_vllm.py"
                $result = & bash -c "$sshCmd 'python3 /workspace/bench_vllm.py 2>&1'" 2>&1
                Write-Host $result
                return $result
            }
        }

        # Phase 7: Download results
        @{
            Script      = 'Inline'
            Description = 'Download adapter and benchmark results'
            Phase       = 'download'
            Timeout     = 1800
            InlineBlock = {
                param($Vars)
                $scpCmd = "scp -o StrictHostKeyChecking=no -P $($Vars.SshPort)"
                $outDir = "$($Vars.AdapterBaseDir)/$($Vars.RunId)"
                New-Item -ItemType Directory -Path $outDir -Force | Out-Null

                & bash -c "$scpCmd -r root@$($Vars.SshHost):/workspace/lora_output/final/* $outDir/"
                & bash -c "$scpCmd root@$($Vars.SshHost):/workspace/benchmark_results.json $($Vars.RunsDir)/$($Vars.RunId)_benchmark.json" 2>$null
                & bash -c "$scpCmd root@$($Vars.SshHost):/workspace/lora_output/checkpoint-*/trainer_state.json $outDir/trainer_state.json" 2>$null

                Write-Host "Downloaded adapter to $outDir"
                return @{ adapter_dir = $outDir }
            }
        }

        # Phase 8: Cleanup
        @{
            Script      = 'Inline'
            Description = 'Destroy cloud instance'
            Phase       = 'cleanup'
            Timeout     = 120
            Condition   = '{{KeepInstance}} -ne $true'
            ContinueOnError = $true
            InlineBlock = {
                param($Vars)
                Invoke-RestMethod -Uri "$($Vars.CometUrl)/deployments/$($Vars.DeployId)/destroy" -Method POST -ErrorAction SilentlyContinue
                Write-Host "Instance destroyed"
            }
        }
    )

    # =========================================================================
    # Error handling
    # =========================================================================
    OnError = @{
        Action         = 'Stop'
        RetryCount     = 0
        NotifyChannels = @('pulse')
        Cleanup        = {
            param($Vars)
            if ($Vars.DeployId) {
                Invoke-RestMethod -Uri "$($Vars.CometUrl)/deployments/$($Vars.DeployId)/destroy" -Method POST -ErrorAction SilentlyContinue
            }
        }
    }

    OnComplete = @{
        NotifyChannels = @('pulse')
    }

    Summary = @{
        SuccessMessage = @'
Training Run Complete!
  Run:       {{RunId}}
  Model:     {{BaseModel}}
  GPU:       {{GpuType}} ({{SshHost}}:{{SshPort}})
  Adapter:   {{AdapterBaseDir}}/{{RunId}}/
  Benchmark: {{RunsDir}}/{{RunId}}_benchmark.json
'@
    }
}
