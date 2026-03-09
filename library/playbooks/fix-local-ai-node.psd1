@{
    Name        = "fix-local-ai-node"
    Description = "Troubleshoots and fixes local AI node issues (CUDA, PyTorch, Drivers)"
    Version     = "1.0.0"
    Sequence    = @(
        # 1. Fix CUDA/PyTorch Mismatch
        @{
            Script = "0733"
            Params = @{
                ComfyPath   = "C:\ComfyUI"
                CudaVersion = "12.4" # Default to 12.4 for RTX 40/50 series
            }
        }
    )
}
