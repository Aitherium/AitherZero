@{
    # =========================================================================
    # AITHEROS ROCKY LINUX DEPLOYMENT PLAYBOOK
    # =========================================================================
    # Full sovereign node deployment on Rocky Linux 9 / RHEL 9.
    #
    # Supports three modes:
    #   pull   - Download pre-built images from GHCR (fastest)
    #   build  - Clone repo + build locally
    #   hybrid - Pull base images, build services locally
    #
    # Usage:
    #   Invoke-AitherPlaybook deploy-rocky-linux
    #   Invoke-AitherPlaybook deploy-rocky-linux -Variables @{ Mode = "pull"; Profile = "full"; GPU = $true }
    #   Invoke-AitherPlaybook deploy-rocky-linux -Variables @{ TargetHost = "10.0.1.50"; Mode = "build" }
    # =========================================================================

    Name        = "deploy-rocky-linux"
    Description = "Deploy AitherOS to Rocky Linux 9 — pull from GHCR or build from source, with systemd + Podman"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "deploy"

    Parameters = @{
        # Target machine (empty = local deploy)
        TargetHost     = ''
        UserName       = 'root'
        IdentityFile   = ''

        # Deployment mode
        Mode           = 'pull'       # pull | build | hybrid
        Profile        = 'standard'   # minimal | core | standard | full | gpu
        Tag            = 'latest'
        Registry       = 'ghcr.io/aitherium'

        # Options
        GPU            = $false
        SkipModels     = $false
        NonInteractive = '$env:CI -eq "true"'
        DryRun         = $false
    }

    Prerequisites = @(
        "Rocky Linux 9, AlmaLinux 9, RHEL 9, or CentOS Stream 9"
        "SSH access to target (or run locally with -Local)"
        "Internet access for package downloads and GHCR pulls"
        "32 GB RAM, 100 GB disk recommended"
        "NVIDIA GPU + drivers (optional, for GPU profile)"
    )

    Sequence = @(
        # =====================================================================
        # PHASE 1: SYSTEM VALIDATION
        # =====================================================================
        @{
            Name            = "Validate Prerequisites"
            Script          = "00-bootstrap/0001_Validate-Prerequisites"
            Description     = "Verify SSH connectivity and minimum system requirements"
            Parameters      = @{
                MinDiskSpaceGB = 50
                MinMemoryGB    = 16
            }
            ContinueOnError = $true
        },

        # =====================================================================
        # PHASE 2: FULL ROCKY LINUX DEPLOYMENT
        # =====================================================================
        @{
            Name            = "Deploy to Rocky Linux"
            Script          = "30-deploy/3060_Deploy-RockyLinux"
            Description     = "Install packages, create user, deploy images, configure systemd, start services"
            Parameters      = @{
                TargetHost     = '$TargetHost'
                UserName       = '$UserName'
                IdentityFile   = '$IdentityFile'
                Mode           = '$Mode'
                Profile        = '$Profile'
                Tag            = '$Tag'
                Registry       = '$Registry'
                GPU            = '$GPU'
                SkipModels     = '$SkipModels'
                NonInteractive = '$NonInteractive'
                DryRun         = '$DryRun'
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 3: POST-INSTALL
        # =====================================================================
        @{
            Name            = "Post-Install Provisioning"
            Script          = "30-deploy/3034_Post-Install"
            Description     = "Seed RBAC users/roles and ingest knowledge"
            ContinueOnError = $true
        },

        # =====================================================================
        # PHASE 4: HEALTH VALIDATION
        # =====================================================================
        @{
            Name            = "Full Health Check"
            Script          = "0803_Get-AitherStatus"
            Description     = "Verify all deployed services are healthy"
            ContinueOnError = $true
        }
    )

    OnSuccess = @{
        Message = @"

=====================================================================
  ROCKY LINUX DEPLOYMENT COMPLETE
=====================================================================

  AitherOS is running as systemd services via Podman.

  Access points:
    Dashboard:      http://<host>:3000
    Genesis API:    http://<host>:8001
    Node (MCP):     http://<host>:8080
    Sovereign Node: http://<host>:8139
    Cockpit:        https://<host>:9090

  Management (on the target):
    aitheros-ctl status       Show service status
    aitheros-ctl health       Run health checks
    aitheros-ctl sovereign    Sovereign node control
    aitheros-ctl logs genesis Follow Genesis logs
    aitheros-ctl backup       Backup all data
    aitheros-ctl update       Pull + restart

  systemd targets:
    systemctl --user start aitheros.target        All services
    systemctl --user start aitheros-core.target    Core only
    systemctl --user stop aitheros.target          Stop all

"@
    }

    OnFailure = @{
        Message = @"

=====================================================================
  ROCKY LINUX DEPLOYMENT FAILED
=====================================================================

  Check the output above for specific error messages.

  Common fixes:
    1. Verify SSH connectivity: ssh user@host 'echo ok'
    2. Ensure Rocky Linux 9 (cat /etc/os-release)
    3. Check disk space: df -h (need 50 GB+)
    4. Check RAM: free -h (need 16 GB+)
    5. For GPU: verify nvidia-smi works on target

  Retry:
    Invoke-AitherPlaybook deploy-rocky-linux
    # or
    .\3060_Deploy-RockyLinux.ps1 -TargetHost <host> -Mode pull

  Troubleshooting:
    See deploy/rocky-linux/README.md

"@
    }
}
