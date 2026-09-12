@{
    Name        = "local-inference"
    Description = "Local models on this box: adk setup pulls weights and serves them (vLLM / Ollama / native llama.cpp), aither-kvcache compresses the KV cache, verify"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "onboarding"

    # ==========================================================================
    # LOCAL INFERENCE — models + KV cache
    # ==========================================================================
    #
    #   1. adk setup --tier <Tier> --non-interactive   pull weights, serve (skipped if UP)
    #   2. pip install aither-kvcache[<KvExtras>]       TurboQuant / TriAttention / KVTransfer
    #   3. verify                                        adk status shows a local backend UP
    #
    # USAGE:
    #   Invoke-AitherPlaybook local-inference                                  # auto tier from GPU
    #   Invoke-AitherPlaybook local-inference -Variables @{ Tier = 'llamacpp' } # laptop, no Docker
    #   Invoke-AitherPlaybook local-inference -Variables @{ Tier = 'full'; KvExtras = 'all' }
    #   Invoke-AitherPlaybook local-inference -DryRun
    #
    # First run downloads 16-30 GB (tier dependent). Never starts a second
    # vLLM next to a live one. Requires dev-workstation (adk on PATH).
    # ==========================================================================

    Parameters = @{
        # adk tier: auto | nano | lite | standard | standard-tq4 | full | hybrid | hybrid-tq4 | ollama | llamacpp
        Tier     = 'auto'

        # aither-kvcache extras: vllm | triton | transfer | all | ''
        KvExtras = 'vllm'

        # HuggingFace token for gated weights (leave empty for public models)
        HfToken  = ''
    }

    Prerequisites = @(
        "dev-workstation playbook (adk on PATH)"
        "GPU with 6 GB+ VRAM for vLLM tiers; any machine for llamacpp / ollama"
        "Docker for vLLM tiers (llamacpp tier needs none)"
        "16-30 GB free disk"
    )

    Sequence = @(
        @{
            Name            = "Models + backend"
            Script          = "32-onboarding/3221_Install-LocalModels"
            Description     = "adk setup --tier <Tier> --non-interactive (skipped if a local backend is already UP)"
            Parameters      = @{ Tier = '$Tier'; HfToken = '$HfToken' }
            ContinueOnError = $false
        }
        @{
            Name            = "aither-kvcache"
            Script          = "32-onboarding/3222_Install-KVCache"
            Description     = "pip install aither-kvcache[<KvExtras>]; import check"
            Parameters      = @{ Extras = '$KvExtras' }
            ContinueOnError = $false
        }
        @{
            Name            = "Verify"
            Script          = "32-onboarding/3217_Test-DevWorkstation"
            Description     = "adk status reports the backend"
            ContinueOnError = $false
        }
    )

    Options = @{ Parallel = $false; MaxConcurrency = 1; StopOnError = $true }

    OnSuccess = @{
        Message = @'

+=================================================================+
|   LOCAL INFERENCE READY                                          |
+=================================================================+
|  adk status            which backend is serving                  |
|  adk start             chat against it                           |
|  adk claude-model local   point Claude Code at it                |
|  aither-kvcache is installed; the vLLM plugin is active inside   |
|  the vLLM adk started (v0.15+).                                  |
+=================================================================+
'@
    }

    OnFailure = @{
        Message = @'

+=================================================================+
|   LOCAL INFERENCE FAILED                                         |
+=================================================================+
|  - OOM / second vLLM     -> adk status; stop the old one or use   |
|                             -Variables @{ Tier='llamacpp' }      |
|  - Docker missing        -> Tier='llamacpp' needs no Docker       |
|  - gated model           -> -Variables @{ HfToken='hf_...' }      |
|  - slow                  -> weights are 16-30 GB; re-run resumes  |
+=================================================================+
'@
    }
}
