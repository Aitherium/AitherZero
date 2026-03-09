@{
    Name        = "install-aitheros"
    Description = "Full AitherOS installation — prerequisites, dependencies, partner profile setup, deployment, model provisioning"
    Version     = "1.0.0"
    Author      = "AitherZero"

    # ═══════════════════════════════════════════════════════════════════════════
    # CROSS-PLATFORM AITHEROS INSTALLER PLAYBOOK
    # ═══════════════════════════════════════════════════════════════════════════
    #
    # USAGE:
    #   ./bootstrap.ps1 -Playbook install-aitheros
    #   ./bootstrap.ps1 -Playbook install-aitheros -NonInteractive
    #   Invoke-AitherPlaybook install-aitheros
    #
    # For pull mode (pre-built images from private registry):
    #   $env:AITHEROS_DEPLOY_MODE = "pull"
    #   ./bootstrap.ps1 -Playbook install-aitheros
    #
    # This playbook handles a COMPLETE fresh installation:
    # 1. Validates system prerequisites (OS, RAM, CPU, disk)
    # 2. Installs dependencies (Docker, Git, NVIDIA toolkit)
    # 3. Configures the AitherOS environment (.env, dirs, venv)
    # 4. Sets up partner profile (interactive wizard OR config file)
    # 5. Applies the profile (branding, agents, RBAC, secrets)
    # 6. Deploys AitherOS via Docker Compose
    # 7. Provisions AI models based on hardware
    # 8. Validates all services are healthy
    #
    # MODES:
    #   Interactive:     Launches AitherVeil wizard at localhost:3000
    #   Non-interactive: Reads from config/profiles/{slug}/profile.yaml
    #   Headless:        Generates default profile, deploys immediately
    #
    # TARGETS:
    #   Windows (native or WSL2), Linux (Ubuntu/Debian/RHEL), macOS
    #
    # ═══════════════════════════════════════════════════════════════════════════

    Parameters = @{
        # Deployment mode: source | pull | hybrid
        DeployMode       = '$env:AITHEROS_DEPLOY_MODE ?? "source"'

        # Service profile: minimal | core | full
        Profile          = '$env:AITHEROS_PROFILE ?? "core"'

        # Partner profile path (auto-detect if empty)
        PartnerProfile   = '$env:AITHER_PARTNER_PROFILE ?? ""'

        # Skip interactive wizard — use existing profile or generate default
        NonInteractive   = '$env:AITHEROS_NONINTERACTIVE -eq "1" -or $env:CI -eq "true"'

        # Launch the AitherVeil installer wizard (overrides NonInteractive)
        Interactive      = '$env:AITHEROS_INTERACTIVE -eq "1"'

        # Dependency installation
        InstallDeps      = $true
        SkipGPU          = '$env:AITHEROS_SKIP_GPU -eq "1"'

        # Model provisioning
        ProvisionModels  = '$env:AITHEROS_SKIP_MODELS -ne "1"'

        # Post-install
        HealthCheck      = $true
        OpenDashboard    = '$env:CI -ne "true"'

        # Options
        Force            = $false
    }

    Prerequisites = @(
        "PowerShell 7+ (auto-installed by bootstrap.ps1)"
        "Internet connection (for Docker images and model downloads)"
        "10GB+ free disk space (minimal), 50GB+ recommended (full with models)"
        "Windows 10/11, Ubuntu 20.04+, macOS 11+"
        "8GB+ RAM (16GB+ recommended, 32GB+ for full GPU inference)"
    )

    Sequence = @(
        # ============================================================
        # PHASE 1: SYSTEM VALIDATION
        # ============================================================

        @{
            Name            = "Validate Prerequisites"
            Script          = "00-bootstrap/0001_Validate-Prerequisites"
            Description     = "Check OS, disk, RAM, CPU, network connectivity"
            Parameters      = @{
                MinDiskSpaceGB = 10
                MinMemoryGB    = 8
                MinCPUCores    = 2
            }
            ContinueOnError = $true
        }

        @{
            Name            = "System Fingerprint"
            Script          = "00-bootstrap/0011_Get-SystemFingerprint"
            Description     = "Detect platform, hardware, GPU, available resources"
            Parameters      = @{}
            ContinueOnError = $true
        }

        # ============================================================
        # PHASE 2: INSTALL DEPENDENCIES
        # ============================================================

        @{
            Name            = "Install Dependencies"
            Script          = "30-deploy/3021_Install-Dependencies"
            Description     = "Auto-detect and install Docker, Git, NVIDIA toolkit"
            Condition       = '$InstallDeps -eq $true'
            Parameters      = @{
                NonInteractive = '$NonInteractive'
                Force          = '$Force'
                SkipGPU        = '$SkipGPU'
            }
            ContinueOnError = $false
        }

        # ============================================================
        # PHASE 3: CONFIGURE ENVIRONMENT
        # ============================================================

        @{
            Name            = "Configure Environment"
            Script          = "00-bootstrap/0005_Configure-Environment"
            Description     = "Create directories, .env, Python venv, shell config"
            Parameters      = @{
                CreateVenv = $true
            }
            ContinueOnError = $true
        }

        # ============================================================
        # PHASE 4: PARTNER PROFILE SETUP
        # ============================================================

        @{
            Name            = "Setup Partner Profile"
            Script          = "30-deploy/3033_Setup-PartnerInteractive"
            Description     = "Interactive wizard or config-file partner profile creation"
            Parameters      = @{
                ProfilePath    = '$PartnerProfile'
                Interactive    = '$Interactive'
                NonInteractive = '$NonInteractive'
            }
            ContinueOnError = $true
        }

        @{
            Name            = "Apply Partner Profile"
            Script          = "30-deploy/3031_Deploy-PartnerProfile"
            Description     = "Validate and apply partner profile (branding, agents, RBAC)"
            Condition       = 'Test-Path "$env:AITHER_PARTNER_PROFILE/profile.yaml" -ErrorAction SilentlyContinue'
            Parameters      = @{
                ProfilePath  = '$env:AITHER_PARTNER_PROFILE'
                SkipBoot     = $true
            }
            ContinueOnError = $true
        }

        # ============================================================
        # PHASE 5: DEPLOY SERVICES
        # ============================================================

        @{
            Name            = "Deploy AitherOS"
            Script          = "30-deploy/3020_Deploy-OneClick"
            Description     = "Build or pull Docker images and start all services"
            Parameters      = @{
                Mode            = '$DeployMode'
                Profile         = '$Profile'
                Force           = '$Force'
                NonInteractive  = '$NonInteractive'
                SkipDependencies = $true
                SkipModels       = $true
            }
            ContinueOnError = $false
        }

        # ============================================================
        # PHASE 6: AI MODEL PROVISIONING
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
        # PHASE 7: POST-INSTALL (RBAC seed + knowledge ingest via Genesis)
        # ============================================================

        @{
            Name            = "Post-Install Provisioning"
            Script          = "30-deploy/3034_Post-Install"
            Description     = "Seed RBAC, ingest partner knowledge, verify services"
            Parameters      = @{}
            ContinueOnError = $true
        }

        # ============================================================
        # PHASE 8: HEALTH CHECK
        # ============================================================

        @{
            Name            = "Health Check"
            Script          = "08-aitheros/0803_Get-AitherStatus"
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
 ║            AITHEROS INSTALLATION COMPLETE                         ║
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
 ║  MANAGEMENT:                                                      ║
 ║  ┌─────────────────────────────────────────────────────────────┐  ║
 ║  │  Status:    docker ps --filter name=aither                 │  ║
 ║  │  Logs:      docker compose -f docker-compose.aitheros.yml  │  ║
 ║  │             logs -f [service]                              │  ║
 ║  │  Stop:      npm stop                                       │  ║
 ║  │  Restart:   npm start                                      │  ║
 ║  │  Settings:  http://localhost:3000/settings/partner          │  ║
 ║  └─────────────────────────────────────────────────────────────┘  ║
 ║                                                                   ║
 ║  RE-RUN ANYTIME:                                                  ║
 ║    ./bootstrap.ps1 -Playbook install-aitheros                     ║
 ║    Invoke-AitherPlaybook install-aitheros                         ║
 ║                                                                   ║
 ╚═══════════════════════════════════════════════════════════════════╝
"@
    }

    OnFailure = @{
        Message = @"

 ╔═══════════════════════════════════════════════════════════════════╗
 ║            INSTALLATION ENCOUNTERED ERRORS                        ║
 ╠═══════════════════════════════════════════════════════════════════╣
 ║                                                                   ║
 ║  Check the output above for specific error messages.              ║
 ║                                                                   ║
 ║  COMMON FIXES:                                                    ║
 ║  ┌─────────────────────────────────────────────────────────────┐  ║
 ║  │  Docker not running:                                       │  ║
 ║  │    Start Docker Desktop, then retry                        │  ║
 ║  │                                                            │  ║
 ║  │  Port conflicts:                                           │  ║
 ║  │    docker compose -f docker-compose.aitheros.yml down      │  ║
 ║  │    Then retry installation                                 │  ║
 ║  │                                                            │  ║
 ║  │  Disk space:                                               │  ║
 ║  │    docker system prune -a  (removes unused images)         │  ║
 ║  │    Need at least 10GB free                                 │  ║
 ║  │                                                            │  ║
 ║  │  Model download failed:                                    │  ║
 ║  │    AITHEROS_SKIP_MODELS=1 ./bootstrap.ps1 ...              │  ║
 ║  └─────────────────────────────────────────────────────────────┘  ║
 ║                                                                   ║
 ║  RETRY:     ./bootstrap.ps1 -Playbook install-aitheros             ║
 ║  SUPPORT:   https://github.com/Aitherium/AitherOS/issues          ║
 ║                                                                   ║
 ╚═══════════════════════════════════════════════════════════════════╝
"@
    }
}
