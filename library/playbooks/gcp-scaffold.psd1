# GCP Scaffold Playbook
# Automates complete GCP project setup for AitherOS deployment
#
# Usage: Invoke-AitherPlaybook -Name 'gcp-scaffold'
#
# This playbook creates a fully automated GCP deployment pipeline from scratch
# Supports 70+ containerized services via GKE or GCE deployment
#
# Deployment Options:
#   - GKE: Kubernetes cluster with GPU node pools for full AitherOS stack
#   - GCE: Individual VMs with role-based service configuration

@{
    Name        = 'gcp-scaffold'
    Description = 'Scaffold a complete GCP project for AitherOS deployment (70+ services) with CI/CD'
    Version     = '1.1.0'
    Author      = 'AitherZero'
    
    # Required parameters (prompted if not provided)
    Parameters  = @{
        ProjectId = @{
            Description = 'GCP Project ID'
            Required    = $true
            Prompt      = 'Enter your GCP Project ID'
        }
        Repository = @{
            Description = 'GitHub repository (owner/repo)'
            Required    = $true
            Default     = 'Aitherium/AitherOS'
            Prompt      = 'Enter GitHub repository (e.g., Aitherium/AitherOS)'
        }
        Region = @{
            Description = 'GCP region for deployment'
            Required    = $false
            Default     = 'us-central1'
        }
        Profile = @{
            Description = 'Deployment profile (minimal, demo, full)'
            Required    = $false
            Default     = 'minimal'
            ValidateSet = @('minimal', 'demo', 'full')
        }
        DeploymentType = @{
            Description = 'Deployment type (gke, gce)'
            Required    = $false
            Default     = 'gke'
            ValidateSet = @('gke', 'gce')
        }
        NodeRole = @{
            Description = 'Node role for GCE deployment (controller, gpu-worker, cpu-worker, edge)'
            Required    = $false
            Default     = 'controller'
            ValidateSet = @('controller', 'gpu-worker', 'cpu-worker', 'edge', 'full')
        }
        EnableGPU = @{
            Description = 'Enable GPU support (T4/A100)'
            Required    = $false
            Default     = $true
        }
        Environment = @{
            Description = 'Environment name (dev, staging, production)'
            Required    = $false
            Default     = 'dev'
            ValidateSet = @('dev', 'staging', 'production')
        }
        GeminiApiKey = @{
            Description = 'Google Gemini API key (optional)'
            Required    = $false
            Sensitive   = $true
        }
    }
    
    # Pre-flight checks
    Prerequisites = @(
        @{
            Name    = 'PowerShell 7+'
            Check   = { $PSVersionTable.PSVersion.Major -ge 7 }
            Message = 'PowerShell 7 or higher is required'
        }
        @{
            Name    = 'Git'
            Check   = { Get-Command git -ErrorAction SilentlyContinue }
            Message = 'Git is required. Install from https://git-scm.com'
        }
    )
    
    # Scripts to execute in order
    Scripts     = @(
        # Step 1: Install gcloud CLI if not present
        @{
            Number      = '0833'
            Name        = 'Install-GCloudCLI'
            Description = 'Install Google Cloud SDK'
            Condition   = { -not (Get-Command gcloud -ErrorAction SilentlyContinue) }
            Parameters  = @{}
        }
        
        # Step 2: Install OpenTofu if not present
        @{
            Number      = '0200'
            Name        = 'Install-OpenTofu'
            Description = 'Install OpenTofu for Infrastructure as Code'
            Condition   = { -not (Get-Command tofu -ErrorAction SilentlyContinue) }
            Parameters  = @{}
        }
        
        # Step 3: Setup GCP credentials and project
        @{
            Number      = '0832'
            Name        = 'Setup-GCPCredentials'
            Description = 'Authenticate with GCP and configure project'
            Parameters  = @{
                ProjectId = '$ProjectId'
                Region    = '$Region'
            }
        }
        
        # Step 4: Setup Cloud Build trigger
        @{
            Number      = '0834'
            Name        = 'Setup-CloudBuildTrigger'
            Description = 'Connect GitHub and create CI/CD trigger'
            Parameters  = @{
                ProjectId      = '$ProjectId'
                Repository     = '$Repository'
                Region         = '$Region'
                Environment    = '$Environment'
            }
        }
        
        # Step 5: Deploy infrastructure
        @{
            Number      = '0830'
            Name        = 'Deploy-AitherGCP'
            Description = 'Deploy AitherOS infrastructure to GCP'
            Parameters  = @{
                ProjectId   = '$ProjectId'
                Profile     = '$Profile'
                Region      = '$Region'
                Environment = '$Environment'
                GeminiApiKey = '$GeminiApiKey'
                AutoApprove = $true
            }
        }
        
        # Step 6: Deploy AitherOS Atomic (70+ services)
        @{
            Number      = '0836'
            Name        = 'Deploy-AitherOSAtomic'
            Description = 'Deploy AitherOS Atomic with 70+ containerized services'
            Condition   = { $DeploymentType -eq 'gke' }
            Parameters  = @{
                ProjectId      = '$ProjectId'
                Region         = '$Region'
                EnableGPU      = '$EnableGPU'
                ManifestPath   = 'AitherOS/AitherDesktop/atomic/cloud/k8s'
            }
        }
        
        # Step 7: Deploy GCE nodes (alternative to GKE)
        @{
            Number      = '0838'
            Name        = 'Deploy-AitherOSGCE'
            Description = 'Deploy AitherOS to GCE VMs'
            Condition   = { $DeploymentType -eq 'gce' }
            Parameters  = @{
                ProjectId   = '$ProjectId'
                Zone        = '${Region}-a'
                Role        = '$NodeRole'
                EnableGPU   = '$EnableGPU'
            }
        }
    )
    
    # Post-execution summary
    Summary     = @{
        SuccessMessage = @'
═══════════════════════════════════════════════════════════════════════════════
  ✅ GCP Project Scaffolded Successfully!
═══════════════════════════════════════════════════════════════════════════════

Your AitherOS deployment is now configured with:

  📦 Infrastructure:
     - VPC Network with private subnets
     - GKE cluster with GPU node pools OR GCE VMs
     - 70+ containerized AitherOS services
     - Artifact Registry for Docker images
     - Secret Manager for API keys
     
  🧠 AitherOS Services (70+):
     - Core: Chronicle, Pulse, Node, Watch, Secrets, Events, Strata, Veil
     - Intelligence: LLM, Mind, Reasoning, Judge, Flow, Will, Council, etc.
     - Perception: Vision, Voice, Portal, Sense, Browser, Reflex, TimeSense
     - Memory: WorkingMemory, Chain, Context, Spirit, Active, Conduit, etc.
     - GPU: Parallel, Accel, Exo, ExoNodes (with NVIDIA T4/A100)
     
  🔄 CI/CD Pipeline:
     - GitHub connected to Cloud Build
     - Auto-deploy on push to main branch
     - Docker images built and pushed automatically
     
  💰 Estimated Cost: $Profile profile
     - minimal: ~$30-50/month
     - demo: ~$80-120/month  
     - full: ~$250-400/month

  🚀 Next Steps:
     1. Push your code to main branch to trigger deployment
     2. View builds: https://console.cloud.google.com/cloud-build/builds?project=$ProjectId
     3. View services: https://console.cloud.google.com/run?project=$ProjectId
     
  🗑️ To tear down:
     .\0831_Destroy-AitherGCP.ps1 -ProjectId "$ProjectId" -Environment "$Environment"
     
═══════════════════════════════════════════════════════════════════════════════
'@
        FailureMessage = @'
═══════════════════════════════════════════════════════════════════════════════
  ❌ GCP Scaffold Failed
═══════════════════════════════════════════════════════════════════════════════

Please check the error messages above and try again.

Common issues:
  - GCP project doesn't exist or you don't have access
  - Billing not enabled on the project
  - APIs not enabled (script should enable them automatically)
  - GitHub App not installed on repository

For manual setup, run each script individually:
  1. .\0833_Install-GCloudCLI.ps1
  2. .\0832_Setup-GCPCredentials.ps1 -ProjectId "$ProjectId"
  3. .\0834_Setup-CloudBuildTrigger.ps1 -ProjectId "$ProjectId" -Repository "$Repository"
  4. .\0830_Deploy-AitherGCP.ps1 -ProjectId "$ProjectId" -Profile "$Profile"

═══════════════════════════════════════════════════════════════════════════════
'@
    }
}
