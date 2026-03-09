# build-iso-pipeline.psd1
# AitherZero Automated ISO Build & Deploy Pipeline
#
# Full E2E automation: Prerequisites → Build ISO → Deploy VMs → Configure
# All dependencies are auto-resolved — zero manual setup required.
# Config-driven via infrastructure.psd1

@{
    Name        = 'build-iso-pipeline'
    Version     = '2.0.0'
    Description = 'Build custom AitherOS Windows Server ISO and deploy Hyper-V nodes with auto-dependency resolution'
    Author      = 'Aitherium'
    
    Parameters  = @{
        SourceISO = @{
            Type        = 'String'
            Default     = ''
            Description = 'Path to stock Windows Server 2025 ISO. Required for ISO build.'
        }
        
        NodeName = @{
            Type        = 'String'
            Default     = 'aither-node-01'
            Description = 'Name for the VM node to create'
        }
        
        NodeCount = @{
            Type    = 'Int'
            Default = 1
            Description = 'Number of identical nodes to deploy'
        }
        
        Profile = @{
            Type        = 'String'
            Default     = 'Core'
            ValidValues = @('Full', 'Core', 'Minimal', 'GPU', 'Edge')
            Description = 'AitherOS deployment profile'
        }
        
        SkipISOBuild = @{
            Type    = 'Switch'
            Default = $false
            Description = 'Skip ISO build (use existing ISO)'
        }
        
        SkipDeploy = @{
            Type    = 'Switch'
            Default = $false
            Description = 'Build ISO only — do not deploy VMs'
        }
        
        AutoApprove = @{
            Type    = 'Switch'
            Default = $false
            Description = 'Auto-approve OpenTofu apply without interactive confirmation'
        }
    }
    
    Prerequisites = @(
        'Windows 10/11 or Windows Server 2019+ (x64)',
        'Administrator privileges',
        'Internet access (for downloading tools)',
        'Stock Windows Server 2025 ISO (for build phase)',
        'All tool dependencies are auto-installed by Phase 1'
    )
    
    Steps       = @(
        # ============================================================
        # PHASE 1: AUTO-RESOLVE ALL PREREQUISITES
        # ============================================================
        
        @{
            Name            = 'Validate Infrastructure Prerequisites'
            Script          = '01-infrastructure/0100_Validate-InfraPrerequisites'
            Description     = 'Check all prerequisites and report status'
            Parameters      = @{ Scope = 'All' }
            ContinueOnError = $true
        }
        
        @{
            Name            = 'Install Windows ADK'
            Script          = '01-infrastructure/0101_Install-WindowsADK'
            Description     = 'Install Windows ADK (oscdimg.exe) for ISO building'
            Condition       = '$SkipISOBuild -ne $true -and -not (Get-Command oscdimg -ErrorAction SilentlyContinue) -and -not $env:OSCDIMG_PATH'
            Parameters      = @{}
            ContinueOnError = $false
        }
        
        @{
            Name            = 'Install OpenTofu'
            Script          = '01-infrastructure/0102_Install-OpenTofu'
            Description     = 'Install OpenTofu for Hyper-V VM provisioning'
            Condition       = '$SkipDeploy -ne $true -and -not (Get-Command tofu -ErrorAction SilentlyContinue) -and -not (Get-Command terraform -ErrorAction SilentlyContinue)'
            Parameters      = @{ IncludeHyperVProvider = $true }
            ContinueOnError = $false
        }
        
        @{
            Name            = 'Enable Hyper-V'
            Script          = '01-infrastructure/0105_Enable-HyperV'
            Description     = 'Enable Hyper-V virtualization role (may require reboot)'
            Condition       = '$SkipDeploy -ne $true'
            Parameters      = @{}
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 2: BUILD CUSTOM ISO
        # ============================================================
        
        @{
            Name            = 'Build AitherOS ISO'
            Script          = '31-remote/3105_Build-WindowsISO'
            Description     = 'Build custom Windows Server 2025 Core ISO with AitherOS bootstrap'
            Condition       = '$SkipISOBuild -ne $true'
            Parameters      = @{
                SourceISO   = '$SourceISO'
                NodeProfile = '$Profile'
            }
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 3: DEPLOY VMs
        # ============================================================
        
        @{
            Name            = 'Setup Hyper-V Host'
            Script          = '31-remote/3100_Setup-HyperVHost'
            Description     = 'Configure Hyper-V virtual switch and host settings'
            Condition       = '$SkipDeploy -ne $true'
            Parameters      = @{}
            ContinueOnError = $false
        }
        
        @{
            Name            = 'Deploy Nodes via OpenTofu'
            Script          = '31-remote/3101_Deploy-RemoteNode'
            Description     = 'Run tofu init + apply to create Hyper-V VMs'
            Condition       = '$SkipDeploy -ne $true'
            Parameters      = @{
                Profile = '$Profile'
            }
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 4: POST-INSTALL
        # ============================================================
        
        @{
            Name            = 'Configure Mesh Watchdog'
            Script          = '31-remote/3102_Watch-MeshFailover'
            Description     = 'Start mesh watchdog for the new node(s)'
            Condition       = '$SkipDeploy -ne $true'
            Parameters      = @{}
            ContinueOnError = $true
        }
    )
    
    OnSuccess   = @"

╔══════════════════════════════════════════════════════════════════════╗
║           AitherOS ISO BUILD & DEPLOY COMPLETE                       ║
╚══════════════════════════════════════════════════════════════════════╝

Your AitherOS node(s) are deployed and running!

The pipeline has:
  ✓ Installed all prerequisites (ADK, OpenTofu, Hyper-V)
  ✓ Built a custom Windows Server 2025 Core ISO
  ✓ Deployed Hyper-V VM(s) via OpenTofu
  ✓ Configured mesh watchdog

Next steps:
  1. Check status:     Get-AitherInfraStatus
  2. View mesh:        Get-AitherMeshStatus -Action Status
  3. Manage fleet:     Invoke-AitherNodeDeploy -Action Status
  4. Destroy VMs:      New-AitherWindowsISO -SkipISOBuild -Force (to rebuild)

"@
    
    OnFailure   = @"

╔══════════════════════════════════════════════════════════════════════╗
║           AitherOS ISO PIPELINE FAILED                                ║
╚══════════════════════════════════════════════════════════════════════╝

Troubleshooting:
  1. Re-run prereq check:  .\01-infrastructure\0100_Validate-InfraPrerequisites.ps1
  2. If Hyper-V needs reboot: restart and re-run playbook
  3. Check ISO source path is valid
  4. Ensure sufficient disk space (50GB+ recommended)
  5. Review logs for detailed errors

Manual recovery:
  Resolve-AitherInfraPrereqs -Scope All
  New-AitherWindowsISO -SourceISO 'C:\ISOs\Server2025.iso' -TofuAutoApprove
  ./0195_Inject-ISO-Artifacts.ps1 -IsoPath <path> -Platform <os> -ShowOutput

"@
}
