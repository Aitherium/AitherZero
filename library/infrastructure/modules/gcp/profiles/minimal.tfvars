# =============================================================================
# AitherOS GCP - MINIMAL Profile
# =============================================================================
# Cost: ~$30-50/month
# Best for: Quick demos, investor presentations, personal testing
#
# Services included:
#   - AitherVeil (Dashboard) on Cloud Run
#   - AitherNode (MCP Server) on Cloud Run
#   - Uses external LLM APIs (Gemini, OpenAI)
#
# NOT included:
#   - GPU support
#   - Self-hosted LLM (Ollama)
#   - Image generation (ComfyUI)
# =============================================================================

# Project Configuration
project_id  = "YOUR_PROJECT_ID" # Replace with your GCP project ID
region      = "us-central1"
environment = "dev"
profile     = "minimal"

# Budget alert disabled for minimal profile (requires billing account setup)
budget_amount = 0

# Labels
labels = {
  team    = "demo"
  purpose = "demo"
}

# Secrets (provide via environment variables or tfvars override)
# Example: tofu apply -var='secrets={"gemini_api_key":"abc123"}'
secrets = {}
