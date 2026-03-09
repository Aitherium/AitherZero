@{
    Name = "genesis-bootstrap"
    Description = "Complete AitherOS Genesis bootstrap - installs all dependencies and starts the bootloader"
    Version = "1.0.0"
    Author = "AitherZero"
    
    # ═══════════════════════════════════════════════════════════════════════════
    # IDEMPOTENT BOOTSTRAP - Run this as many times as you need!
    # ═══════════════════════════════════════════════════════════════════════════
    #
    # THIS IS THE ONLY COMMAND YOU NEED TO REMEMBER:
    #   ./bootstrap.ps1 -Playbook genesis-bootstrap
    #   OR: Invoke-AitherPlaybook genesis-bootstrap
    #
    # This command handles EVERYTHING:
    # ✓ Fresh install (first time)
    # ✓ Upgrade/update (existing install)
    # ✓ Repair (broken state)
    # ✓ Restart (after crash)
    #
    # DEBUG MODE:
    #   $env:GENESIS_DEBUG_MODE = "1"
    #   ./bootstrap.ps1 -Playbook genesis-bootstrap
    #   → Genesis starts but does NOT auto-boot services
    #   → Start services one at a time via Dashboard or API
    #   → See docs/GENESIS_DEBUG_MODE.md for details
    #
    # ═══════════════════════════════════════════════════════════════════════════
    
    # Bootstrap Chain:
    #   1. bootstrap.ps1 → PowerShell 7, Git (already handled)
    #   2. genesis-bootstrap.psd1 → Python, Node, Ollama, NSSM, dependencies
    #   3. Genesis BMC → Boots all AitherOS services
    #
    # Usage:
    #   ./bootstrap.ps1 -Playbook genesis-bootstrap
    #   ./bootstrap.ps1 -Playbook genesis-bootstrap -PlaybookParams @{ Full = $true }
    
    Parameters = @{
        # Core dependencies (required)
        InstallPython = $true
        InstallNode = $true
        InstallNSSM = $true          # Windows service manager
        InstallDocker = $true         # Docker for container orchestration
        InstallCosign = $true         # Cosign for container image signing
        
        # AI/ML dependencies
        # Can be disabled via: AITHEROS_SKIP_OLLAMA=1
        InstallOllama = '$env:AITHEROS_SKIP_OLLAMA -ne "1"'
        InstallComfyUI = $false       # Heavy, optional
        PullModels = '$env:AITHEROS_SKIP_OLLAMA -ne "1"'
        
        # Aither custom model - creates aither-orchestrator-8b-v4 and sets as default
        SetupAitherModel = '$env:AITHEROS_SKIP_OLLAMA -ne "1"'

        # Qwen3-Coder-Next - 80B MoE model for Level 7+ agentic tasks
        # Can be disabled via: AITHEROS_SKIP_QWEN3=1
        SetupQwen3Coder = '$env:AITHEROS_SKIP_OLLAMA -ne "1" -and $env:AITHEROS_SKIP_QWEN3 -ne "1"'
        
        # AitherOS setup
        SetupAitherNode = $true
        SetupDirectories = $true
        # Can be disabled via: AITHEROS_SKIP_VEIL=1
        SetupVeil = '$env:AITHEROS_SKIP_VEIL -ne "1"'
        # Web developer toolkit for Aither's website (Neocities + Tunnel)
        # Can be disabled via: AITHEROS_SKIP_WEBDEV=1
        SetupWebDeveloper = '$env:AITHEROS_SKIP_WEBDEV -ne "1"'
        
        # Genesis control
        StartGenesis = $true
        
        # Install Genesis as persistent system service (auto-start on boot)
        # This is the KEY for "leave and come back to running AitherOS"
        InstallGenesisService = $true
        # Can be enabled via: GENESIS_AUTO_BOOT=1
        BootOS = '$env:GENESIS_AUTO_BOOT -eq "1"'
        # Profile from env var: AITHEROS_PROFILE (default: core)
        Profile = '$env:AITHEROS_PROFILE ?? "core"'
        
        # Options
        SkipInstalled = $true
        Force = $false
        
        # CI/Non-interactive mode
        # Set via: AITHEROS_NONINTERACTIVE=1 or AITHERZERO_NONINTERACTIVE=1
        NonInteractive = '$env:AITHEROS_NONINTERACTIVE -eq "1" -or $env:AITHERZERO_NONINTERACTIVE -eq "1" -or $env:CI -eq "true"'
    }
    
    Prerequisites = @(
        "PowerShell 7+ (installed by bootstrap.ps1)"
        "Git (installed by bootstrap.ps1)"
        "Windows 10/11, macOS, or Linux"
        "Internet connection"
        "20GB+ free disk space"
    )
    
    Sequence = @(
        # ============================================================
        # PHASE 1: SYSTEM INFO & VALIDATION
        # ============================================================
        
        @{
            Name = "Gather System Information"
            Script = "0011_Get-SystemInfo"
            Description = "Check system compatibility and resources"
            Parameters = @{
                }
            ContinueOnError = $true
        }
        
        @{
            Name = "Validate Environment"
            Script = "0005_Validate-Environment"
            Description = "Ensure all prerequisites are met"
            Parameters = @{
                }
            ContinueOnError = $true
        }
        
        @{
            Name = "Sync AitherOS Environment"
            Script = "0020_Sync-AitherOSEnv"
            Description = "Sync AitherZero config to AitherOS environment variables"
            Parameters = @{
                }
            ContinueOnError = $true
        }

        @{
            Name = "Install Sysinternals"
            Script = "0019_Install-Sysinternals"
            Description = "Download and install Microsoft Sysinternals Suite"
            Parameters = @{
                }
            ContinueOnError = $true
        }

        # ============================================================
        # PHASE 2: CORE RUNTIME DEPENDENCIES
        # ============================================================
        
        @{
            Name = "Install Python 3.11+"
            Script = "0206_Install-Python"
            Description = "Install Python runtime for AitherOS services"
            Condition = '$InstallPython -eq $true'
            Parameters = @{
                }
            ContinueOnError = $false
        }
        
        @{
            Name = "Install Node.js 20+"
            Script = "0201_Install-Node"
            Description = "Install Node.js for AitherVeil and AitherTrainer"
            Condition = '$InstallNode -eq $true'
            Parameters = @{
                }
            ContinueOnError = $false
        }
        
        @{
            Name = "Install Docker Desktop"
            Script = "0208_Install-Docker"
            Description = "Install Docker for container-based service orchestration (auto orphan cleanup)"
            Condition = '$InstallDocker -eq $true'
            Parameters = @{
                }
            ContinueOnError = $true
        }

        @{
            Name = "Build AitherOS Docker Images"
            Script = "0820_Build-AitherOSDocker"
            Description = "Build all AitherOS service images (base + 131+ services)"
            Condition = '$InstallDocker -eq $true'  # defaulted from InstallDocker for now, could be separate param
            Parameters = @{
                Profile = "all"
                NoCache = $false
            }
            ContinueOnError = $true
        }

        @{
            Name = "Install Cosign"
            Script = "1021_Install-Cosign"
            Description = "Install Cosign for container image signing integration"
            Condition = '$InstallCosign -eq $true'
            Parameters = @{
                Force = '$Force'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 3: SERVICE MANAGEMENT (Windows)
        # ============================================================
        
        @{
            Name = "Install Servy Service Manager"
            Script = "0226_Install-Servy"
            Description = "Install Servy for Windows service management (NSSM alternative)"
            Condition = '$IsWindows -and $InstallNSSM -eq $true'
            Parameters = @{
                }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 4: AI/ML DEPENDENCIES
        # ============================================================
        
        @{
            Name = "Install Ollama"
            Script = "0740_Install-Ollama"
            Description = "Install Ollama for local LLM inference"
            Condition = '$InstallOllama -eq $true'
            Parameters = @{
                }
            ContinueOnError = $true
        }
        
        @{
            Name = "Optimize Ollama Configuration"
            Script = "0021_Optimize-Ollama"
            Description = "Configure Ollama for optimal performance"
            Condition = '$InstallOllama -eq $true'
            Parameters = @{
                }
            ContinueOnError = $true
        }
        
        # NOTE: Ollama is started/managed by Genesis via AitherOracle wrapper
        # (removed 0737_Start-Ollama step)
        
        @{
            Name = "Pull Default Ollama Models"
            Script = "0741_Setup-LocalLLM"
            Description = "Pull required Ollama models for AitherOS"
            Condition = '$InstallOllama -eq $true -and $PullModels -eq $true'
            Parameters = @{
                }
            ContinueOnError = $true
        }
        
        @{
            Name = "Setup Base NVIDIA Orchestrator Model"
            Script = "0758_Setup-Orchestrator8B"
            Description = "Download and register NVIDIA Orchestrator-8B (base model)"
            Condition = '$InstallOllama -eq $true -and $PullModels -eq $true'
            Parameters = @{
                Quantization = 'Q6_K'
                }
            ContinueOnError = $true  # May already exist or user may want different model
        }
        
        @{
            Name = "Setup Aither Custom Orchestrator Model"
            Script = "0759_Setup-AitherOrchestratorModel"
            Description = "Create aither-orchestrator-v5 (Nemotron-based) with AitherOS customizations"
            Condition = '$InstallOllama -eq $true'
            Parameters = @{
                ModelVersion = 'v5'
                SetDefault = $true
                }
            ContinueOnError = $true  # Optional but recommended
        }

        @{
            Name = "Setup Qwen3-Coder-Next Agentic Model"
            Script = "0760_Setup-Qwen3CoderNext"
            Description = "Download and setup Qwen3-Coder-Next-80B for Level 7+ agentic coding tasks"
            Condition = '$InstallOllama -eq $true -and $env:AITHEROS_SKIP_QWEN3 -ne "1"'
            Parameters = @{
                Quantization = 'Q5_K_M'
                }
            ContinueOnError = $true  # Large model, optional for basic setups
        }
        
        # NOTE: Nemotron-Elastic models are built during Genesis boot from GGUF Modelfiles
        # in AitherGenesis/modelfiles/ (removed 0742_Setup-NemotronElastic step)
        
        @{
            Name = "Install ComfyUI"
            Script = "0730_Install-ComfyUI"
            Description = "Install ComfyUI for image generation"
            Condition = '$InstallComfyUI -eq $true'
            Parameters = @{
                }
            ContinueOnError = $true
        }

        @{
            Name = "Provision ComfyUI Models"
            Script = "0851_Setup-ComfyUIModels"
            Description = "Download required LoRAs (technical diagrams, schematics, flat illustration) from CivitAI"
            Condition = '$true'  # Always run — idempotent, skips existing models
            Parameters = @{
                SkipCheckpoints = $true  # Checkpoints are large, handled separately
            }
            ContinueOnError = $true  # Non-critical — image gen works without LoRAs
        }
        
        # ============================================================
        # PHASE 5: AITHEROS SETUP
        # ============================================================
        
        @{
            Name = "Setup Directory Structure"
            Script = "0002_Setup-Directories"
            Description = "Create required AitherOS directories"
            Condition = '$SetupDirectories -eq $true'
            Parameters = @{
                }
            ContinueOnError = $false
        }
        
        @{
            Name = "Configure Environment"
            Script = "0001_Configure-Environment"
            Description = "Set environment variables and create .env files"
            Parameters = @{
                }
            ContinueOnError = $false
        }
        
        @{
            Name = "Setup AitherNode"
            Script = "0761_Setup-AitherNode"
            Description = "Install Python dependencies for AitherNode services"
            Condition = '$SetupAitherNode -eq $true'
            Parameters = @{
                }
            ContinueOnError = $false
        }

        @{
            Name = "Build AitherZero MCP Server"
            Script = "0762_Build-AitherZeroMCP"
            Description = "Build AitherZero MCP TypeScript server (npm install && npm run build)"
            Parameters = @{
                }
            ContinueOnError = $true  # MCP server is optional but provides PowerShell tools for agents
        }

        @{
            Name = "Setup Web Developer Toolkit"
            Script = "0769_Setup-WebDeveloperToolkit"
            Description = "Configure Neocities deployment tools and Cloudflare Tunnel for Aither's website"
            Condition = '$SetupWebDeveloper -eq $true'
            Parameters = @{
                SkipCloudflared = $false
                }
            ContinueOnError = $true  # Optional but enables Aither's website capabilities
        }

        # ============================================================
        # PHASE 6: WINDOWS SERVICE INSTALL + GENESIS BOOTLOADER
        # ============================================================
        # IMPORTANT:
        # - Installing services is handled by the Genesis installer scripts under AitherOS/AitherGenesis.
        # - 0800_Manage-Genesis -Action Reinitialize is SAFE: it reinstalls AitherGenesis only.
        
        @{
            Name = "Setup AitherOS Virtual Environment"
            Script = "0720_Setup-AitherOSVenv"
            Description = "Create centralized Python venv for all AitherOS services"
            Parameters = @{
            }
            ContinueOnError = $false
        }

        @{
            Name = "Reinitialize Genesis (Idempotent)"
            Script = "0800_Manage-Genesis"
            Description = "Safe reinstall Genesis (AitherGenesis only) - reinstalls bootloader and opens dashboard when ready"
            Condition = '$InstallGenesisService -eq $true -or $StartGenesis -eq $true'
            Parameters = @{
                Action = 'Reinitialize'
            }
            ContinueOnError = $false  # This MUST succeed
        }

        @{
            Name = "Install Genesis as System Service (Cross-Platform)"
            Script = "0843_Install-SystemServices"
            Description = "Install Genesis as a system service (Windows Services/systemd/launchd) so it persists across reboots"
            Condition = '$InstallGenesisService -eq $true'
            Parameters = @{
                Action = "InstallGenesis"
                Enable = $true
                Start = $false
            }
            ContinueOnError = $true  # Optional but recommended
        }

        @{
            Name = "Install GenesisAgent Windows Service"
            Script = "0842_Manage-AitherWindowsServices"
            Description = "Install GenesisAgent as Windows service (AitherGenesisAgent) so it can take over automation post-bootstrap"
            Condition = '$IsWindows'
            Parameters = @{
                Action = "Install"
                ServiceName = "GenesisAgent"
                Group = "core"
                ShowOutput = $true
                Force = $true
            }
            ContinueOnError = $false
        }

        @{
            Name = "Start GenesisAgent Windows Service"
            Script = "0842_Manage-AitherWindowsServices"
            Description = "Start GenesisAgent; it will install/start the remaining services and run health checks + reporting"
            Condition = '$IsWindows'
            Parameters = @{
                Action = "Start"
                ServiceName = "GenesisAgent"
                Group = "core"
                ShowOutput = $true
            }
            ContinueOnError = $false
        }

        @{
            Name = "Install Core Services as System Services"
            Script = "0843_Install-SystemServices"
            Description = "Install core AitherOS services as system services for persistence across reboots"
            Condition = '$InstallGenesisService -eq $true'
            Parameters = @{
                Action = "Install"
                Group = "core"
                Enable = $true
                Start = $false
            }
            ContinueOnError = $true  # Continue even if some services fail to install
        }

        @{
            Name = "Setup Scheduled Backups"
            Script = "0845_Setup-ScheduledBackups"
            Description = "Configure nightly backup schedule and backup directory for disaster recovery"
            Parameters = @{
                }
            ContinueOnError = $true  # Non-critical — backups can be configured later
        }

        # NOTE: We intentionally DO NOT boot the full ecosystem here.
        # GenesisAgent is responsible for installing/starting/health-checking the rest.
        
        # ============================================================
        # PHASE 7: GENESISAGENT IS STARTED BY GENESIS
        # ============================================================
        # GenesisAgent is in the 'core' group with boot_priority: 1
        # Genesis auto-starts it with: boot_with_genesis: true
        # 
        # GenesisAgent takes over ALL automation:
        # - Zombie process cleanup
        # - Service lifecycle management
        # - Auto-recovery
        # - MCP tool execution for local OS commands (via AitherZero MCP Server)
        #
        # Access it at: http://localhost:8776
        
        # ============================================================
        # PHASE 8: VALIDATION
        # ============================================================
        
        @{
            Name = "Get AitherOS Status"
            Script = "0803_Get-AitherStatus"
            Description = "Verify all services are running"
            Parameters = @{
                }
            ContinueOnError = $true
        }
    )
    
    OnSuccess = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════════╗
║           🚀 AITHEROS GENESIS BOOTSTRAP COMPLETE 🚀               ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  INSTALLED DEPENDENCIES:                                          ║
║  ✓ Python 3.11+ with pip                                          ║
║  ✓ Node.js 20+ with npm                                           ║
║  ✓ Docker Desktop (container orchestration)                       ║
║  ✓ Ollama (local LLM inference)                                   ║
║  ✓ NSSM (Windows service manager)                                 ║
║  ✓ AitherNode Python packages                                     ║
║  ✓ AitherZero MCP Server (PowerShell tools for agents)            ║
║                                                                   ║
║  AI MODELS CONFIGURED:                                            ║
║  ✓ nvidia/nemotron-orchestrator-8b (base model)                   ║
║  ✓ aither-orchestrator-v5 (priority model - Nemotron-based)       ║
║    → Set as default for Aither, Council, Demiurge                 ║
║  ✓ Background download: reflex, agent, reasoning tiers            ║
║                                                                   ║
║  GENESIS BOOTLOADER:                                              ║
║  → Dashboard:  http://localhost:8001/dashboard                    ║
║  → API Docs:   http://localhost:8001/docs                         ║
║  → BMC Status: http://localhost:8001/bmc/status                   ║
║                                                                   ║
║  SYSTEM SERVICE STATUS:                                           ║
║  ✓ Genesis installed as system service (persists across reboots) ║
║  ✓ Core services installed with auto-start on boot               ║
║                                                                   ║
║  PLATFORM-SPECIFIC COMMANDS:                                      ║
║  Windows:                                                         ║
║    Get-Service AitherGenesis          # Check status              ║
║    Start-Service AitherGenesis        # Start Genesis             ║
║    Stop-Service AitherGenesis         # Stop Genesis              ║
║                                                                   ║
║  Linux (systemd):                                                 ║
║    systemctl status aither-genesis    # Check status              ║
║    systemctl start aither-genesis     # Start Genesis             ║
║    systemctl stop aither-genesis      # Stop Genesis              ║
║    journalctl -u aither-genesis -f    # View logs                 ║
║                                                                   ║
║  macOS (launchd):                                                 ║
║    launchctl list com.aither.genesis  # Check status              ║
║    launchctl start com.aither.genesis # Start Genesis             ║
║    launchctl stop com.aither.genesis  # Stop Genesis              ║
║                                                                   ║
║  NEXT STEPS:                                                      ║
║  1. Reboot your system to verify services start automatically     ║
║  2. Open Genesis Dashboard in browser                             ║
║  3. Use dashboard to control all services                         ║
║                                                                   ║
║  Manual Commands:                                                 ║
║    Invoke-AitherScript 0800 -Action Status   # Check Genesis      ║
║    Invoke-AitherScript 0803                  # Full OS status     ║
║    Invoke-AitherScript 0800 -Action Stop     # Stop Genesis       ║
║    ollama run aither-orchestrator-8b-v4      # Test model         ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    }
    
    OnFailure = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════════╗
║           ⚠️ GENESIS BOOTSTRAP ENCOUNTERED ERRORS ⚠️              ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  Some steps may have failed. Check the output above for details.  ║
║                                                                   ║
║  COMMON FIXES:                                                    ║
║  • Run as Administrator for system-wide installs                  ║
║  • Check internet connectivity                                    ║
║  • Update winget: winget upgrade --all                            ║
║  • Manually install failed components                             ║
║                                                                   ║
║  RETRY INDIVIDUAL STEPS:                                          ║
║    Invoke-AitherScript 0206    # Python                           ║
║    Invoke-AitherScript 0201    # Node.js                          ║
║    Invoke-AitherScript 0740    # Ollama                           ║
║    Invoke-AitherScript 0226    # NSSM                             ║
║    Invoke-AitherScript 0761    # AitherNode setup                 ║
║    Invoke-AitherScript 0762    # AitherZero MCP build             ║
║    Invoke-AitherScript 0800    # Genesis                          ║
║                                                                   ║
║  DOCUMENTATION:                                                   ║
║    https://github.com/wizzense/AitherZero/docs/QUICKSTART.md      ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    }
}






