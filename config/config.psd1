#Requires -Version 7.0

<#
.SYNOPSIS
    AitherZero Configuration Manifest - Single Source of Truth
.DESCRIPTION
    This is the master configuration manifest for the AitherZero infrastructure automation platform.
    Every aspect of the system is configuration-driven through this file for true CI/CD automation.

    This file serves as both:
    - Configuration store for all components
    - Manifest defining features, dependencies, and capabilities
    - Source of truth for automation workflows

    UPDATED: January 2026 - Simplified Script Architecture
    The automation scripts have been reorganized into a category-based structure
    with ~40 focused scripts replacing the previous 212+ scripts.

    Configuration Features:
    - Native PowerShell Data File (.psd1) format
    - IntelliSense support in IDEs
    - Hierarchical configuration sections
    - Environment-specific overrides
    - Feature dependency mapping
    - Platform abstraction layer
    - CI/CD automation profiles

    Configuration Precedence (highest to lowest):
    1. Command-line parameters
    2. Environment variables (AITHERZERO_*)
    3. config.local.psd1 (local overrides, gitignored)
    4. This file (config.psd1) - Master manifest
    5. Module defaults (fallback only)

.NOTES
    Version: 3.0 - Simplified Script Architecture
    Last Updated: 2026-01-24
#>

