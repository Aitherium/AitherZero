@{
    Name        = "deploy-hyperv-node"
    Description = "End-to-end deployment of an AitherNode to a remote Windows Server 2025 Hyper-V host with LAN hot failover"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "deploy"
    
    # ═══════════════════════════════════════════════════════════════════════════
    # HYPER-V NODE DEPLOYMENT PLAYBOOK
    # ═══════════════════════════════════════════════════════════════════════════
    #
    # USAGE:
    #   Invoke-AitherPlaybook deploy-hyperv-node -Variables @{ ComputerName = "lab-server" }
    #   New-AitherHyperVNode -ComputerName "lab-server"
    #   Invoke-AitherElysiumDeploy -ComputerName "lab-server"
    #
    # TARGET: Windows Server 2025 (Server Core) running Hyper-V
    # GOAL:   Deploy AitherNode + join AitherMesh for LAN hot failover
    #
    # PHASES:
    # 1. Validate target connectivity and hardware
    # 2. Bootstrap Hyper-V, Docker, PS7, networking on remote host
    # 3. Deploy AitherNode containers via docker-compose.node.yml
    # 4. Join node to AitherMesh with failover priority
    # 5. Health check and validate mesh membership
    # 6. Optionally start failover watchdog
    #
    # ═══════════════════════════════════════════════════════════════════════════
    
    Parameters = @{
        # REQUIRED: Target server
        ComputerName     = ''
        
        # Authentication (one of these)
        CredentialName   = ''
        
        # Connection
        UseSSH           = $false
        
        # What to install
        SkipHyperV       = $false
        SkipDocker       = $false
        SkipFirewall     = $false
        GPU              = $false
        
        # Node config
        Profile          = 'core'
        FailoverPriority = 10
        ReplicateServices = 'Pulse,Chronicle,Strata'
        VirtualSwitchName = 'AitherSwitch'
        
        # Mesh
        CoreUrl          = ''
        MeshToken        = ''
        
        # Post-deploy
        StartWatchdog    = $false
        WatchdogInterval = 15
        FailureThreshold = 3
        
        # Options
        Force            = $false
        NonInteractive   = '$env:CI -eq "true"'
    }
    
    Prerequisites = @(
        "PowerShell 7+ on the control machine (this machine)"
        "Network connectivity to target server"
        "WinRM or SSH access to target server"
        "Administrator credentials for the target"
        "Target: Windows Server 2025 (Server Core recommended)"
    )
    
    Sequence = @(
        # ============================================================
        # PHASE 1: VALIDATE
        # ============================================================
        
        @{
            Name            = "Validate Target Connectivity"
            Script          = "31-remote/3100_Setup-HyperVHost"
            Description     = "Test connectivity, validate hardware requirements"
            Parameters      = @{
                ComputerName = '$ComputerName'
                DryRun       = $true
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 2: BOOTSTRAP REMOTE HOST
        # ============================================================
        
        @{
            Name            = "Bootstrap Hyper-V Host"
            Script          = "31-remote/3100_Setup-HyperVHost"
            Description     = "Install Hyper-V, Docker, PS7, configure networking and firewall on remote host"
            Parameters      = @{
                ComputerName      = '$ComputerName'
                SkipHyperV        = '$SkipHyperV'
                SkipDocker        = '$SkipDocker'
                SkipFirewall      = '$SkipFirewall'
                GPU               = '$GPU'
                VirtualSwitchName = '$VirtualSwitchName'
                CoreUrl           = '$CoreUrl'
                MeshToken         = '$MeshToken'
                Force             = '$Force'
            }
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 3: DEPLOY AITHERNODE
        # ============================================================
        
        @{
            Name            = "Deploy AitherNode Containers"
            Script          = "31-remote/3101_Deploy-RemoteNode"
            Description     = "Deploy/update AitherNode containers with failover configuration"
            Parameters      = @{
                ComputerName      = '$ComputerName'
                Profile           = '$Profile'
                FailoverPriority  = '$FailoverPriority'
                ReplicateServices = '$ReplicateServices'
                CoreUrl           = '$CoreUrl'
                MeshToken         = '$MeshToken'
                Force             = '$Force'
            }
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 4: VERIFY MESH MEMBERSHIP
        # ============================================================
        
        @{
            Name            = "Verify Mesh Health"
            Script          = "31-remote/3102_Watch-MeshFailover"
            Description     = "One-shot health check of all mesh nodes including new node"
            Parameters      = @{
                CoreUrl = '$CoreUrl'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 5: DATABASE REPLICATION
        # ============================================================
        
        @{
            Name            = "Configure Database Replication"
            Script          = "31-remote/3104_Setup-DatabaseReplication"
            Description     = "Set up PostgreSQL streaming replication, Redis replication, and Strata sync"
            Parameters      = @{
                CoreHost = '$CoreUrl'
                NodeHost = '$ComputerName'
                EnableSentinel = $true
                Force    = '$Force'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 6: START WATCHDOG (optional)
        # ============================================================
        
        @{
            Name            = "Start Failover Watchdog"
            Script          = "31-remote/3102_Watch-MeshFailover"
            Description     = "Start continuous failover monitoring (background)"
            Condition       = '$StartWatchdog -eq $true'
            Parameters      = @{
                CoreUrl              = '$CoreUrl'
                Continuous           = $true
                EnableFailback       = $true
                PollIntervalSeconds  = '$WatchdogInterval'
                FailureThreshold     = '$FailureThreshold'
            }
            ContinueOnError = $true
        }
    )
    
    OnSuccess = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║        🚀 HYPER-V NODE DEPLOYED SUCCESSFULLY 🚀                   ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  The AitherNode is now running on the remote host and has         ║
║  joined the AitherMesh for LAN hot failover.                      ║
║                                                                   ║
║  SERVICES DEPLOYED:                                               ║
║  ┌─────────────────────────────────────────────────────────────┐  ║
║  │  Genesis (8001) — Orchestrator                             │  ║
║  │  Pulse (8081)   — Health & state                           │  ║
║  │  Watch (8082)   — Service monitoring                       │  ║
║  │  Secrets (8111) — Credential vault                         │  ║
║  │  Chronicle (8121) — Logging                                │  ║
║  │  MeshCore (8125) — Mesh + failover                         │  ║
║  │  Strata (8136)  — Data & learning                          │  ║
║  │  MicroScheduler (8150) — LLM routing                       │  ║
║  │  Node (8080)    — MCP tools                                │  ║
║  └─────────────────────────────────────────────────────────────┘  ║
║                                                                   ║
║  FAILOVER:                                                        ║
║  ┌─────────────────────────────────────────────────────────────┐  ║
║  │  Replicated: Pulse, Chronicle, Strata                      │  ║
║  │  Failover threshold: 3 missed heartbeats                   │  ║
║  │  Recovery: Automatic failback when node returns            │  ║
║  └─────────────────────────────────────────────────────────────┘  ║
║                                                                   ║
║  VERIFY:                                                          ║
║    curl http://<node-ip>:8001/health                              ║
║    curl http://<node-ip>:8125/mesh/status                         ║
║                                                                   ║
║  MANAGE:                                                          ║
║    Invoke-AitherRemoteCommand <node> { docker ps }                ║
║    Invoke-AitherElysiumDeploy <node> -SkipBootstrap               ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    }
    
    OnFailure = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════════╗
║        ⚠️ HYPER-V NODE DEPLOYMENT FAILED ⚠️                       ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  Check the output above for specific errors.                      ║
║                                                                   ║
║  COMMON ISSUES:                                                   ║
║  ┌─────────────────────────────────────────────────────────────┐  ║
║  │  Cannot connect:                                           │  ║
║  │    → winrm quickconfig (on target)                         │  ║
║  │    → Set-Item WSMan:\localhost\Client\TrustedHosts "*"     │  ║
║  │                                                            │  ║
║  │  Hyper-V reboot required:                                  │  ║
║  │    → Restart the target, re-run with -SkipHyperV           │  ║
║  │                                                            │  ║
║  │  Docker failed:                                            │  ║
║  │    → Check Windows Containers feature is enabled           │  ║
║  │    → Check disk space (need 50GB+ free)                    │  ║
║  │                                                            │  ║
║  │  Mesh join failed:                                         │  ║
║  │    → Is AitherOS Core running locally?                     │  ║
║  │    → Check firewall allows port 8125 bidirectionally       │  ║
║  └─────────────────────────────────────────────────────────────┘  ║
║                                                                   ║
║  RETRY WITH SKIPS:                                                ║
║    Invoke-AitherElysiumDeploy <node> -SkipBootstrap               ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
"@
    }
}
