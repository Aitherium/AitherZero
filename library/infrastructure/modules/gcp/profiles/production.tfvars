# =============================================================================
# AitherOS GCP — PRODUCTION Profile (Go-to-Market)
# =============================================================================
# Cost: ~$400-800/month (scales with demand)
# Best for: Production SaaS, serving external users, autoscaling inference
#
# Architecture:
#   - GKE Autopilot cluster with GPU node pools
#   - vLLM workers on L4 GPUs (24GB VRAM, 2-4x cheaper than A100)
#   - Ollama sidecar for free-tier inference
#   - Cloud Run for stateless services (Veil, Gateway, ACTA)
#   - Cloudflare for edge routing, WAF, DDoS protection
#   - Autoscaling: HPA on GPU utilization + queue depth
#
# Cost advantage vs OpenAI/Claude:
#   - L4 GPU spot: ~$0.35/hr → $252/mo continuous
#   - Serves ~2M tokens/hr at 14B params (REAP-pruned)
#   - Cost per 1M tokens: ~$0.13 (vs OpenAI GPT-4o-mini $0.15, Claude Haiku $0.25)
#   - At scale: 10x cheaper than cloud API providers
# =============================================================================

# Project Configuration
project_id  = "aitherium-prod"
region      = "us-central1"
environment = "production"
profile     = "full"

# Budget alert — hard cap with notification
budget_amount = 1000

# Labels
labels = {
  team        = "production"
  purpose     = "saas-inference"
  cost_center = "revenue"
  ring        = "prod"
}

# CI/CD — deploy on main branch push
enable_cicd  = true
github_owner = "Aitherium"
github_repo  = "AitherOS"

# GPU config — L4 for production (24GB VRAM, ~$0.35/hr spot)
# Much cheaper than T4 for inference while being faster
# container_images = {
#   veil     = "latest"
#   node     = "latest"
#   services = "latest"
# }

# Secrets — populated by CI/CD pipeline from GitHub Secrets
# tofu apply -var-file="profiles/production.tfvars" \
#   -var="secrets={STRIPE_SECRET_KEY=\"sk_live_...\", VASTAI_API_KEY=\"...\", ...}"
secrets = {}

# Domain
# domain     = "api.aitherium.com"
# enable_ssl = true
