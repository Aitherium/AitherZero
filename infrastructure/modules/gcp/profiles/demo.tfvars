# =============================================================================
# AitherOS GCP - DEMO Profile
# =============================================================================
# Cost: ~$80-120/month
# Best for: Full demos, multi-user access, client presentations
#
# Services included:
#   - AitherVeil (Dashboard) on Cloud Run
#   - AitherNode (MCP Server) on Cloud Run
#   - Core AitherOS services on Cloud Run
#   - External LLM APIs (Gemini, OpenAI)
#   - Higher resource limits for better performance
#
# NOT included:
#   - GPU support
#   - Self-hosted LLM (Ollama)
#   - Image generation (ComfyUI)
# =============================================================================

# Project Configuration
project_id  = "YOUR_PROJECT_ID" # Replace with your GCP project ID
region      = "us-central1"
environment = "staging"
profile     = "demo"

# Budget alert at $150/month
budget_amount = 150

# Labels
labels = {
  team    = "demo"
  purpose = "client-demo"
}

# Enable CI/CD for automatic deployments
enable_cicd  = false
github_owner = "Aitherium"
github_repo  = "AitherZero"

# Secrets (provide via environment variables or tfvars override)
secrets = {}

# Optional: Custom domain
# domain     = "demo.aither.ai"
# enable_ssl = true
