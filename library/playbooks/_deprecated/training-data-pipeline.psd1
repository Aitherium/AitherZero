@{
    Name = "training-data-pipeline"
    Description = "Full training pipeline: video extraction, data collection, and model training preparation"
    Version = "2.0.0"
    Author = "AitherZero"
    
    # Default parameters
    Parameters = @{
        DaysBack = 7
        IncludeTranscripts = $true
        IncludeBenchmarks = $true
        IncludeConversations = $true
        ShowOutput = $true
    }
    
    Steps = @(
        # ═══════════════════════════════════════════════════════════════════════════
        # Step 1: Ensure Training Services are Running
        # ═══════════════════════════════════════════════════════════════════════════
        @{
            Name = "Start AitherPrism"
            Script = "0780_Start-AitherPrism"
            Description = "Video extraction service for training data"
            Parameters = @{
                Background = $true
            }
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherTrainer"
            Script = "0779_Start-AitherTrainer"
            Description = "Model training service"
            Parameters = @{
                Background = $true
            }
            ContinueOnError = $true
        },
        
        # ═══════════════════════════════════════════════════════════════════════════
        # Step 2: GPU Services for Benchmarking and Training
        # ═══════════════════════════════════════════════════════════════════════════
        @{
            Name = "Run GPU Benchmarks"
            Script = "0764_Start-AitherAccel"
            Description = "Ensure GPU services are running for benchmarking"
            ContinueOnError = $true
        },
        
        # ═══════════════════════════════════════════════════════════════════════════
        # Step 3: Collect Training Data from Operations
        # ═══════════════════════════════════════════════════════════════════════════
        @{
            Name = "Collect Training Data"
            Script = "0880_Collect-TrainingData"
            Description = "Harvest transcripts, logs, benchmarks, and conversations"
            Parameters = @{
                DaysBack = '$DaysBack'
                IncludeTranscripts = '$IncludeTranscripts'
                IncludeBenchmarks = '$IncludeBenchmarks'
                IncludeConversations = '$IncludeConversations'
                ShowOutput = '$ShowOutput'
            }
            ContinueOnError = $false
        },
        
        # ═══════════════════════════════════════════════════════════════════════════
        # Step 4: Generate Summary Report
        # ═══════════════════════════════════════════════════════════════════════════
        @{
            Name = "Generate Report"
            Script = "0510_Generate-ProjectReport"
            Description = "Create project report with training data summary"
            Parameters = @{
                ShowAll = $true
            }
        }
    )
    
    OnSuccess = @{
        Message = @"
Training data pipeline complete!

Services Running:
  - AitherPrism (8096): Video frame extraction
  - AitherTrainer (8097): Model training management

Next Steps:
1. Extract frames from video: Use AitherPrism MCP tools or REST API
2. Review training data in AitherOS/training-data/
3. Start training run via AitherVeil Training widget
4. Monitor progress in dashboard
5. Deploy trained model to Ollama

Quick Commands:
  # Extract frames from video
  Invoke-RestMethod -Uri 'http://localhost:8096/extract' -Method POST -Body @{
    video_path = 'path/to/video.mp4'
    mode = 'keyframes'
    output_dir = 'training-data/datasets/my-dataset'
  } | ConvertTo-Json

  # List available datasets
  Invoke-RestMethod -Uri 'http://localhost:8097/datasets'
  
  # Start training run
  Invoke-RestMethod -Uri 'http://localhost:8097/runs' -Method POST -Body @{
    name = 'my-model-v1'
    base_model = 'mistral-nemo'
    epochs = 3
  } | ConvertTo-Json
"@
    }
    
    Metadata = @{
        Created = "2025-11-28"
        Updated = "2025-11-30"
        Tags = @("training", "data", "pipeline", "self-improvement", "video", "prism")
        EstimatedDuration = "5-30 minutes (depends on data volume)"
        RequiresGPU = $true
        Services = @("AitherPrism", "AitherTrainer", "AitherAccel")
    }
}
