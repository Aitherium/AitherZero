@{
    Name = "dev-environment"
    Description = "Complete development environment setup with custom paths on E:\ drive"
    Version = "1.0.0"
    Author = "AitherZero"
    
    # Master playbook for setting up a complete development environment
    # All tools install to E:\ drive per config.local.psd1
    # Uses Get-AitherPath for path resolution
    
    Parameters = @{
        # Core tools
        InstallPython = $true
        InstallNode = $true
        InstallGit = $true
        InstallDocker = $true
        InstallCosign = $true
        
        # AI/ML tools (vLLM runs via Docker, no native install needed)
        SetupvLLM = $false              # Start vLLM multi-model stack
        InstallComfyUI = $false          # Heavy, optional
        
        # Cloud/DevOps
        InstallKubectl = $false
        InstallHelm = $false
        InstallAwsCli = $false
        InstallAzureCli = $false
        
        # WSL Configuration
        SetupWsl = $true
        WslDistro = 'Ubuntu-24.04'
        
        # Cleanup C:\ drive first
        CleanupFirst = $false
        
        # Skip already installed
        SkipInstalled = $true
    }
    
    Prerequisites = @(
        "Windows 10/11 with winget"
        "Administrator privileges (for some features)"
        "E:\ drive with 100GB+ free space"
        "Internet connection"
    )
    
    Sequence = @(
        # ============================================================
        # PHASE 1: FOUNDATION
        # ============================================================
        
        @{
            Name = "System Information"
            Script = "0011_Get-SystemInfo"
            Description = "Gather system information for compatibility check"
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 2: WSL + DOCKER (if enabled)
        # ============================================================
        
        @{
            Name = "Setup WSL2"
            Script = "0214_Manage-WSL"
            Description = "Install and configure WSL2 for E:\ drive"
            Condition = '$SetupWsl -eq $true'
            Parameters = @{
                Action = 'Install'
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Configure WSL Settings"
            Script = "0214_Manage-WSL"
            Description = "Create optimized .wslconfig"
            Condition = '$SetupWsl -eq $true'
            Parameters = @{
                Action = 'Configure'
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Install Docker Desktop"
            Script = "0208_Install-Docker"
            Description = "Install Docker with custom data paths"
            Condition = '$InstallDocker -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 3: CORE DEVELOPMENT TOOLS
        # ============================================================
        
        @{
            Name = "Install Git"
            Script = "0207_Install-Git"
            Description = "Install Git version control"
            Condition = '$InstallGit -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Install Python"
            Script = "0206_Install-Python"
            Description = "Install Python with custom paths"
            Condition = '$InstallPython -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Install Node.js"
            Script = "0201_Install-NodeJS"
            Description = "Install Node.js runtime"
            Condition = '$InstallNode -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 4: AI/ML TOOLS
        # ============================================================
        
        @{
            Name = "Setup vLLM Multi-Model Stack"
            Script = "00-bootstrap/0000_Bootstrap-AitherOS"
            Description = "Start vLLM multi-model Docker stack for local LLM inference"
            Condition = '$SetupvLLM -eq $true'
            Parameters = @{
                Profile = 'core'
                SkipBuild = $true
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Install ComfyUI"
            Script = "0730_Install-ComfyUI"
            Description = "Install ComfyUI for image generation"
            Condition = '$InstallComfyUI -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 5: CLOUD/DEVOPS TOOLS (optional)
        # ============================================================
        
        @{
            Name = "Install kubectl"
            Script = "0220_Install-Kubectl"
            Description = "Install Kubernetes CLI"
            Condition = '$InstallKubectl -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Install Helm"
            Script = "0221_Install-Helm"
            Description = "Install Helm package manager"
            Condition = '$InstallHelm -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Install AWS CLI"
            Script = "0213_Install-AwsCli"
            Description = "Install AWS command line interface"
            Condition = '$InstallAwsCli -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Install Azure CLI"
            Script = "0212_Install-AzureCli"
            Description = "Install Azure command line interface"
            Condition = '$InstallAzureCli -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Install Cosign"
            Script = "1021_Install-Cosign"
            Description = "Install Cosign for container image signing"
            Condition = '$InstallCosign -eq $true'
            Parameters = @{
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 6: WSL DISTRO (if enabled)
        # ============================================================
        
        @{
            Name = "Install WSL Distribution"
            Script = "0214_Manage-WSL"
            Description = "Install Linux distribution to E:\WSL"
            Condition = '$SetupWsl -eq $true -and $WslDistro -ne $null'
            Parameters = @{
                Action = 'InstallDistro'
                Distro = '$WslDistro'
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        # ============================================================
        # PHASE 7: VERIFICATION
        # ============================================================
        
        @{
            Name = "Verify Installation"
            Script = "0906_Validate-Syntax"
            Description = "Validate AitherZero scripts are working"
            Parameters = @{
                Quick = '$true'
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        @{
            Name = "Show WSL Status"
            Script = "0214_Manage-WSL"
            Description = "Display final WSL and disk status"
            Parameters = @{
                Action = 'Status'
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
    )
    
    OnSuccess = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════╗
║        🚀 DEVELOPMENT ENVIRONMENT READY 🚀                    ║
╠═══════════════════════════════════════════════════════════════╣
║  All tools installed to E:\ drive!                            ║
║                                                               ║
║  INSTALLED TO:                                                ║
║  → E:\Apps\        - Application binaries                     ║
║  → E:\Data\        - Data directories                         ║
║  → E:\Models\      - AI models (vLLM, ComfyUI)              ║
║  → E:\WSL\         - WSL distributions                        ║
║                                                               ║
║  NEXT STEPS:                                                  ║
║  1. Open new terminal for PATH updates                        ║
║  2. Run: docker compose -f docker-compose.vllm-multimodel.yml up -d  ║
║  3. Run: ./Start-AitherZero.ps1                               ║
║                                                               ║
║  Your C:\ drive stays clean! 🎉                               ║
╚═══════════════════════════════════════════════════════════════╝
"@
    }
    
    OnFailure = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════╗
║        ⚠️ SOME INSTALLATIONS FAILED ⚠️                        ║
╠═══════════════════════════════════════════════════════════════╣
║  Some tools may not have installed correctly.                 ║
║  Check the output above for specific errors.                  ║
║                                                               ║
║  Common fixes:                                                ║
║  - Run as Administrator for system-wide installs              ║
║  - Check internet connectivity                                ║
║  - Update winget: winget upgrade --all                        ║
║  - Manual install if winget fails                             ║
╚═══════════════════════════════════════════════════════════════╝
"@
    }
}
