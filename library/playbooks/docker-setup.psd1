@{
    Name = "docker-setup"
    Description = "Complete Docker Desktop + WSL2 setup with custom paths on E:\ drive"
    Version = "1.0.0"
    Author = "AitherZero"
    
    # This playbook ensures Docker and WSL are properly configured to use
    # the E:\ drive instead of filling up C:\. It handles:
    # - WSL2 installation and configuration
    # - Docker Desktop installation
    # - Moving WSL distros to E:\WSL
    # - Setting up .wslconfig for optimal performance
    
    Parameters = @{
        WslPath = 'E:\WSL'              # Where to store WSL distros
        DockerDataPath = 'E:\Data\Docker'  # Docker data location
        SkipWslInstall = $false         # Skip WSL installation (already installed)
        SkipDockerInstall = $false      # Skip Docker installation (already installed)
        CleanupFirst = $false           # Remove existing WSL distros before setup
        InstallDistro = 'Ubuntu-24.04'  # Linux distro to install (or $null for none)
    }
    
    Prerequisites = @(
        "Windows 10 version 2004+ or Windows 11"
        "Administrator privileges (for WSL feature)"
        "Virtualization enabled in BIOS"
        "E:\ drive with 50GB+ free space"
    )
    
    Sequence = @(
        # Phase 1: Cleanup (optional)
        @{
            Name = "Cleanup Existing WSL"
            Script = "0214_Manage-WSL"
            Description = "Remove all existing WSL distros and free C:\ drive space"
            Condition = '$CleanupFirst -eq $true'
            Parameters = @{
                Action = 'Cleanup'
                Force = '$true'
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        # Phase 2: Install/Configure WSL2
        @{
            Name = "Install and Configure WSL2"
            Script = "0214_Manage-WSL"
            Description = "Install WSL2 Windows feature and create optimized .wslconfig"
            Condition = '$SkipWslInstall -eq $false'
            Parameters = @{
                Action = 'Install'
                Path = '$WslPath'
                ShowOutput = '$true'
            }
            ContinueOnError = $false
        }
        
        # Phase 3: Configure WSL settings
        @{
            Name = "Configure WSL Settings"
            Script = "0214_Manage-WSL"
            Description = "Set up .wslconfig with custom swap location and memory limits"
            Parameters = @{
                Action = 'Configure'
                Path = '$WslPath'
                ShowOutput = '$true'
            }
            ContinueOnError = $false
        }
        
        # Phase 4: Install Docker Desktop
        @{
            Name = "Install Docker Desktop"
            Script = "0208_Install-Docker"
            Description = "Install Docker Desktop with custom data paths"
            Condition = '$SkipDockerInstall -eq $false'
            Parameters = @{
                DataPath = '$DockerDataPath'
                WslDiskPath = '$WslPath'
                ShowOutput = '$true'
            }
            ContinueOnError = $false
        }
        
        # Phase 5: Install Linux Distro (optional)
        @{
            Name = "Install Linux Distribution"
            Script = "0214_Manage-WSL"
            Description = "Install a Linux distribution to the custom path"
            Condition = '$InstallDistro -ne $null -and $InstallDistro -ne ""'
            Parameters = @{
                Action = 'InstallDistro'
                Distro = '$InstallDistro'
                Path = '$WslPath'
                ShowOutput = '$true'
            }
            ContinueOnError = $true
        }
        
        # Phase 6: Show final status
        @{
            Name = "Verify Setup"
            Script = "0214_Manage-WSL"
            Description = "Display WSL status and disk usage"
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
║           🐳 DOCKER + WSL SETUP COMPLETE 🐳                   ║
╠═══════════════════════════════════════════════════════════════╣
║  WSL2 and Docker Desktop are configured for E:\ drive!        ║
║                                                               ║
║  PATHS CONFIGURED:                                            ║
║  → WSL Distros:     E:\WSL\                                   ║
║  → Docker Data:     E:\Data\Docker\                           ║
║  → WSL Swap:        E:\WSL\swap.vhdx                          ║
║  → .wslconfig:      ~/.wslconfig (optimized)                  ║
║                                                               ║
║  NEXT STEPS:                                                  ║
║  1. Start Docker Desktop from Start Menu                      ║
║  2. Wait for initialization (creates docker-desktop distros)  ║
║  3. Run playbook again with -CleanupFirst to relocate         ║
║     Docker's WSL distros to E:\WSL                            ║
║                                                               ║
║  Or manually: wsl --export docker-desktop-data ...            ║
╚═══════════════════════════════════════════════════════════════╝
"@
    }
    
    OnFailure = @{
        Message = @"

╔═══════════════════════════════════════════════════════════════╗
║           ⚠️ DOCKER + WSL SETUP FAILED ⚠️                     ║
╠═══════════════════════════════════════════════════════════════╣
║  Check logs for details.                                      ║
║                                                               ║
║  Common issues:                                               ║
║  - Virtualization not enabled in BIOS                         ║
║  - Windows version too old (need 2004+)                       ║
║  - Administrator privileges required                          ║
║  - WSL update needed: wsl --update                            ║
║                                                               ║
║  Try: wsl --install --web-download                            ║
╚═══════════════════════════════════════════════════════════════╝
"@
    }
}
