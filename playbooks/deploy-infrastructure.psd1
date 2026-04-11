# deploy-infrastructure.psd1
# AitherZero Infrastructure Deployment Playbook
#
# Headless E2E infrastructure deployment from zero to running VMs.
# Config-driven via config.psd1 Infrastructure section.
#
# Usage:
#   aitherzero -Playbook deploy-infrastructure
#   ./bootstrap.ps1 -Playbook deploy-infrastructure

@{
    Name        = 'deploy-infrastructure'
    Version     = '1.0.0'
    Description = 'Deploy infrastructure from zero using OpenTofu and Taliesin Hyper-V provider'
    Author      = 'Aitherium'
    
    # Parameters settable via config.psd1 or command line
    Parameters  = @{
        # Target environment - matches Infrastructure.Targets in config.psd1
        Target = @{
            Type        = 'String'
            Default     = 'OnPrem'
            ValidValues = @('OnPrem', 'Cloud', 'Both')
            Description = 'Deployment target: OnPrem (Hyper-V), Cloud (GCP/AWS/Azure), or Both'
        }
        
        # Auto-approve deployment (skip confirmation)
        AutoApprove = @{
            Type    = 'Switch'
            Default = $false
            Description = 'Skip confirmation prompts (for CI/CD)'
        }
        
        # Hyper-V host override
        HyperVHost = @{
            Type    = 'String'
            Default = ''
            Description = 'Override Hyper-V host from config'
        }
        
        # Skip provider setup (if already done)
        SkipProviderSetup = @{
            Type    = 'Switch'
            Default = $false
            Description = 'Skip Taliesin provider setup'
        }
    }
    
    # Conditions for when this playbook should run
    Condition   = '$config.Infrastructure.Enabled -eq $true'
    
    # Execution steps - run in order
    Steps       = @(
        # ============================================================
        # PHASE 1: SYSTEM PREREQUISITES
        # ============================================================
        
        @{
            Name        = 'Validate System Requirements'
            Script      = '01-infrastructure/0100_Validate-InfraPrerequisites'
            Description = 'Check all infrastructure prerequisites and report status'
            Parameters  = @{ Scope = 'All'; AutoInstall = $false }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 2: AUTO-INSTALL DEPENDENCIES
        # ============================================================
        
        @{
            Name        = 'Install OpenTofu'
            Script      = '01-infrastructure/0102_Install-OpenTofu'
            Description = 'Install OpenTofu infrastructure-as-code tool with Hyper-V provider'
            Condition   = '(Get-Command tofu -ErrorAction SilentlyContinue) -eq $null -and (Get-Command terraform -ErrorAction SilentlyContinue) -eq $null'
            Parameters  = @{ IncludeHyperVProvider = $true }
            ContinueOnError = $false
        }
        
        @{
            Name        = 'Enable Hyper-V'
            Script      = '01-infrastructure/0105_Enable-HyperV'
            Description = 'Enable Hyper-V virtualization feature (may require reboot)'
            Condition   = '$Target -ne "Cloud"'
            Parameters  = @{}
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 3: REMOTE ACCESS & SECURITY
        # ============================================================
        
        @{
            Name        = 'Configure Remote Access'
            Script      = '00-bootstrap/0008_Setup-RemoteAccess'
            Description = 'Configure WinRM, PSRemoting, and firewall for remote management'
            Condition   = '$Target -ne "Cloud"'
            Parameters  = @{}
            ContinueOnError = $false
        }
        
        # ============================================================
        # PHASE 4: INITIALIZE AND DEPLOY
        # ============================================================
        
        @{
            Name        = 'Deploy Infrastructure'
            Script      = '31-remote/3101_Deploy-RemoteNode'
            Description = 'Deploy VMs using OpenTofu and configure for AitherOS'
            Parameters  = @{}
            ContinueOnError = $false
        }
    )
    
    # Success message
    OnSuccess   = @"

╔══════════════════════════════════════════════════════════════════════╗
║           INFRASTRUCTURE DEPLOYMENT COMPLETE                          ║
╚══════════════════════════════════════════════════════════════════════╝

Your infrastructure has been deployed successfully!

Next steps:
  1. Check VM status:     aitherzero 0012
  2. Connect to VMs:      Enter-PSSession -ComputerName <VM-IP>
  3. Deploy AitherOS:     aitherzero -Playbook genesis-bootstrap

For cleanup:
  tofu destroy -auto-approve (in infrastructure directory)

"@
    
    # Failure message
    OnFailure   = @"

╔══════════════════════════════════════════════════════════════════════╗
║           INFRASTRUCTURE DEPLOYMENT FAILED                            ║
╚══════════════════════════════════════════════════════════════════════╝

Troubleshooting:
  1. Check WinRM on Hyper-V host:  winrm quickconfig
  2. Verify credentials in terraform.tfvars
  3. Check Hyper-V host connectivity
  4. Review logs in: ./logs/

Manual recovery:
  cd infrastructure/tofu-base-lab
  tofu init
  tofu validate
  tofu plan

"@
}
