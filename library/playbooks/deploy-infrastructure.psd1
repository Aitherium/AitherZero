# deploy-infrastructure.psd1
# AitherZero Infrastructure Deployment Playbook
#
# Fully automated E2E infrastructure deployment from zero to running AitherOS VMs.
# Config-driven via config.psd1 Infrastructure section.
#
# Deploys Rocky Linux 9 VMs with Podman via OpenTofu + cloud-init.
# Every parameter is read from config.psd1 — zero manual steps required.
#
# Usage:
#   ./bootstrap.ps1 -InstallProfile Infrastructure          # Auto-invokes this playbook
#   ./bootstrap.ps1 -Playbook deploy-infrastructure          # Direct invocation
#   Invoke-AitherPlaybook deploy-infrastructure              # From loaded module
#   Invoke-AitherPlaybook deploy-infrastructure -Variables @{ AutoApprove = $true }

@{
    Name        = 'deploy-infrastructure'
    Version     = '2.0.0'
    Description = 'Deploy AitherOS infrastructure — Rocky Linux VMs via OpenTofu + Hyper-V + cloud-init'
    Author      = 'Aitherium'
    Category    = 'deploy'

    # Parameters — defaults read from config.psd1 Infrastructure section
    Parameters  = @{
        # Override target OS (default from config.psd1 Infrastructure.TargetOS)
        TargetOS        = ''
        # Auto-approve tofu apply (default from config.psd1 Infrastructure.TofuAutoApprove)
        AutoApprove     = $false
        # VM name override (default from first node in config.psd1 Infrastructure.Nodes)
        VMName          = ''
        # Cloud image override (default from config.psd1 Infrastructure.RockyLinux.CloudImagePath)
        ImagePath       = ''
        # SSH key override (default from config.psd1 Infrastructure.RockyLinux.SSHPublicKey)
        SSHPublicKey    = ''
        # Profile override (default from config.psd1 Infrastructure.RockyLinux.Profile)
        Profile         = ''
        # Skip to specific phase
        SkipValidation  = $false
        SkipInstalls    = $false
        # Use direct Hyper-V API instead of OpenTofu
        DirectDeploy    = $false
        DryRun          = $false
    }

    Prerequisites = @(
        "Windows 10/11 or Windows Server with Hyper-V capability"
        "Internet access for OpenTofu and cloud image download"
        "16 GB RAM minimum on host (32 GB recommended)"
        "100 GB free disk space"
        "config.psd1 Infrastructure section configured (or pass -Variables overrides)"
    )

    # Execution sequence (Invoke-AitherPlaybook reads 'Sequence', NOT 'Steps')
    Sequence    = @(
        # =====================================================================
        # PHASE 1: VALIDATE PREREQUISITES
        # =====================================================================
        @{
            Name            = 'Validate System Requirements'
            Script          = '01-infrastructure/0100_Validate-InfraPrerequisites'
            Description     = 'Check Hyper-V, OpenTofu, disk space, memory, and network'
            Parameters      = @{
                Scope       = 'All'
                AutoInstall = $true
            }
            ContinueOnError = $true
        },

        # =====================================================================
        # PHASE 2: INSTALL DEPENDENCIES
        # =====================================================================
        @{
            Name            = 'Install OpenTofu'
            Script          = '01-infrastructure/0102_Install-OpenTofu'
            Description     = 'Install OpenTofu IaC tool with Hyper-V provider plugin'
            Parameters      = @{ IncludeHyperVProvider = $true }
            ContinueOnError = $false
        },

        @{
            Name            = 'Enable Hyper-V'
            Script          = '01-infrastructure/0105_Enable-HyperV'
            Description     = 'Enable Hyper-V virtualization (may require reboot)'
            Parameters      = @{ SkipRebootCheck = $true }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 3: PREPARE CLOUD IMAGE
        # =====================================================================
        # Downloads Rocky Linux 9 GenericCloud qcow2, verifies checksum,
        # installs qemu-img, converts to VHDX, generates SSH key if needed.
        # Idempotent — skips if image already exists and is valid.
        @{
            Name            = 'Prepare Rocky Linux Cloud Image'
            Script          = '01-infrastructure/0311_Prepare-RockyLinuxImage'
            Description     = 'Download, verify, and convert Rocky Linux 9 cloud image to VHDX'
            Parameters      = @{
                UpdateConfig = $true
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 4: DEPLOY VM
        # =====================================================================
        # Reads all settings from config.psd1 Infrastructure section.
        # The 0310 script supports both OpenTofu and direct Hyper-V paths.
        @{
            Name            = 'Deploy AitherOS VM'
            Script          = '01-infrastructure/0310_Deploy-HypervVM'
            Description     = 'Provision Rocky Linux 9 VM with AitherOS via OpenTofu + cloud-init'
            Parameters      = @{
                # These pull from config.psd1 via variable interpolation
                # The playbook engine merges Parameters from config before passing
                VMName       = '$VMName'
                Template     = 'rocky'
                ImagePath    = '$ImagePath'
                Profile      = '$Profile'
                SSHPublicKey = '$SSHPublicKey'
                UseOpenTofu  = $true
                AutoStart    = $true
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 5: HEALTH VALIDATION
        # =====================================================================
        @{
            Name            = 'Verify Deployment Health'
            Script          = '0803_Get-AitherStatus'
            Description     = 'Verify AitherOS services are healthy in the deployed VM'
            ContinueOnError = $true
        }
    )
    
    # Success message
    OnSuccess   = @{
        Message = @"

=====================================================================
  INFRASTRUCTURE DEPLOYMENT COMPLETE
=====================================================================

  AitherOS is running in a Rocky Linux 9 Hyper-V VM.
  Full kernel isolation with Podman container orchestration inside.

  Access:
    SSH:            ssh aither@<vm-ip>
    Dashboard:      http://<vm-ip>:3000
    Genesis API:    http://<vm-ip>:8001
    Node (MCP):     http://<vm-ip>:8080
    Cockpit:        https://<vm-ip>:9090

  Management:
    Get-VM aither-rocky-* | Select State, Uptime, MemoryAssigned
    Invoke-AitherInfra -Action Status -Provider rocky-linux

  OpenTofu:
    cd AitherZero/library/infrastructure/environments/rocky-linux
    tofu plan       # Preview changes
    tofu destroy    # Tear down

  This was deployed from config.psd1 Infrastructure section.
  To redeploy: bootstrap.ps1 -InstallProfile Infrastructure

"@
    }

    OnFailure   = @{
        Message = @"

=====================================================================
  INFRASTRUCTURE DEPLOYMENT FAILED
=====================================================================

  Common fixes:
    1. Enable Hyper-V:  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
    2. Install OpenTofu: .\0102_Install-OpenTofu.ps1
    3. Prepare cloud image (auto downloads + converts):
       .\0311_Prepare-RockyLinuxImage.ps1 -UpdateConfig
    4. Or set manually in config.psd1:
       Infrastructure.RockyLinux.CloudImagePath = 'C:\Images\Rocky-9.vhdx'
    5. Check disk space (need 100 GB+)
    6. Check RAM (need 16 GB+)

  Retry:
    ./bootstrap.ps1 -InstallProfile Infrastructure
    # or
    Invoke-AitherPlaybook deploy-infrastructure

  Direct:
    .\0310_Deploy-HypervVM.ps1 -VMName aither-rocky-01 -Template rocky -ImagePath C:\Images\Rocky-9.vhdx

"@
    }
}
