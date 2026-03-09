@{
    # =========================================================================
    # AITHEROS BOOTSTRAP PLAYBOOK
    # =========================================================================
    # Fresh system setup - installs all prerequisites and configures environment
    # Usage: ./bootstrap.ps1 -Playbook bootstrap
    # =========================================================================

    Name = "bootstrap"
    Description = "Fresh system bootstrap - installs Docker, Kubernetes tools, and configures environment"
    Version = "2.0.0"
    Author = "AitherZero"
    Category = "setup"

    # Parameters that can be overridden
    Parameters = @{
        InstallPowerShell7 = $true
        InstallDocker = $true
        InstallKubernetes = $true
        ConfigureEnvironment = $true
        CreateVenv = $true
        LocalCluster = "kind"  # kind, minikube, k3d, none
        BootAitherOS = $true   # Boot AitherOS after bootstrap completes
        AitherOSProfile = "core"  # Service profile: minimal, core, full
        SkipGPU = $false        # Skip GPU services (vLLM, ComfyUI)
    }

    # Prerequisites checked before running
    Prerequisites = @(
        "PowerShell 5.1+"
        "Internet connectivity"
        "Administrator/sudo access for installations"
    )

    # Playbook execution sequence
    Sequence = @(
        # =====================================================================
        # PHASE 1: VALIDATION
        # =====================================================================
        @{
            Name = "Validate Prerequisites"
            Script = "00-bootstrap/0001_Validate-Prerequisites"
            Description = "Check system requirements"
            Parameters = @{
                MinDiskSpaceGB = 50
                MinMemoryGB = 16
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 2: CORE RUNTIME
        # =====================================================================
        @{
            Name = "Install PowerShell 7"
            Script = "00-bootstrap/0002_Install-PowerShell7"
            Description = "Install or update PowerShell 7"
            Condition = '$InstallPowerShell7 -eq $true'
            ContinueOnError = $false
        },

        @{
            Name = "Install Docker"
            Script = "00-bootstrap/0003_Install-Docker"
            Description = "Install Docker container runtime"
            Condition = '$InstallDocker -eq $true'
            Parameters = @{
                Engine = "docker"
            }
            ContinueOnError = $false
        },

        @{
            Name = "Install Kubernetes Tools"
            Script = "00-bootstrap/0004_Install-Kubernetes"
            Description = "Install kubectl, helm, and local cluster tool"
            Condition = '$InstallKubernetes -eq $true'
            Parameters = @{
                LocalCluster = "kind"
                CreateCluster = $false
            }
            ContinueOnError = $true
        },

        # =====================================================================
        # PHASE 3: ENVIRONMENT SETUP
        # =====================================================================
        @{
            Name = "Configure Environment"
            Script = "00-bootstrap/0005_Configure-Environment"
            Description = "Create directories, set environment variables, configure shell"
            Condition = '$ConfigureEnvironment -eq $true'
            Parameters = @{
                CreateVenv = $true
                ConfigureShell = $true
            }
            ContinueOnError = $false
        },

        @{
            Name = "Install Testing Tools"
            Script = "10-devtools/1020_Install-TestingTools"
            Description = "Install Pester and PSScriptAnalyzer"
            ContinueOnError = $true
        },

        # =====================================================================
        # PHASE 4: BOOT AITHEROS (Optional)
        # =====================================================================
        @{
            Name = "Bootstrap AitherOS"
            Script = "00-bootstrap/0000_Bootstrap-AitherOS"
            Description = "Build and start AitherOS services (Genesis, Veil, vLLM, ComfyUI, all services)"
            Condition = '$BootAitherOS -eq $true'
            Parameters = @{
                Profile = "core"
                SkipBuild = $false
                SkipGPU = $false
            }
            ContinueOnError = $true  # Don't fail bootstrap if AitherOS boot fails
        }
    )

    # Success message
    OnSuccess = @{
        Message = @"

  ============================================================
  BOOTSTRAP COMPLETE!
  ============================================================

  Your system is now ready for AitherOS.

  Next steps:
    1. Restart your terminal to load new environment
    2. AitherOS should be running (if BootAitherOS was enabled)
    3. Access: http://localhost:3000 (Veil Dashboard)
    4. Access: http://localhost:8001 (Genesis API)

  To boot AitherOS manually:
    Invoke-AitherPlaybook -Name bootstrap -Variables @{ BootAitherOS = $true }

  To boot with different profile:
    Invoke-AitherPlaybook -Name bootstrap -Variables @{ BootAitherOS = $true; AitherOSProfile = "full" }

"@
    }

    # Failure message
    OnFailure = @{
        Message = @"

  ============================================================
  BOOTSTRAP FAILED
  ============================================================

  Please check the error messages above and resolve any issues.

  Common issues:
    - Docker not installed or not running
    - Insufficient disk space
    - Network connectivity problems

  For help, see: docs/troubleshooting.md

"@
    }
}
