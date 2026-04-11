# AitherOS GCP Deployment

Deploy the complete AitherOS ecosystem to Google Cloud Platform with one command.

## Quick Start

```powershell
# 1. Setup credentials (first time only)
.\AitherZero\library\automation-scripts\0832_Setup-GCPCredentials.ps1 -ProjectId YOUR_PROJECT_ID

# 2. Deploy (demo profile)
.\AitherZero\library\automation-scripts\0830_Deploy-AitherGCP.ps1 -Profile demo -ProjectId YOUR_PROJECT_ID

# 3. Open your dashboard
# URL will be printed after deployment completes
```

## Deployment Profiles

| Profile | Cost | Use Case | Includes |
|---------|------|----------|----------|
| **minimal** | ~$30-50/mo | Quick demos | Cloud Run (Veil + Node) |
| **demo** | ~$80-120/mo | Client demos | Cloud Run with higher resources |
| **full** | ~$250-400/mo | Production | GKE + GPU + Ollama + ComfyUI |

## Prerequisites

1. **GCP Account** with billing enabled
2. **gcloud CLI** installed: <https://cloud.google.com/sdk/docs/install>
3. **OpenTofu** (auto-installed if missing)
4. **Docker** (only if building images locally)

## Commands

### Deploy

```powershell
# Minimal (cheapest)
.\0830_Deploy-AitherGCP.ps1 -Profile minimal -ProjectId my-project

# Demo (recommended for demos)
.\0830_Deploy-AitherGCP.ps1 -Profile demo -ProjectId my-project -BuildImages

# Full (with GPU)
.\0830_Deploy-AitherGCP.ps1 -Profile full -ProjectId my-project -Environment production
```

### Destroy

```powershell
# Destroy dev environment
.\0831_Destroy-AitherGCP.ps1 -ProjectId my-project -Environment dev

# Force destroy (skip confirmation)
.\0831_Destroy-AitherGCP.ps1 -ProjectId my-project -AutoApprove
```

### Using Playbooks

```powershell
# Deploy via playbook
Invoke-AitherPlaybook -Name deploy-gcp -Parameters @{
 ProjectId = "my-project"
 Profile = "demo"
}

# Destroy via playbook
Invoke-AitherPlaybook -Name destroy-gcp -Parameters @{
 ProjectId = "my-project"
}
```

## What Gets Deployed

### Cloud Run (minimal/demo profiles)

```

 Google Cloud Run 

 AitherVeil (3000) AitherNode (8080) 
 Next.js Dashboard Python FastAPI + MCP 

 
 
 
 Secret Manager 
 (API Keys) 
 
```

### GKE (full profile)

```

 GKE Autopilot 

 
 Veil Node Ollama ComfyUI 
 
 
 
 GPU Node Pool (T4) 
 

```

## Environment Variables

Set these before deployment or pass via `-var`:

```powershell
$env:GEMINI_API_KEY = "your-gemini-key"
$env:OPENAI_API_KEY = "your-openai-key" # Optional
```

## Troubleshooting

### "Permission denied"

```powershell
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### "Billing not enabled"

Enable billing at: <https://console.cloud.google.com/billing>

### "Quota exceeded"

Request quota increase at: <https://console.cloud.google.com/iam-admin/quotas>

### View Logs

```bash
gcloud run logs read --service aither-veil-dev
gcloud run logs read --service aither-node-dev
```

## Cost Breakdown

### Minimal Profile (~$30-50/mo)

| Service | Cost |
|---------|------|
| Cloud Run (Veil) | $5-10 |
| Cloud Run (Node) | $10-20 |
| VPC Connector | $10 |
| Artifact Registry | $1-5 |
| Secret Manager | $0.50 |
| **Total** | **$30-50** |

### Demo Profile (~$80-120/mo)

| Service | Cost |
|---------|------|
| Cloud Run (Veil) | $10-20 |
| Cloud Run (Node) | $20-40 |
| Cloud Run (Services) | $20-40 |
| VPC Connector | $10-15 |
| Artifact Registry | $5-10 |
| **Total** | **$80-120** |

### Full Profile (~$250-400/mo)

| Service | Cost |
|---------|------|
| GKE Cluster | $70-100 |
| GPU Node Pool | $150-250 |
| Persistent Disks | $10-20 |
| Load Balancer | $20-30 |
| Artifact Registry | $10-20 |
| **Total** | **$250-400** |

## Files

```
AitherZero/library/
 infrastructure/modules/gcp/
 main.tf # Root module
 variables.tf # Input variables
 outputs.tf # Output values
 backend.tf # State configuration
 profiles/
 minimal.tfvars # Minimal profile
 demo.tfvars # Demo profile
 full.tfvars # Full profile
 modules/
 network/ # VPC, subnets, NAT
 cloudrun/ # Cloud Run services
 gke/ # GKE cluster + GPU
 automation-scripts/
 0830_Deploy-AitherGCP.ps1
 0831_Destroy-AitherGCP.ps1
 0832_Setup-GCPCredentials.ps1
 playbooks/
 deploy-gcp.psd1
 destroy-gcp.psd1
```
