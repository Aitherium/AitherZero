@{
    # ===================================================================
    # INFRASTRUCTURE - System and Infrastructure Settings
    # ===================================================================
    Infrastructure           = @{
        # Provider settings
        Provider         = 'opentofu'
        Hypervisor       = 'hyperv'
        WorkingDirectory = './infrastructure'

        # Default resource settings
        DefaultVMPath    = 'C:\VMs'
        DefaultMemory    = '2GB'
        DefaultCPU       = 2

        # Directory paths
        Directories      = @{
            LocalPath     = 'C:/temp'
            HyperVPath    = 'C:/HyperV'
            IsoSharePath  = 'C:/ISOs'
            InfraRepoPath = 'C:/Temp/base-infra'
            VhdPath       = 'C:/VMs/AitherOS'
            TofuEnvPath   = './AitherZero/library/infrastructure/environments/local-hyperv'
        }

        # ISO Pipeline settings
        ISOPipeline      = @{
            Enabled           = $true
            DefaultEdition    = 'Windows Server 2025 SERVERSTANDARDCORE'
            OutputName        = 'AitherOS-Server2025-Core.iso'
            DefaultProfile    = 'Core'
            DefaultBranch     = 'develop'
            MeshCoreUrl       = 'http://192.168.1.100:8125'
            AutoInstallPwsh7  = $true
            AutoInstallDocker = $true
            AutoJoinMesh      = $true
            FirstBootFeatures = @('WinRM', 'PSRemoting', 'Firewall')
            BuildScript       = '3105'
            PrereqScript      = '0100'
            ADKScript         = '0101'
            TofuScript        = '0102'
            HyperVScript      = '0105'
            Playbook          = 'build-iso-pipeline'
            Description       = 'Custom Windows Server ISO with AitherOS bootstrap baked in'
        }

        # HyperV specific settings
        HyperV           = @{
            EnableManagementTools = $true
            Https                 = $true
            Insecure              = $true
            UseNtlm               = $true
            Timeout               = '30s'
            Port                  = 5986
            ScriptPath            = 'C:/Temp/tofu_%RAND%.cmd'
            ProviderVersion       = '1.2.1'
        }

        # Repository settings
        Repositories     = @{
            RepoUrl      = 'https://github.com/Aitherium/AitherLabs.git'
            InfraRepoUrl = 'https://github.com/Aitherium/aitherium-infrastructure.git'
        }

        # Git Submodule Management for Infrastructure
        # Infrastructure repositories are configured as Git submodules for flexible, versioned deployments
        Submodules       = @{
            Enabled      = $true
            AutoInit     = $true  # Automatically initialize submodules on bootstrap
            AutoUpdate   = $false # Don't auto-update submodules (requires explicit action)

            # Default infrastructure repository (Aitherium Infrastructure)
            # Tailored for customized mass deployments to any environment
            Default      = @{
                Name        = 'aitherium-infrastructure'
                Url         = 'https://github.com/Aitherium/aitherium-infrastructure.git'
                Path        = 'infrastructure/aitherium'
                Branch      = 'main'
                Description = 'Default Aitherium infrastructure templates for mass deployment'
                Enabled     = $true
                Repositories = @{}
                Behavior     = @{
                    RecursiveInit    = $true
                    ShallowClone     = $false
                    ParallelJobs     = 4
                    TimeoutSeconds   = 300
                    RetryAttempts    = 3
                    VerifySignatures = $false
                }
            }

            # Additional infrastructure repositories can be configured here
            # Each entry will be managed as a separate Git submodule
            Repositories = @{}

            # Submodule behavior settings
            Behavior     = @{
                RecursiveInit    = $true  # Initialize submodules recursively
                ShallowClone     = $false # Use full clone (not shallow) for better git history
                ParallelJobs     = 4      # Number of parallel jobs for submodule operations
                TimeoutSeconds   = 300    # Timeout for submodule operations
                RetryAttempts    = 3      # Number of retry attempts for failed operations
                VerifySignatures = $false # Verify GPG signatures on submodule commits
            }
        }
    }

    # ===================================================================
    # PSSESSION MANAGEMENT - PowerShell Remoting Session Configuration
    # ===================================================================
    PSSessionManagement         = @{
        # Default session settings
        DefaultPort             = @{
            WinRM               = 5985
            WinRMHTTPS          = 5986
            SSH                 = 22
        }

        # Session storage
        SavedSessionsPath       = './library/saved-sessions'

        # Session pooling
        EnableSessionPooling   = $true
        MaxPoolSize             = 10
        SessionTimeout          = 3600  # seconds (1 hour)

        # Connection settings
        ConnectionTimeout       = 30  # seconds
        OperationTimeout        = 300  # seconds (5 minutes)

        # Security settings
        RequireSSL              = $false  # Set to $true for production WinRM
        VerifyHostKeys          = $true  # For SSH connections

        # Retry settings
        MaxRetries              = 3
        RetryDelay              = 5  # seconds
    }

    Features = @{
        # Infrastructure components
        Infrastructure = @{
            System               = @{
                Enabled       = $false
                InstallScript = '0100'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Description   = 'Base system configuration'
            }
            HyperV               = @{
                Enabled           = $false
                InstallScript     = '0105'
                Platforms         = @('Windows')
                RequiresElevation = $true
                Configuration     = @{
                    PrepareHost           = $false
                    EnableManagementTools = $true
                    DefaultVMPath         = 'C:\VMs'
                    DefaultVHDPath        = 'C:\VHDs'
                    Host                  = 'localhost'
                    User                  = 'Administrator'
                    Port                  = 5985
                    Https                 = $true
                    Insecure              = $true
                    UseNtlm               = $true
                    Timeout               = '30s'
                }
            }
            WSL2                 = @{
                Enabled           = $false
                InstallScript     = '0106'
                Platforms         = @('Windows')
                RequiresElevation = $true
                Configuration     = @{
                    Distribution = 'Ubuntu'
                    Version      = '2'
                    Settings     = @{
                        Memory              = '4GB'
                        Processors          = 2
                        SwapSize            = '2GB'
                        LocalhostForwarding = $true
                    }
                }
            }
            WindowsAdminCenter   = @{
                Enabled           = $false
                InstallScript     = '0106'
                Platforms         = @('Windows')
                RequiresElevation = $true
                Description       = 'Windows Admin Center for remote management'
            }
            CertificateAuthority = @{
                Enabled           = $false
                InstallScript     = '0104'
                Platforms         = @('Windows')
                RequiresElevation = $true
                Description       = 'Certificate Authority installation'
            }
            PXE                  = @{
                Enabled           = $false
                InstallScript     = '0112'
                Platforms         = @('Windows')
                RequiresElevation = $true
                Description       = 'PXE boot configuration'
            }
            WindowsADK           = @{
                Enabled           = $false
                InstallScript     = '0101'
                Platforms         = @('Windows')
                RequiresElevation = $true
                Description       = 'Windows Assessment and Deployment Kit (oscdimg for ISO building)'
            }
            OpenTofu             = @{
                Enabled          = $false
                Version          = 'latest'
                InstallScript    = '0102'
                InitializeScript = '0102'
                Platforms        = @('Windows', 'Linux', 'macOS')
                Configuration    = @{
                    Initialize       = $false
                    WorkingDirectory = './infrastructure'
                }
            }
            Go                   = @{
                Enabled       = $false
                Version       = 'latest'
                InstallScript = '0007'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Description   = 'Go programming language'
            }
            ValidationTools      = @{
                Enabled       = $true  # Enabled by default for code quality
                InstallScript = '0006'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Description   = 'Validation and linting tools (actionlint, etc.)'
            }
            Directories          = @{
                Enabled       = $true
                InstallScript = '0002'
                Configuration = @{
                    HyperVPath    = 'C:\VMs'
                    IsoSharePath  = 'C:\ISOs'
                    LocalPath     = '$HOME/aitherzero/infra'
                    InfraRepoPath = '$HOME/aitherzero/infra-repo'
                }
            }
            Defaults             = @{
                Provider         = 'opentofu'
                Hypervisor       = 'hyperv'
                WorkingDirectory = './infrastructure'
                DefaultVMPath    = 'C:\VMs'
                DefaultMemory    = '2GB'
                DefaultCPU       = 2
            }
        }

        # Mesh and Remote Node management
        Mesh = @{
            Enabled          = $true
            MeshCorePort     = 8125
            HeartbeatInterval = 30      # seconds
            FailoverTimeout  = 120      # seconds before promoting standby
            WatchdogEnabled  = $true
            WatchdogCheckInterval = 60  # seconds
            Description      = 'AitherMesh topology management for LAN failover'
        }
        RemoteNodes = @{
            Enabled            = $true
            DefaultProfile     = 'Core'
            DefaultCredential  = 'AitherNode'
            DeploymentScripts  = @{
                Bootstrap      = '0008'
                Deploy         = '3101'
                Watchdog       = '3102'
                FleetManager   = '3103'
                Replication    = '3104'
            }
            Description        = 'Remote node deployment and lifecycle management'
        }
        Replication = @{
            Enabled            = $true
            PostgreSQL         = @{
                Enabled        = $true
                ContainerName  = 'aitheros-postgres'
                Port           = 5432
                SlotPrefix     = 'aither_node_'
                SyncMode       = 'async'   # async or sync
            }
            Redis              = @{
                Enabled        = $true
                ContainerName  = 'aitheros-redis'
                Port           = 6379
            }
            Strata             = @{
                Enabled        = $true
                Port           = 8136
                SyncEndpoint   = '/api/v1/sync/start'
            }
            Description        = 'Database replication across mesh nodes'
        }
    }
}
