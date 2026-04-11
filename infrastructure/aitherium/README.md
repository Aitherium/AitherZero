# Aitherium Infrastructure Repository

Infrastructure-as-Code templates for deploying Aitherium/AitherOS across on-prem and cloud environments.

## Quick Start

```bash
# From AitherZero root
aitherzero 0109 # Clone this repo as submodule
aitherzero 0008 # Install OpenTofu
aitherzero 0300 # Deploy infrastructure
```

## Structure

```
aitherium/
 environments/ # Environment-specific configs
 dev/
 staging/
 production/
 modules/ # Reusable OpenTofu modules
 hyperv-vm/ # On-prem Hyper-V VMs
 gcp-cloudrun/ # GCP Cloud Run services
 aws-ecs/ # AWS ECS (future)
 azure-aci/ # Azure Container Instances
 kubernetes/ # K8s manifests
 docker/ # Container definitions
```

## Environments

| Environment | Purpose | Target |
|-------------|---------|--------|
| `dev` | Local development | Hyper-V, Docker |
| `staging` | Testing | GCP Cloud Run |
| `production` | Live services | GCP GKE or on-prem |

## Usage

### Deploy to Dev (On-Prem)
```bash
cd environments/dev
tofu init
tofu apply
```

### Deploy to Cloud
```bash
cd environments/staging
tofu init
tofu apply -var="project_id=your-gcp-project"
```

## Configuration

All deployments are config-driven via `terraform.tfvars`:

```hcl
# environments/dev/terraform.tfvars
environment = "dev"
hyperv_host = "localhost"
vm_count = 3
vm_memory_gb = 4
vm_cpus = 2
```

## Integration with AitherZero

This repo is designed to be used as a Git submodule:

1. Configure in `config.psd1`:
 ```powershell
 Infrastructure = @{
 Submodules = @{
 Default = @{
 Url = 'git@github.com:Aitherium/infrastructure.git'
 Path = 'infrastructure/aitherium'
 }
 }
 }
 ```

2. Run `aitherzero 0109` to clone
3. Run `aitherzero 0300` to deploy
