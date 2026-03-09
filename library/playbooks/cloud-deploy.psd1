# AitherOS Cloud Deployment Playbook
# Deploys AitherOS to cloud infrastructure (GCP, Hyper-V)
#
# Usage:
#   Invoke-AitherPlaybook -Name cloud-deploy -PlaybookParams @{ Target = 'gke' }
#   Invoke-AitherPlaybook -Name cloud-deploy -PlaybookParams @{ Target = 'hyperv'; Role = 'gpu-worker' }
#
# Targets:
#   - gke: Google Kubernetes Engine
#   - gce: Google Compute Engine
#   - hyperv: Microsoft Hyper-V

@{
    Name = 'cloud-deploy'
    Description = 'Deploy AitherOS (70+ services) to cloud infrastructure'
    Version = '1.0.0'
    Author = 'Aitherium'

    # Default profile
    DefaultProfile = 'gke'

    # Available profiles
    Profiles = @{
        gke = @{
            Description = 'Deploy to Google Kubernetes Engine'
            Variables = @{
                Target = 'gke'
                GPUEnabled = $true
                AutoScale = $true
            }
        }
        gce = @{
            Description = 'Deploy to Google Compute Engine VMs'
            Variables = @{
                Target = 'gce'
                GPUEnabled = $true
                MachineType = 'n2-standard-8'
            }
        }
        hyperv = @{
            Description = 'Deploy to local Hyper-V'
            Variables = @{
                Target = 'hyperv'
                GPUEnabled = $false
                MemoryGB = 16
                ProcessorCount = 8
            }
        }
        'hyperv-gpu' = @{
            Description = 'Deploy to Hyper-V with GPU passthrough'
            Variables = @{
                Target = 'hyperv'
                GPUEnabled = $true
                MemoryGB = 32
                ProcessorCount = 8
            }
        }
    }

    # Parameters
    Parameters = @{
        Target = @{
            Type = 'string'
            Description = 'Deployment target (gke, gce, hyperv)'
            Required = $true
            ValidateSet = @('gke', 'gce', 'hyperv')
        }
        Role = @{
            Type = 'string'
            Description = 'Node role (controller, gpu-worker, cpu-worker, edge, full)'
            Required = $false
            Default = 'full'
            ValidateSet = @('controller', 'gpu-worker', 'cpu-worker', 'edge', 'full')
        }
        ProjectId = @{
            Type = 'string'
            Description = 'GCP Project ID (required for GKE/GCE)'
            Required = $false
        }
        Region = @{
            Type = 'string'
            Description = 'GCP Region'
            Required = $false
            Default = 'us-central1'
        }
        Zone = @{
            Type = 'string'
            Description = 'GCP Zone (for GCE)'
            Required = $false
            Default = 'us-central1-a'
        }
        VMName = @{
            Type = 'string'
            Description = 'VM name (for Hyper-V/GCE)'
            Required = $false
        }
    }

    # Global variables
    Variables = @{
        Registry = 'ghcr.io/aitherium'
        Tag = 'latest'
        AtomicPath = 'AitherOS/AitherDesktop/atomic'
        ServiceCount = 70
    }

    # Prerequisites
    Prerequisites = @(
        @{
            Name = 'Podman Available'
            Check = { Get-Command podman -ErrorAction SilentlyContinue }
            Message = 'Podman is required for container operations'
        }
        @{
            Name = 'GCloud CLI (for GCP targets)'
            Check = { 
                param($Target) 
                if ($Target -in @('gke', 'gce')) { 
                    Get-Command gcloud -ErrorAction SilentlyContinue 
                } else { $true }
            }
            Message = 'Google Cloud SDK required for GCP deployment'
        }
        @{
            Name = 'Kubectl (for GKE)'
            Check = {
                param($Target)
                if ($Target -eq 'gke') {
                    Get-Command kubectl -ErrorAction SilentlyContinue
                } else { $true }
            }
            Message = 'kubectl required for GKE deployment'
        }
        @{
            Name = 'Hyper-V (for hyperv target)'
            Check = {
                param($Target)
                if ($Target -eq 'hyperv') {
                    (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue).State -eq 'Enabled'
                } else { $true }
            }
            Message = 'Hyper-V must be enabled for Hyper-V deployment'
        }
    )

    # Steps
    Steps = @(
        # =====================================================================
        # GKE Deployment Steps
        # =====================================================================
        @{
            Name = 'Authenticate with GCP'
            Script = '0832_Setup-GCPCredentials.ps1'
            Arguments = @{
                ProjectId = '{{ProjectId}}'
                Region = '{{Region}}'
            }
            Condition = '{{Target}} -in @("gke", "gce")'
        }

        @{
            Name = 'Create GKE Cluster'
            Script = '0835_Create-GKECluster.ps1'
            Arguments = @{
                ProjectId = '{{ProjectId}}'
                Region = '{{Region}}'
                EnableGPU = '{{GPUEnabled}}'
            }
            Condition = '{{Target}} -eq "gke"'
            DependsOn = 'Authenticate with GCP'
        }

        @{
            Name = 'Deploy Kubernetes Manifests'
            Script = '0836_Deploy-K8sManifests.ps1'
            Arguments = @{
                ManifestPath = '{{AtomicPath}}/cloud/k8s'
                Namespace = 'aitheros'
            }
            Condition = '{{Target}} -eq "gke"'
            DependsOn = 'Create GKE Cluster'
        }

        @{
            Name = 'Install NVIDIA GPU Plugin'
            Script = '0837_Install-NvidiaPlugin.ps1'
            Arguments = @{}
            Condition = '{{Target}} -eq "gke" -and {{GPUEnabled}} -eq $true'
            DependsOn = 'Create GKE Cluster'
        }

        # =====================================================================
        # GCE Deployment Steps
        # =====================================================================
        @{
            Name = 'Create GCE Instance'
            Script = '0838_Create-GCEInstance.ps1'
            Arguments = @{
                ProjectId = '{{ProjectId}}'
                Zone = '{{Zone}}'
                Role = '{{Role}}'
                MachineType = '{{MachineType}}'
                EnableGPU = '{{GPUEnabled}}'
            }
            Condition = '{{Target}} -eq "gce"'
            DependsOn = 'Authenticate with GCP'
        }

        @{
            Name = 'Configure GCE Instance'
            Script = '0839_Configure-GCEInstance.ps1'
            Arguments = @{
                Zone = '{{Zone}}'
                Role = '{{Role}}'
            }
            Condition = '{{Target}} -eq "gce"'
            DependsOn = 'Create GCE Instance'
        }

        # =====================================================================
        # Hyper-V Deployment Steps
        # =====================================================================
        @{
            Name = 'Validate Hyper-V Environment'
            Script = '0840_Validate-HyperV.ps1'
            Arguments = @{
                GPUPassthrough = '{{GPUEnabled}}'
            }
            Condition = '{{Target}} -eq "hyperv"'
        }

        @{
            Name = 'Create Hyper-V VM'
            Script = '0841_Create-HyperVVM.ps1'
            Arguments = @{
                Name = '{{VMName}}'
                Role = '{{Role}}'
                MemoryGB = '{{MemoryGB}}'
                ProcessorCount = '{{ProcessorCount}}'
                GPUPassthrough = '{{GPUEnabled}}'
            }
            Condition = '{{Target}} -eq "hyperv"'
            DependsOn = 'Validate Hyper-V Environment'
        }

        @{
            Name = 'Start Hyper-V VM'
            Script = '0842_Start-HyperVVM.ps1'
            Arguments = @{
                Name = '{{VMName}}'
                WaitForBoot = $true
            }
            Condition = '{{Target}} -eq "hyperv"'
            DependsOn = 'Create Hyper-V VM'
        }

        # =====================================================================
        # Common Post-Deployment
        # =====================================================================
        @{
            Name = 'Verify Deployment'
            Script = '0850_Verify-CloudDeployment.ps1'
            Arguments = @{
                Target = '{{Target}}'
                ExpectedServices = '{{ServiceCount}}'
            }
            Condition = 'Always'
            ContinueOnError = $true
        }

        @{
            Name = 'Generate Deployment Report'
            Script = '0851_Report-CloudDeployment.ps1'
            Arguments = @{
                Target = '{{Target}}'
                Role = '{{Role}}'
                OutputFormat = 'markdown'
            }
            Condition = 'Always'
            ContinueOnError = $true
        }
    )

    # Error handling
    OnError = @{
        Action = 'Stop'
        RetryCount = 1
        NotifyChannels = @('pulse')
    }

    # Post-completion
    OnComplete = @{
        NotifyChannels = @('pulse')
        CleanupTempFiles = $true
    }

    # Summary
    Summary = @{
        SuccessMessage = @'
═══════════════════════════════════════════════════════════════════════════════
  ✅ AitherOS Cloud Deployment Complete!
═══════════════════════════════════════════════════════════════════════════════

Deployment Summary:
  📦 Target:    {{Target}}
  🎭 Role:      {{Role}}
  📊 Services:  {{ServiceCount}} containerized services

Service Categories:
  - Core:         Chronicle, Pulse, Node, Watch, Secrets, Events, Strata, Veil
  - Intelligence: LLM, Mind, Reasoning, Judge, Flow, Will, Council, etc.
  - Perception:   Vision, Voice, Portal, Sense, Browser, Reflex, TimeSense
  - Memory:       WorkingMemory, Chain, Context, Spirit, Active, Conduit, etc.
  - Training:     Prism, Trainer, Harvest, Evolution
  - Autonomic:    Autonomic, Scheduler, Demand, Force, Sandbox, Scope
  - Security:     Identity, Recover, Sentry, Inspector, Flux, Chaos, Jail
  - Agents:       Demiurge, Orchestrator, Forge, Intent, Director
  - Gateway:      Gateway, A2A, Mesh, Deployer, AitherNet, Comet
  - GPU:          Parallel, Accel, Exo, ExoNodes
  - MCP:          MCPVision, MCPCanvas, MCPMind, MCPMemory

Next Steps:
  1. Access the dashboard at the displayed URL
  2. Configure API keys in Secrets Manager
  3. Start additional worker nodes for distributed workloads

═══════════════════════════════════════════════════════════════════════════════
'@
    }
}

