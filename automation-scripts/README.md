# AitherZero Automation Scripts

This directory contains all automated installation, configuration, and lifecycle management scripts for the AitherOS platform.

## New Architecture (January 2026)

Scripts are now organized into **category-based directories** for better maintainability and clearer purpose.

### Directory Structure

```
automation-scripts/
 _archive/ # Archived legacy scripts (212+ scripts)
 _init.ps1 # Shared utilities and functions
 README.md # This file

 00-bootstrap/ # System bootstrap and prerequisites (9 scripts)
  0000_Bootstrap-AitherOS.ps1
  0001_Validate-Prerequisites.ps1
  0002_Install-PowerShell7.ps1
  0003_Install-Docker.ps1
  0005_Configure-Environment.ps1
  0006_Setup-GPUDependencies.ps1

 08-aitheros/ # AitherOS-specific config (1 script)
  0845_Setup-ScheduledBackups.ps1

 10-devtools/ # Dev tool installation (19 scripts)
  1001_Install-Chocolatey.ps1
  1002_Install-Git.ps1
  1003_Install-Node.ps1
  1004_Install-Python.ps1
  ...

 20-build/ # Container image builds (7 scripts)
  2001_Build-GenesisImage.ps1
  2002_Build-ServicesBase.ps1
  2003_Build-ServiceImages.ps1
  2005_Push-Images.ps1

 30-deploy/ # Deployment to various targets (11 scripts)
  3001_Deploy-LocalCompose.ps1
  3002_Deploy-K8sCluster.ps1
  3020_Deploy-OneClick.ps1
  3021_Install-Dependencies.ps1
  3022_Provision-Models.ps1

 40-lifecycle/ # Service lifecycle management (9 scripts)
  4001_Start-Genesis.ps1
  4002_Stop-Genesis.ps1
  4003_Restart-Services.ps1

 50-ai-setup/ # AI/ML setup: vLLM, ComfyUI, models (7 scripts)
  5001_Setup-vLLM.ps1
  5002_Provision-Models.ps1
  0850_Validate-ComfyUISetup.ps1
  0851_Setup-ComfyUIModels.ps1

 60-monitoring/ # Monitoring and observability (2 scripts)
  0650_Sync-Observability.ps1
  6001_Get-ServiceStatus.ps1

 60-security/ # Security configuration (5 scripts)
  0820_Setup-SecurityMesh.ps1
  6001_Add-Secret.ps1
  6002_List-Secrets.ps1

 70-external-integrations/ # External service integrations (2 scripts)

 70-git/ # Git and GitHub automation (2 scripts)
  0897_Import-RoadmapToGitHub.ps1
  0898_Submit-SessionLog.ps1

 70-maintenance/ # Maintenance and cleanup (4 scripts)
  7001_Cleanup-Docker.ps1
  7002_Validate-Environment.ps1
  9010_Scan-DiskUsage.ps1
  9020_Optimize-GPUMemory.ps1

 80-testing/ # Testing and validation (8 scripts)
  0402_Run-UnitTests.ps1
  0403_Run-IntegrationTests.ps1
  0404_Run-PSScriptAnalyzer.ps1
  8001_Test-ServiceHealth.ps1
  8010_Benchmark-InferenceModes.ps1
```

## Category Overview

| Category | Range | Purpose | Script Count |
|----------|-------|---------|--------------|
| 00-bootstrap | 0000-0011 | System prerequisites, Docker, K8s | 9 |
| 08-aitheros | 0845 | AitherOS-specific config | 1 |
| 10-devtools | 0769-1021 | Dev tool installation | 19 |
| 20-build | 2001-2011 | Container image building and pushing | 7 |
| 30-deploy | 3001-3022 | Deployment to various environments | 11 |
| 40-lifecycle | 4001-4008 | Service start/stop/restart/scale | 9 |
| 50-ai-setup | 0550-5002 | AI/ML tools: vLLM, ComfyUI, models | 7 |
| 60-monitoring | 0650-6001 | Observability, service status | 2 |
| 60-security | 0820-6003 | Secrets, security mesh | 5 |
| 70-external | varies | External integrations | 2 |
| 70-git | 0897-0898 | GitHub sync, session logging | 2 |
| 70-maintenance | 7001-9020 | Docker cleanup, GPU memory | 4 |
| 80-testing | 0402-8010 | Integration tests, benchmarks | 8 |

**Total: ~86 focused scripts** (vs. 212+ legacy scripts)

## Script Standards

### Metadata Header

Every script must include:

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
 Brief one-line description.

.DESCRIPTION
 Detailed description of what this script does.

.PARAMETER ConfigPath
 Path to configuration file.

.EXAMPLE
 .\0001_Validate-Prerequisites.ps1 -Verbose

.NOTES
 Category: bootstrap
 Dependencies: None
 Platform: Windows, Linux, macOS
#>
```

### Key Principles

1. **Idempotent**: Safe to run multiple times
2. **Cross-platform**: Support Windows, Linux, macOS where applicable
3. **Container-first**: All services run in containers
4. **Single responsibility**: Each script does one thing well
5. **Configurable**: Read settings from services.yaml and environment

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General failure |
| 2 | Prerequisites not met |
| 3 | Configuration error |
| 10 | Container build failure |
| 20 | Deployment failure |
| 30 | Service health check failure |

## Usage

### Via Playbooks (Recommended)

```powershell
# Full bootstrap
./bootstrap.ps1 -Playbook bootstrap

# Build containers
Invoke-AitherPlaybook -Name build

# Deploy locally
Invoke-AitherPlaybook -Name deploy-local

# Deploy to production
Invoke-AitherPlaybook -Name deploy-prod
```

### Direct Execution

```powershell
# Run a single script
& ".\00-bootstrap\0001_Validate-Prerequisites.ps1" -Verbose

# Run with configuration
& ".\30-deploy\3001_Deploy-LocalCompose.ps1" -Environment "development"
```

## Container Architecture

All AitherOS services run in containers:

- **Local Development**: Docker Compose
- **Production**: Kubernetes

### Key Containers

| Container | Purpose | Port |
|-----------|---------|------|
| genesis | Bootloader and orchestrator | 8001 |
| veil | Dashboard UI | 3000 |
| chronicle | Centralized logging | 8121 |
| vllm-orchestrator | General LLM (vLLM) | 8200 |
| vllm-reasoning | Deep reasoning LLM (vLLM) | 8201 |
| vllm-vision | Multimodal LLM (vLLM) | 8202 |
| vllm-coding | Code generation LLM (vLLM) | 8203 |
| canvas | ComfyUI image generation | 8108 |

## Legacy Scripts

All 212+ legacy scripts have been archived to `_archive/` for reference. Key functionality has been consolidated into the new category-based structure.

To reference old scripts:
```powershell
# View archived scripts
Get-ChildItem .\_archive\*.ps1 | Select-Object Name
```

## Adding New Scripts

1. Identify the appropriate category directory
2. Use the next available number in that category's range
3. Follow the naming convention: `NNNN_Verb-Noun.ps1`
4. Include the required metadata header
5. Make the script idempotent and cross-platform
6. Add to the appropriate playbook if needed
