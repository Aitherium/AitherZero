@{
    Name        = "deploy-aitheros"
    Description = "One-click AitherOS deployment — installs dependencies, builds containers, provisions models, starts services"
    Version     = "1.0.0"
    Author      = "AitherZero"
    
    # ═══════════════════════════════════════════════════════════════════════════
    # ONE-CLICK DEPLOYMENT PLAYBOOK
    # ═══════════════════════════════════════════════════════════════════════════
    #
    # THE ONLY COMMAND YOU NEED:
    #   ./Deploy-AitherOS.ps1
    #   OR: Invoke-AitherPlaybook deploy-aitheros
    #   OR: Invoke-AitherDeploy
    #
    # This playbook handles EVERYTHING:
    # ✓ Detects your platform (Windows/Linux/macOS)
    # ✓ Installs Docker, Git if missing
    # ✓ Builds all container images from source
    # ✓ Downloads AI models based on your hardware
    # ✓ Starts all services with health validation
    # ✓ Opens the dashboard when ready
    #
    # DEPLOYMENT MODES:
    #   Source (default): Builds from local source code
    #   Pull:            Downloads pre-built images from registry
    #   Hybrid:          Pulls base images, builds services locally
    #
    # CUSTOMIZATION:
    #   All behavior is driven by config.psd1 — override any setting via:
    #   - config.local.psd1 (gitignored, local overrides)
    #   - Environment variables (AITHEROS_*)
    #   - Playbook parameters (see below)
    #
    # ═══════════════════════════════════════════════════════════════════════════
    
    Parameters = @{
        # Deployment mode: source | pull | hybrid
        DeployMode       = 'source'
        
        # Service profile: minimal | core | full | headless | gpu | agents
        Profile          = '$env:AITHEROS_PROFILE ?? "core"'
        
        # Environment: development | production
        Environment      = '$env:AITHEROS_ENVIRONMENT ?? "development"'
        
        # Dependency installation
        InstallDeps      = $true
        SkipvLLM         = '$env:AITHEROS_SKIP_VLLM -eq "1"'
        SkipGPU          = $false
        
        # Build control
        BuildImages      = $true
        NoCacheBuild     = $false
        
        # Model provisioning
        ProvisionModels  = '$env:AITHEROS_SKIP_MODELS -ne "1"'
        DefaultModel     = '$env:AITHEROS_DEFAULT_MODEL ?? ""'
        
        # Post-deploy
        HealthCheck      = $true
        OpenDashboard    = '$env:CI -ne "true"'
        
        # Options
        Force            = $false
        NonInteractive   = '$env:AITHEROS_NONINTERACTIVE -eq "1" -or $env:CI -eq "true"'
    }
    
    Prerequisites = @(
        "PowerShell 7+ (auto-installed by Deploy-AitherOS.ps1)"
        "Internet connection (for Docker images and model downloads)"
        "10GB+ free disk space (minimal), 50GB+ recommended (full)"
        "Windows 10/11, Ubuntu 20.04+, macOS 11+"
    )
    
    Sequence = @(
        # ============================================================
        # PHASE 1: SYSTEM VALIDATION
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
            Description     = "Auto-detect and install Docker, Git"
            Condition       = '$InstallDeps -eq $true'
            Parameters      = @{
                NonInteractive = '$NonInteractive'
                Force          = '$Force'
                SkipvLLM       = '$SkipvLLM'
                SkipGPU        = '$SkipGPU'
            }
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 3: ENVIRONMENT SETUP
        # ============================================================
        
        @{
            Name            = "Setup Directories"
            Script          = "0002_Setup-Directories"
            Description     = "Create data, logs, cache directories"
            Parameters      = @{}
            ContinueOnError = $true
        }
        
        @{
            Name            = "Configure Environment"
            Script          = "0001_Configure-Environment"
            Description     = "Generate .env file and configure services"
            Parameters      = @{}
            ContinueOnError = $true
        }
        
        @{
            Name            = "Sync AitherOS Environment"
            Script          = "0020_Sync-AitherOSEnv"
            Description     = "Sync config.psd1 settings to .env for Docker Compose"
            Parameters      = @{}
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 4: BUILD CONTAINER IMAGES
        # ============================================================
        
        @{
            Name            = "Build Docker Images"
            Script          = "30-deploy/3020_Deploy-OneClick"
            Description     = "Build or pull all AitherOS Docker images"
            Condition       = '$BuildImages -eq $true'
            Parameters      = @{
                Mode            = '$DeployMode'
                Profile         = '$Profile'
                Environment     = '$Environment'
                Force           = '$NoCacheBuild'
                SkipDependencies = $true
                SkipModels       = $true
                SkipHealthCheck  = $true
                NonInteractive  = '$NonInteractive'
            }
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 5: AI MODEL PROVISIONING
        # ============================================================
        
        @{
            Name            = "Provision AI Models"
            Script          = "30-deploy/3022_Provision-Models"
            Description     = "Download and configure AI models for local inference"
            Condition       = '$ProvisionModels -eq $true'
            Parameters      = @{
                Profile        = '$Profile'
                NonInteractive = '$NonInteractive'
                Force          = '$Force'
                ModelOverride  = '$DefaultModel'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 6: SERVICE STARTUP
        # ============================================================
        
        @{
            Name            = "Start AitherOS Services"
            Script          = "40-lifecycle/4001_Start-Genesis"
            Description     = "Start all services via Docker Compose"
            Parameters      = @{
                Profile     = '$Profile'
                Environment = '$Environment'
                Build       = $false
                Wait        = $true
            }
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 7: HEALTH VALIDATION
        # ============================================================
        
        @{
            Name            = "Health Check"
            Script          = "0803_Get-AitherStatus"
            Description     = "Verify all deployed services are healthy"
            Condition       = '$HealthCheck -eq $true'
            Parameters      = @{}
            ContinueOnError = $true
        },
        
        # ============================================================
        # PHASE 8: POST-INSTALL PROVISIONING
        # ============================================================
        
        @{
            Name            = "Post-Install Provisioning"
            Script          = "30-deploy/3034_Post-Install"
            Description     = "Seed RBAC users/roles and ingest knowledge documents"
            Parameters      = @{}
            ContinueOnError = $true
        },
        
        # ============================================================
        # PHASE 9: EDGE / CLOUDFLARE HARDENING
        # ============================================================
        
        @{
            Name            = "Sync Cloudflare Tunnel Routes"
            Script          = "30-deploy/3040_Sync-CloudflareTunnel"
            Description     = "Push tunnel-routes.yaml to Cloudflare API"
            Condition       = 'Test-Path (Join-Path $ProjectRoot "AitherOS/config/tunnel-routes.yaml")'
            Parameters      = @{
                DryRun = '$DryRun'
            }
            ContinueOnError = $true
        },
        
        @{
            Name            = "Enforce Cloudflare SSL/TLS Hardening"
            Script          = "30-deploy/3042_Enforce-CloudflareSSL"
            Description     = "Enforce HSTS, Full(Strict) SSL, TLS 1.3, HTTPS — auto-remediates drift"
            Parameters      = @{}
            ContinueOnError = $true
        },
        
        @{
            Name            = "Cloudflare Tunnel Health Check"
            Script          = "30-deploy/3041_CloudflareTunnel-HealthCheck"
            Description     = "Verify all tunnel routes are live and healthy"
            Parameters      = @{
                ReportOnly = $true
            }
            ContinueOnError = $true
        }
    )
    
    OnSuccess = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║             🚀 AITHEROS DEPLOYED SUCCESSFULLY 🚀                  ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  ACCESS POINTS:                                                   ║
║  ┌─────────────────────────────────────────────────────────────┐  ║
║  │  Dashboard:     http://localhost:3000                       │  ║
║  │  Genesis API:   http://localhost:8001                       │  ║
║  │  API Docs:      http://localhost:8001/docs                  │  ║
║  │  BMC Status:    http://localhost:8001/bmc/status            │  ║
║  └─────────────────────────────────────────────────────────────┘  ║
║                                                                   ║
║  MANAGEMENT COMMANDS:                                             ║
║  ┌─────────────────────────────────────────────────────────────┐  ║
║  │  Status:    docker ps --filter name=aither                 │  ║
║  │  Logs:      docker compose -f docker-compose.aitheros.yml  │  ║
║  │             logs -f [service]                              │  ║
║  │  Stop:      ./Stop-AitherOS.ps1                            │  ║
║  │  Restart:   docker compose -f docker-compose.aitheros.yml  │  ║
║  │             restart [service]                              │  ║
║  └─────────────────────────────────────────────────────────────┘  ║
║                                                                   ║
║  NEXT STEPS:                                                      ║
║  1. Open http://localhost:3000 in your browser                    ║
║  2. Explore the Genesis API at http://localhost:8001/docs         ║
║  3. Chat with Aither at http://localhost:3000/chat                ║
║                                                                   ║
║  REDEPLOY ANYTIME:                                                ║
║    ./Deploy-AitherOS.ps1                                          ║
║    ./Deploy-AitherOS.ps1 -Profile full                            ║
║    ./Deploy-AitherOS.ps1 -Mode pull  (pre-built images)           ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    }
    
    OnFailure = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════════╗
║             ⚠️ DEPLOYMENT ENCOUNTERED ERRORS ⚠️                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  Check the output above for specific error messages.              ║
║                                                                   ║
║  COMMON FIXES:                                                    ║
║  ┌─────────────────────────────────────────────────────────────┐  ║
║  │  Docker not running:                                       │  ║
║  │    → Start Docker Desktop, then retry                      │  ║
║  │                                                            │  ║
║  │  Port conflicts:                                           │  ║
║  │    → docker compose -f docker-compose.aitheros.yml down    │  ║
║  │    → Then retry deployment                                 │  ║
║  │                                                            │  ║
║  │  Build failures:                                           │  ║
║  │    → ./Deploy-AitherOS.ps1 -Force  (clean rebuild)         │  ║
║  │                                                            │  ║
║  │  Disk space:                                               │  ║
║  │    → docker system prune -a  (removes unused images)       │  ║
║  │    → Need at least 10GB free                               │  ║
║  │                                                            │  ║
║  │  Model download failed:                                    │  ║
║  │    → ./Deploy-AitherOS.ps1 -SkipModels                     │  ║
║  │    → Models are provisioned via vLLM docker stack             │  ║
║  └─────────────────────────────────────────────────────────────┘  ║
║                                                                   ║
║  SUPPORT:                                                         ║
║    Docs:   ./docs/TROUBLESHOOTING.md                              ║
║    Issues: https://github.com/Aitherium/AitherZero/issues          ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    }
}