# AitherZero Configuration Manifest - Single Source of Truth
@{
    # ===================================================================
    # PLATFORM MANIFEST - System Capabilities and Dependencies
    # ===================================================================
    Manifest                 = @{
        Name                = 'AitherZero'
        Version             = '3.0.0'
        Type                = 'Infrastructure Automation Platform'
        Description         = 'Container-first infrastructure automation with category-based script orchestration'

        # Platform support matrix
        SupportedPlatforms  = @{
            Windows = @{
                Versions          = @('10', '11', 'Server2019', 'Server2022')
                MinimumPowerShell = '7.0'
                RequiredFeatures  = @('PowerShell7', 'Git', 'Docker')
                OptionalFeatures  = @('HyperV', 'WSL2', 'Kubernetes')
            }
            Linux   = @{
                Distributions     = @('Ubuntu 20.04+', 'Debian 11+', 'RHEL 8+', 'CentOS 8+')
                MinimumPowerShell = '7.0'
                RequiredPackages  = @('curl', 'wget', 'git', 'docker')
                PackageManagers   = @('apt', 'yum', 'dnf')
            }
            macOS   = @{
                Versions          = @('11.0+', '12.0+', '13.0+')
                MinimumPowerShell = '7.0'
                RequiredTools     = @('brew', 'git', 'docker')
            }
        }

        # =============================================================
        # SIMPLIFIED FEATURE DEPENDENCIES (January 2026 Redesign)
        # =============================================================
        # Scripts are now organized in category-based directories:
        #   00-bootstrap:     System prerequisites and environment
        #   10-infrastructure: Registry, networking, certificates
        #   20-build:         Container image builds
        #   30-deploy:        Deployment targets
        #   40-lifecycle:     Service start/stop/restart/scale
        #   50-ai-setup:      AI/ML tools
        #   60-monitoring:    Prometheus, Grafana, alerting
        #   70-security:      Secrets, TLS, network policies
        #   80-testing:       Integration tests, validation
        #   90-maintenance:   Backup, cleanup, updates
        # =============================================================
        FeatureDependencies = @{
            # Core features - Bootstrap category
            Bootstrap       = @{
                Prerequisites    = @{ 
                    Scripts     = @('00-bootstrap/0001') 
                    Description = 'System prerequisites validation'
                    Required    = $true
                }
                PowerShell7      = @{ 
                    Scripts     = @('00-bootstrap/0002') 
                    Description = 'PowerShell 7+ runtime'
                    Required    = $true
                }
                Docker           = @{ 
                    Scripts     = @('00-bootstrap/0003') 
                    Description = 'Docker container runtime'
                    Required    = $true
                }
                Kubernetes       = @{ 
                    Scripts     = @('00-bootstrap/0004') 
                    Description = 'Kubernetes CLI tools (kubectl, helm, kind)'
                    Required    = $false
                }
                Environment      = @{ 
                    Scripts     = @('00-bootstrap/0005') 
                    Description = 'Environment configuration'
                    Required    = $true
                }
            }

            # Infrastructure category
            Infrastructure  = @{
                ContainerRegistry = @{
                    Scripts     = @('10-infrastructure/1001')
                    DependsOn   = @('Bootstrap.Docker')
                    Description = 'Container registry setup'
                }
                Networking        = @{
                    Scripts     = @('10-infrastructure/1002')
                    DependsOn   = @('Bootstrap.Docker')
                    Description = 'Docker network configuration'
                }
                Certificates      = @{
                    Scripts     = @('10-infrastructure/1003')
                    DependsOn   = @('Bootstrap.Prerequisites')
                    Description = 'TLS certificate setup'
                }
                Storage           = @{
                    Scripts     = @('10-infrastructure/1004')
                    DependsOn   = @('Bootstrap.Docker')
                    Description = 'Volume and storage configuration'
                }
            }

            # Build category
            Build           = @{
                BaseImage        = @{
                    Scripts     = @('20-build/2001')
                    DependsOn   = @('Bootstrap.Docker')
                    Description = 'Build base container image'
                }
                ServiceImages    = @{
                    Scripts     = @('20-build/2003')
                    DependsOn   = @('Build.BaseImage')
                    Description = 'Build all service images via Compose'
                }
                PushImages       = @{
                    Scripts     = @('20-build/2005')
                    DependsOn   = @('Build.ServiceImages')
                    Description = 'Push images to registry'
                }
            }

            # Deploy category
            Deploy          = @{
                LocalCompose     = @{
                    Scripts     = @('30-deploy/3001')
                    DependsOn   = @('Build.ServiceImages')
                    Description = 'Deploy locally via Docker Compose'
                }
                K8sCluster       = @{
                    Scripts     = @('30-deploy/3002')
                    DependsOn   = @('Bootstrap.Kubernetes', 'Build.ServiceImages')
                    Description = 'Deploy to Kubernetes cluster'
                }
                GCP              = @{
                    Scripts     = @('30-deploy/3003')
                    DependsOn   = @('Build.ServiceImages')
                    Description = 'Deploy to Google Cloud Platform'
                }
                Azure            = @{
                    Scripts     = @('30-deploy/3004')
                    DependsOn   = @('Build.ServiceImages')
                    Description = 'Deploy to Microsoft Azure'
                }
            }

            # Lifecycle category
            Lifecycle       = @{
                StartServices    = @{
                    Scripts     = @('40-lifecycle/4001')
                    DependsOn   = @('Deploy.LocalCompose')
                    Description = 'Start all services'
                }
                StopServices     = @{
                    Scripts     = @('40-lifecycle/4002')
                    Description = 'Stop all services gracefully'
                }
                RestartServices  = @{
                    Scripts     = @('40-lifecycle/4003')
                    Description = 'Restart specific services'
                }
                ScaleServices    = @{
                    Scripts     = @('40-lifecycle/4004')
                    Description = 'Scale service replicas'
                }
                Rollback         = @{
                    Scripts     = @('40-lifecycle/4005')
                    Description = 'Rollback deployment to previous version'
                }
            }

            # AI Setup category
            AISetup         = @{
                vLLM             = @{
                    Scripts     = @('50-ai-setup/5001')
                    Description = 'Configure and start vLLM multi-model stack'
                }
                ProvisionModels  = @{
                    Scripts     = @('50-ai-setup/5002')
                    DependsOn   = @('AISetup.vLLM')
                    Description = 'Provision AI models for vLLM workers'
                }
                ComfyUI          = @{
                    Scripts     = @('50-ai-setup/5003')
                    Description = 'Setup ComfyUI for image generation'
                }
                GPUConfig        = @{
                    Scripts     = @('50-ai-setup/5004')
                    Description = 'Configure GPU access for containers'
                }
            }

            # Monitoring category
            Monitoring      = @{
                Prometheus       = @{
                    Scripts     = @('60-monitoring/6001')
                    DependsOn   = @('Bootstrap.Docker')
                    Description = 'Deploy Prometheus metrics'
                }
                Grafana          = @{
                    Scripts     = @('60-monitoring/6002')
                    DependsOn   = @('Monitoring.Prometheus')
                    Description = 'Deploy Grafana dashboards'
                }
                Alerts           = @{
                    Scripts     = @('60-monitoring/6003')
                    DependsOn   = @('Monitoring.Prometheus')
                    Description = 'Configure alerting rules'
                }
                LogAggregation   = @{
                    Scripts     = @('60-monitoring/6004')
                    Description = 'Centralized log collection'
                }
            }

            # Security category
            Security        = @{
                Secrets          = @{
                    Scripts     = @('70-security/7001')
                    Description = 'Secrets management setup'
                }
                TLS              = @{
                    Scripts     = @('70-security/7002')
                    DependsOn   = @('Infrastructure.Certificates')
                    Description = 'TLS configuration'
                }
                NetworkPolicies  = @{
                    Scripts     = @('70-security/7003')
                    DependsOn   = @('Bootstrap.Kubernetes')
                    Description = 'Kubernetes network policies'
                }
            }

            # Testing category
            Testing         = @{
                IntegrationTests = @{
                    Scripts     = @('80-testing/8001')
                    DependsOn   = @('Lifecycle.StartServices')
                    Description = 'Run integration tests'
                }
                ValidateServices = @{
                    Scripts     = @('80-testing/8002')
                    DependsOn   = @('Lifecycle.StartServices')
                    Description = 'Validate service health'
                }
                BenchmarkSuite   = @{
                    Scripts     = @('80-testing/8003')
                    DependsOn   = @('Lifecycle.StartServices')
                    Description = 'Run performance benchmarks'
                }
            }

            # Maintenance category
            Maintenance     = @{
                BackupData       = @{
                    Scripts     = @('90-maintenance/9001')
                    Description = 'Backup volumes and data'
                }
                CleanupResources = @{
                    Scripts     = @('90-maintenance/9002')
                    Description = 'Clean unused containers, images, volumes'
                }
                UpdateDeps       = @{
                    Scripts     = @('90-maintenance/9003')
                    Description = 'Update base images and dependencies'
                }
            }
        }

        # Script execution profiles - what gets run for each profile
        ExecutionProfiles   = @{
            Minimal   = @{
                Description   = 'Essential components only (Docker + core services)'
                Categories    = @('Bootstrap')
                Playbook      = 'bootstrap'
                EstimatedTime = '5-10 minutes'
            }
            Standard  = @{
                Description   = 'Standard development environment'
                Categories    = @('Bootstrap', 'Build', 'Deploy', 'Lifecycle')
                Playbook      = 'deploy-local'
                EstimatedTime = '10-20 minutes'
            }
            Full      = @{
                Description   = 'Full deployment with monitoring and security'
                Categories    = @('Bootstrap', 'Build', 'Deploy', 'Lifecycle', 'Monitoring', 'Security')
                Playbook      = 'deploy-prod'
                EstimatedTime = '20-40 minutes'
            }
            CI        = @{
                Description    = 'Optimized for CI/CD environments'
                Categories     = @('Bootstrap', 'Build', 'Testing')
                Playbook       = 'build'
                Parallel       = $true
                NonInteractive = $true
                EstimatedTime  = '5-15 minutes'
            }
            AIWorkload = @{
                Description   = 'AI/ML workload with GPU support'
                Categories    = @('Bootstrap', 'Build', 'Deploy', 'Lifecycle', 'AISetup')
                EstimatedTime = '15-30 minutes'
            }
        }

        # Playbook inventory - orchestration playbook tracking
        PlaybookInventory   = @{
            Count = 4
            Path  = 'library/playbooks'
            Items = @(
                @{ Name = 'bootstrap'; Description = 'Fresh system setup' }
                @{ Name = 'build'; Description = 'Build container images' }
                @{ Name = 'deploy-local'; Description = 'Local Docker Compose deployment' }
                @{ Name = 'deploy-prod'; Description = 'Production Kubernetes deployment' }
            )
        }

        # Script inventory by category (actual directories on disk)
        ScriptInventory     = @{
            '00-bootstrap'            = @{ Count = 9;  Category = 'System Bootstrap';         Range = '0000-0011' }
            '08-project'              = @{ Count = 0;  Category = 'Project Config';            Range = '0845' }
            '10-devtools'             = @{ Count = 19; Category = 'Dev Tool Installation';    Range = '0769-1021' }
            '20-build'                = @{ Count = 7;  Category = 'Container Builds';         Range = '2001-2011' }
            '30-deploy'               = @{ Count = 11; Category = 'Deployment';               Range = '3001-3022' }
            '40-lifecycle'            = @{ Count = 9;  Category = 'Service Lifecycle';         Range = '4001-4008' }
            '50-ai-setup'             = @{ Count = 7;  Category = 'AI/ML Setup (vLLM)';       Range = '0550-5002' }
            '60-monitoring'           = @{ Count = 2;  Category = 'Monitoring';               Range = '0650-6001' }
            '60-security'             = @{ Count = 5;  Category = 'Security';                 Range = '0820-6003' }
            '70-external-integrations' = @{ Count = 2;  Category = 'External Integrations';   Range = 'varies' }
            '70-git'                  = @{ Count = 2;  Category = 'Git & GitHub';             Range = '0897-0898' }
            '70-maintenance'          = @{ Count = 4;  Category = 'Maintenance';              Range = '7001-9020' }
            '80-testing'              = @{ Count = 8;  Category = 'Testing & Validation';     Range = '0402-8010' }
        }

        # Domain module structure
        Domains             = @{
            'automation'     = @{ Modules = 3; Description = 'Playbook execution and script orchestration' }
            'configuration'  = @{ Modules = 2; Description = 'Unified configuration management' }
            'containers'     = @{ Modules = 2; Description = 'Docker and Kubernetes integration' }
            'utilities'      = @{ Modules = 4; Description = 'Core utilities and logging' }
        }

        # Configuration schema version for validation
        SchemaVersion       = '3.0'
        LastUpdated         = '2026-01-24'
    }

    # ===================================================================
    # PROJECT CONTEXT - What This AitherZero Instance Manages
    # ===================================================================
    # Override these values via plugin config overlay or config.local.psd1
    # to point AitherZero at your project instead of the defaults.
    ProjectContext            = @{
        Name               = 'MyProject'       # Project display name
        ComposeFile        = 'docker-compose.yml'
        ProjectName        = 'myproject'        # Docker project name prefix
        ContainerPrefix    = 'myproject'        # Container name prefix for filtering
        NetworkName        = 'myproject-net'    # Docker network name
        RegistryURL        = ''                 # Container registry (e.g., ghcr.io/org)
        OrchestratorURL    = ''                 # Orchestrator/API URL (e.g., http://localhost:8001)
        MetricsURL         = ''                 # Metrics/health URL (e.g., http://localhost:8081)
        EventBusURL        = ''                 # Event bus URL
        TelemetryURL       = ''                 # Telemetry/ingest URL (e.g., http://localhost:8136)
        ServicesFile       = ''                 # Path to services definition file (e.g., services.yaml)
        ConfigPath         = 'config/'          # Relative path to project config
        Domain             = ''                 # Production domain (e.g., example.com)
    }

    # ===================================================================
    # CORE CONFIGURATION - Fundamental System Settings
    # ===================================================================
    Core                     = @{
        # Platform and environment
        Name               = 'AitherZero'
        Version            = '3.0.0'
        Platform           = 'auto'  # auto, windows, linux, macos
        Environment        = 'Development'  # Development, Testing, Staging, Production, CI

        # Execution profiles - determines which features/scripts are enabled
        Profile            = 'Standard'  # Minimal, Standard, Full, CI, AIWorkload

        # Container-first architecture
        ContainerRuntime   = 'docker'  # docker, podman
        Orchestrator       = 'compose'  # compose, kubernetes

        # Behavior settings
        AutoStart          = $true
        NonInteractive     = $false  # Automatically set to true in CI environments
        CI                 = $false  # Automatically detected in CI environments

        # User experience
        ClearScreenOnStart = $true
        ShowWelcomeMessage = $true
        EnableAnimations   = $true

        ErrorReporting     = $true
        CheckForUpdates    = $true

        # Debugging and development
        DebugMode          = $false
        VerboseOutput      = $false
        WhatIf             = $false
        DryRun             = $false

        # Execution control
        ContinueOnError    = $false
        SkipPrerequisites  = $false
        ForceReinstall     = $false

        # Output and reporting
        OutputFormat       = 'Console'  # Console, JSON - automatically set to JSON in CI
        ShowProgress       = $true
        ShowExecutionTime  = $true

        # Configuration management
        ConfigValidation   = $true
        ConfigHotReload    = $true
        ConfigBackup       = $true
    }

    # ===================================================================
    # CONTAINER CONFIGURATION - Docker and Kubernetes Settings
    # ===================================================================
    Container                = @{
        # Docker settings — override via ProjectContext or plugin config overlay
        Docker             = @{
            ComposeFile       = 'docker-compose.yml'  # Override via ProjectContext.ComposeFile
            DevOverlay        = 'docker/docker-compose.dev.yml'
            ProdOverlay       = 'docker/docker-compose.prod.yml'
            GPUOverlay        = 'docker/docker-compose.gpu.yml'
            ProjectName       = 'myproject'            # Override via ProjectContext.ProjectName
            DefaultNetwork    = 'myproject-net'         # Override via ProjectContext.NetworkName
        }

        # Kubernetes settings
        Kubernetes         = @{
            Namespace         = 'default'
            ManifestPath      = 'docker/k8s'
            UseKustomize      = $true
            DefaultContext    = ''  # Empty = current context
        }

        # Registry settings
        Registry           = @{
            URL               = ''                     # Override via ProjectContext.RegistryURL
            DefaultTag        = 'latest'
            PushOnBuild       = $false
        }

        # Image names — override via plugin config overlay
        Images             = @{}
    }

    # ===================================================================
    # SERVICES CONFIGURATION - Service Ports and Settings
    # ===================================================================
    # Service registry — populated by plugin config overlay
    # Plugins add service ports and groups here via ConfigOverlay.
    # For standalone use, define your own services in a plugin or config.local.psd1.
    Services                 = @{
        Ports              = @{}
        Groups             = @{}
    }

    # ===================================================================
    # AI CONFIGURATION - vLLM Multi-Model and Settings
    # ===================================================================
    AI                       = @{
        # Inference engine
        InferenceMode      = 'vllm'  # vllm, ollama (legacy)
        MultiModelMode     = $true   # Run specialist models simultaneously

        # vLLM Multi-Model Stack
        # Each worker serves a specialist role on a shared GPU
        vLLM               = @{
            ComposeFile       = 'docker-compose.vllm-multimodel.yml'
            Image             = 'vllm/vllm-openai:latest'

            Orchestrator      = @{
                Port              = 8200
                Model             = 'cerebras/GLM-4.7-Flash-REAP-23B-A3B'
                ServedName        = 'orchestrator'
                GPUMemory         = 0.19    # ~6GB
                MaxContextLength  = 16384
                MaxConcurrentSeqs = 8
                ToolCallParser    = 'hermes'
                Description       = 'General task routing, intent classification'
            }
            Reasoning         = @{
                Port              = 8201
                Model             = 'cerebras/Qwen3-Coder-REAP-25B-A3B'
                ServedName        = 'reasoning'
                GPUMemory         = 0.22    # ~7GB
                MaxContextLength  = 16384
                MaxConcurrentSeqs = 4
                ToolCallParser    = 'hermes'
                Description       = 'Deep reasoning, CoT, mathematical analysis'
            }
            Vision            = @{
                Port              = 8202
                Model             = 'Qwen/Qwen2.5-VL-7B-Instruct'
                ServedName        = 'vision'
                GPUMemory         = 0.16    # ~5GB
                MaxContextLength  = 8192
                MaxConcurrentSeqs = 4
                Description       = 'Image understanding, multimodal analysis'
            }
            Coding            = @{
                Port              = 8203
                Model             = 'deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct'
                ServedName        = 'coding'
                GPUMemory         = 0.13    # ~4GB
                MaxContextLength  = 8192
                MaxConcurrentSeqs = 4
                Description       = 'Code generation, completion, review'
            }
        }

        # ComfyUI settings
        ComfyUI            = @{
            Port              = 8188
            ModelsPath        = 'data/comfyui-models'
            OutputPath        = 'data/comfyui-output'
        }

        # GPU configuration
        GPU                = @{
            Enabled           = $true
            NvidiaRuntime     = $true
            DeviceRequest     = 'all'  # all, 0, 1, etc.
        }
    }

    # ===================================================================
    # FEATURES - Component Enablement
    # ===================================================================
    Features                 = @{
        # Core requirements
        Core               = @{
            PowerShell7       = @{ Enabled = $true; Required = $true }
            Git               = @{ Enabled = $true; Required = $true }
            Docker            = @{ Enabled = $true; Required = $true }
            Kubernetes        = @{ Enabled = $true; Required = $false }
        }

        # Deployment targets
        Deployment         = @{
            LocalCompose      = @{ Enabled = $true }
            Kubernetes        = @{ Enabled = $true }
            GCP               = @{ Enabled = $false }
            Azure             = @{ Enabled = $false }
        }

        # Monitoring stack
        Monitoring         = @{
            Prometheus        = @{ Enabled = $false }
            Grafana           = @{ Enabled = $false }
            Alerting          = @{ Enabled = $false }
        }

        # AI features
        AI                 = @{
            vLLM              = @{ Enabled = $true }
            MultiModel        = @{ Enabled = $true }
            ComfyUI           = @{ Enabled = $true }
            GPUAcceleration   = @{ Enabled = $true }
        }
    }

    # ===================================================================
    # USER INTERFACE - Display Settings
    # ===================================================================
    UI                       = @{
        ShowHints          = $true
        ClearScreenOnStart = $true
        EnableColors       = $true
        ShowWelcomeMessage = $true
        ShowExecutionTime  = $true
        EnableEmoji        = $true

        # Themes
        Theme              = 'Default'
        Themes             = @{
            Default = @{
                Primary = 'Cyan'
                Warning = 'Yellow'
                Success = 'Green'
                Error   = 'Red'
                Info    = 'White'
                Muted   = 'DarkGray'
            }
        }
    }

    # ===================================================================
    # PATHS - Directory Configuration
    # ===================================================================
    Paths                    = @{
        # Relative to workspace root
        AutomationScripts  = 'AitherZero/library/automation-scripts'
        Playbooks          = 'AitherZero/library/playbooks'
        Docker             = 'docker'
        K8sManifests       = 'docker/k8s'
        Logs               = 'logs'
        Data               = 'data'
        Config             = 'config'           # Override via ProjectContext.ConfigPath
        ServicesYaml       = ''                  # Override via ProjectContext.ServicesFile
    }

    # ===================================================================
    # DEPENDENCIES - Module Dependencies
    # ===================================================================
    Dependencies             = @{
        ValidateOnStart     = $true
        EnforceDependencies = $false

        External            = @{
            Pester           = @{ Version = '5.0.0+'; Required = $false }
            PSScriptAnalyzer = @{ Version = '1.20.0+'; Required = $false }
            ThreadJob        = @{ Version = '2.0.3+'; Required = $true }
        }
    }
}
