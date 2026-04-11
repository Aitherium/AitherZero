@{
    Name        = "partner-deploy"
    Description = "Pull-only AitherOS deployment for partners — pre-built compiled images from GHCR, zero source code"
    Version     = "1.0.0"
    Author      = "AitherZero"
    
    # ═══════════════════════════════════════════════════════════════════════════
    # PARTNER DEPLOYMENT PLAYBOOK
    # ═══════════════════════════════════════════════════════════════════════════
    #
    # THE ONLY COMMAND YOUR PARTNER NEEDS:
    #   ./Deploy-Partner.ps1
    #   OR: Invoke-AitherPlaybook partner-deploy
    #
    # This playbook handles EVERYTHING for partner deployments:
    # ✓ Detects partner's hardware (GPU, CPU, RAM)
    # ✓ Installs Docker if missing
    # ✓ PULLS pre-built compiled images from GHCR (NO source code)
    # ✓ Auto-selects GPU profile based on detected VRAM
    # ✓ Downloads AI models appropriate for the hardware
    # ✓ Starts all services with health validation
    # ✓ Opens the dashboard when ready
    #
    # CRITICAL DIFFERENCES FROM deploy-aitheros:
    #   1. Mode is ALWAYS "pull" — no source code, no building
    #   2. Uses docker-compose.partner.yml (no build blocks, no source mounts)
    #   3. Images are Nuitka-compiled (.so) — no readable Python
    #   4. GPU profile auto-selected from hardware_profiles.yaml
    #
    # ═══════════════════════════════════════════════════════════════════════════
    
    Parameters = @{
        # Service profile: minimal | core | full
        Profile          = '$env:AITHEROS_PROFILE ?? "core"'
        
        # GHCR registry settings
        Registry         = '$env:AITHEROS_REGISTRY ?? "ghcr.io/aitherium"'
        ImageTag          = '$env:AITHEROS_IMAGE_TAG ?? "dist-latest"'
        
        # GPU profile override (auto-detected if not set)
        GpuProfile       = '$env:AITHEROS_GPU_PROFILE ?? ""'
        
        # Dependency installation
        InstallDeps      = $true
        
        # Model provisioning
        ProvisionModels  = '$env:AITHEROS_SKIP_MODELS -ne "1"'
        
        # Post-deploy
        HealthCheck      = $true
        OpenDashboard    = '$env:CI -ne "true"'
        
        # Options
        Force            = $false
        DryRun           = $false
        NonInteractive   = '$env:AITHEROS_NONINTERACTIVE -eq "1" -or $env:CI -eq "true"'
    }
    
    Prerequisites = @(
        "PowerShell 7+ (auto-installed by bootstrap.ps1)"
        "Internet connection (for Docker image pulls and model downloads)"
        "20GB+ free disk space"
        "Windows 10/11, Ubuntu 20.04+, macOS 11+"
        "NVIDIA GPU with CUDA drivers (recommended, not required)"
    )
    
    Sequence = @(
        # ============================================================
        # PHASE 1: SYSTEM DETECTION
        # ============================================================
        
        @{
            Name            = "System Detection"
            Script          = "0011_Get-SystemInfo"
            Description     = "Detect platform, hardware, GPU, available resources"
            Parameters      = @{}
            ContinueOnError = $true
        }
        
        @{
            Name            = "Validate Environment"
            Script          = "0005_Validate-Environment"
            Description     = "Verify minimum system requirements"
            Parameters      = @{}
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 2: DEPENDENCY INSTALLATION
        # ============================================================
        
        @{
            Name            = "Install Dependencies"
            Script          = "30-deploy/3021_Install-Dependencies"
            Description     = "Auto-detect and install Docker, NVIDIA Container Toolkit"
            Condition       = '$InstallDeps -eq $true'
            Parameters      = @{
                NonInteractive = '$NonInteractive'
                Force          = '$Force'
                SkipvLLM       = $false
                SkipGPU        = $false
            }
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 3: PARTNER DEPLOYMENT (pull + configure + start)
        # ============================================================
        
        @{
            Name            = "Deploy Partner System"
            Script          = "30-deploy/3030_Deploy-Partner"
            Description     = "Pull compiled images, auto-configure GPU, start services"
            Parameters      = @{
                Profile        = '$Profile'
                Registry       = '$Registry'
                ImageTag       = '$ImageTag'
                GpuProfile     = '$GpuProfile'
                Force          = '$Force'
                DryRun         = '$DryRun'
                NonInteractive = '$NonInteractive'
            }
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 4: AI MODEL PROVISIONING
        # ============================================================
        
        @{
            Name            = "Provision AI Models"
            Script          = "30-deploy/3022_Provision-Models"
            Description     = "Download AI models appropriate for detected hardware"
            Condition       = '$ProvisionModels -eq $true'
            Parameters      = @{
                Profile        = '$Profile'
                NonInteractive = '$NonInteractive'
                Force          = '$Force'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 5: HEALTH VALIDATION
        # ============================================================
        
        @{
            Name            = "Health Check"
            Script          = "0803_Get-AitherStatus"
            Description     = "Verify all deployed services are healthy"
            Condition       = '$HealthCheck -eq $true'
            Parameters      = @{}
            ContinueOnError = $true
        }
    )
    
    OnSuccess = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║          🚀 AITHEROS PARTNER DEPLOYMENT COMPLETE 🚀               ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  ACCESS POINTS:                                                   ║
║  ┌─────────────────────────────────────────────────────────────┐  ║
║  │  Dashboard:     http://localhost:3000                       │  ║
║  │  Genesis API:   http://localhost:8001                       │  ║
║  │  API Docs:      http://localhost:8001/docs                  │  ║
║  └─────────────────────────────────────────────────────────────┘  ║
║                                                                   ║
║  MANAGEMENT COMMANDS:                                             ║
║  ┌─────────────────────────────────────────────────────────────┐  ║
║  │  Status:   docker ps --filter name=aither                  │  ║
║  │  Logs:     docker compose -f docker-compose.partner.yml    │  ║
║  │            logs -f [service]                               │  ║
║  │  Stop:     docker compose -f docker-compose.partner.yml    │  ║
║  │            down                                            │  ║
║  │  Restart:  docker compose -f docker-compose.partner.yml    │  ║
║  │            restart [service]                               │  ║
║  └─────────────────────────────────────────────────────────────┘  ║
║                                                                   ║
║  GPU PROFILE:                                                     ║
║    Auto-detected from your hardware. To switch:                   ║
║    ./AitherZero/.../0908_Switch-GpuProfile.ps1 -Profile balanced  ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    }
    
    OnFailure = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════════╗
║          ⚠️ PARTNER DEPLOYMENT ENCOUNTERED ERRORS ⚠️              ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  Check output above for specific errors.                          ║
║                                                                   ║
║  COMMON FIXES:                                                    ║
║  ┌─────────────────────────────────────────────────────────────┐  ║
║  │  Docker not running:                                       │  ║
║  │    → Start Docker Desktop, then retry                      │  ║
║  │                                                            │  ║
║  │  Image pull failed:                                        │  ║
║  │    → Check internet connection                             │  ║
║  │    → Verify GHCR access (gh auth login)                    │  ║
║  │                                                            │  ║
║  │  GPU not detected:                                         │  ║
║  │    → Install NVIDIA drivers                                │  ║
║  │    → Install NVIDIA Container Toolkit                      │  ║
║  │    → Restart Docker Desktop                                │  ║
║  │                                                            │  ║
║  │  Disk space:                                               │  ║
║  │    → docker system prune -a  (removes unused images)       │  ║
║  │    → Need at least 20GB free                               │  ║
║  └─────────────────────────────────────────────────────────────┘  ║
║                                                                   ║
║  SUPPORT: aither@aitherium.com                                    ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    }
}
