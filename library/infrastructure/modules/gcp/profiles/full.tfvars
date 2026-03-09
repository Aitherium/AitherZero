# =============================================================================
# AitherOS GCP - FULL Profile
# =============================================================================
# Cost: ~$250-400/month
# Best for: Production, GPU workloads, self-hosted LLMs, image generation
#
# Services included:
#   - Full AitherOS ecosystem on GKE
#   - GPU node pool (NVIDIA T4)
#   - Self-hosted Ollama for LLM inference
#   - ComfyUI for image generation
#   - Full observability stack
#
# Includes:
#   - GKE Autopilot cluster
#   - GPU node pool (scales 0-3)
#   - Persistent storage
#   - Load balancer with SSL
# =============================================================================

# Project Configuration
project_id  = "YOUR_PROJECT_ID" # Replace with your GCP project ID
region      = "us-central1"
environment = "production"
profile     = "full"

# Budget alert at $500/month
budget_amount = 500

# Labels
labels = {
  team    = "production"
  purpose = "full-deployment"
}

# Enable CI/CD
enable_cicd  = true
github_owner = "Aitherium"
github_repo  = "AitherZero"

# Secrets
secrets = {}

# Custom domain
# domain     = "aither.ai"
# enable_ssl = true
