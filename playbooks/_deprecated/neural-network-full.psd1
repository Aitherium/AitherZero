@{
    Name = "neural-network-full"
    Description = "Start the COMPLETE Aither Neural Network - all 21 services in correct order"
    Version = "1.0.0"
    Author = "AitherZero"
    
    Parameters = @{
        SkipOllama = $false
        SkipComfyUI = $false
        HealthCheck = $true
    }
    
    Sequence = @(
        # ═══════════════════════════════════════════════════════════════════════
        # PHASE 0: CREATIVE INFRASTRUCTURE (ComfyUI for AitherCanvas)
        # ═══════════════════════════════════════════════════════════════════════
        @{
            Name = "Start ComfyUI"
            Script = "0734_Start-ComfyUI"
            Description = "Start ComfyUI backend for AitherCanvas (port 8188)"
            ContinueOnError = $true
        },
        
        # ═══════════════════════════════════════════════════════════════════════
        # PHASE 1: CORE INFRASTRUCTURE
        # ═══════════════════════════════════════════════════════════════════════
        @{
            Name = "Start Ollama"
            Script = "0737_Start-Ollama"
            Description = "Start Ollama LLM backend (port 11434)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherNode MCP"
            Script = "0762_Start-AitherNode"
            Description = "Start MCP server (port 8080)"
            ContinueOnError = $false
        },
        
        # ═══════════════════════════════════════════════════════════════════════
        # PHASE 2: MONITORING LAYER  
        # Note: AitherPulse (0530) is a PowerShell metrics loop, started separately
        # ═══════════════════════════════════════════════════════════════════════
        @{
            Name = "Start AitherWatch"
            Script = "0768_Start-AitherWatch"
            Description = "Start watchdog service (port 8082)"
            ContinueOnError = $true
        },
        
        # ═══════════════════════════════════════════════════════════════════════
        # PHASE 3: PERCEPTION LAYER
        # ═══════════════════════════════════════════════════════════════════════
        @{
            Name = "Start AitherVoice"
            Script = "0769_Start-AitherVoice"
            Description = "Start voice service (port 8083)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherVision"
            Script = "0770_Start-AitherVision"
            Description = "Start vision service (port 8084)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherPortal"
            Script = "0771_Start-AitherPortal"
            Description = "Start portal service (port 8085)"
            ContinueOnError = $true
        },
        
        # ═══════════════════════════════════════════════════════════════════════
        # PHASE 4: INTELLIGENCE LAYER
        # ═══════════════════════════════════════════════════════════════════════
        @{
            Name = "Start AitherReflex"
            Script = "0772_Start-AitherReflex"
            Description = "Start reflex service (port 8086)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherMind"
            Script = "0773_Start-AitherMind"
            Description = "Start mind/embedding service (port 8088)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherJudge"
            Script = "0774_Start-AitherJudge"
            Description = "Start judge service (port 8089)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherFlow"
            Script = "0775_Start-AitherFlow"
            Description = "Start flow orchestration (port 8090)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherTag"
            Script = "0763_Start-AitherTag"
            Description = "Start tagging service (port 8092)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherReasoning"
            Script = "0777_Start-AitherReasoning"
            Description = "Start reasoning engine (port 8093)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherEnviro"
            Script = "0765_Start-AitherEnviro"
            Description = "Start environment service (port 8094)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherWorkingMemory"
            Script = "0776_Start-AitherWorkingMemory"
            Description = "Start fast memory cache (port 8095)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherChain"
            Script = "0766_Start-AitherChain"
            Description = "Start chain/audit service (port 8099)"
            ContinueOnError = $true
        },
        
        # ═══════════════════════════════════════════════════════════════════════
        # PHASE 5: CONTROL LAYER (Nervous System)
        # ═══════════════════════════════════════════════════════════════════════
        @{
            Name = "Start AitherGate"
            Script = "0778_Start-AitherGate"
            Description = "Start gating service (port 8100)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherAutonomic"
            Script = "0767_Start-AitherAutonomic"
            Description = "Start autonomic service (port 8101)"
            ContinueOnError = $true
        },
        @{
            Name = "Start AitherAccel"
            Script = "0764_Start-AitherAccel"
            Description = "Start GPU acceleration (port 8103)"
            ContinueOnError = $true
        },
        
        # ═══════════════════════════════════════════════════════════════════════
        # PHASE 6: VERIFICATION
        # ═══════════════════════════════════════════════════════════════════════
        @{
            Name = "Verify All Services"
            Script = "0803_Get-AitherStatus"
            Description = "Check status of all services"
            ContinueOnError = $true
        }
    )
    
    OnSuccess = @{
        Message = "🧠 Neural Network fully online! All 21 services started."
    }
    
    OnFailure = @{
        Message = "⚠️ Some services failed to start. Check logs for details."
    }
}
