# =============================================================================
# AitherOS GCP Infrastructure - Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# URLs and Endpoints
# -----------------------------------------------------------------------------

output "veil_url" {
  description = "AitherVeil dashboard URL"
  value       = local.profile.enable_cloudrun ? module.cloudrun[0].veil_url : (local.profile.enable_gke ? module.gke[0].veil_url : null)
}

output "node_url" {
  description = "AitherNode MCP server URL"
  value       = local.profile.enable_cloudrun ? module.cloudrun[0].node_url : (local.profile.enable_gke ? module.gke[0].node_url : null)
}

output "api_url" {
  description = "Main API endpoint"
  value       = local.profile.enable_cloudrun ? module.cloudrun[0].api_url : (local.profile.enable_gke ? module.gke[0].api_url : null)
}

# -----------------------------------------------------------------------------
# Container Registry
# -----------------------------------------------------------------------------

output "registry_url" {
  description = "Artifact Registry URL for container images"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.aither.repository_id}"
}

output "registry_push_commands" {
  description = "Commands to push container images"
  value = {
    configure = "gcloud auth configure-docker ${var.region}-docker.pkg.dev"
    push_veil = "docker push ${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.aither.repository_id}/aither-veil:latest"
    push_node = "docker push ${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.aither.repository_id}/aither-node:latest"
  }
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

output "network_id" {
  description = "VPC Network ID"
  value       = module.network.network_id
}

output "subnetwork_id" {
  description = "Subnetwork ID"
  value       = module.network.subnetwork_id
}

# -----------------------------------------------------------------------------
# GKE (if enabled)
# -----------------------------------------------------------------------------

output "gke_cluster_name" {
  description = "GKE cluster name"
  value       = local.profile.enable_gke ? module.gke[0].cluster_name : null
}

output "gke_kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = local.profile.enable_gke ? "gcloud container clusters get-credentials ${module.gke[0].cluster_name} --region ${var.region} --project ${var.project_id}" : null
}

# -----------------------------------------------------------------------------
# Cost Estimation
# -----------------------------------------------------------------------------

output "estimated_monthly_cost" {
  description = "Estimated monthly cost in USD"
  value = {
    profile = var.profile
    estimate = var.profile == "minimal" ? "$30-50/month" : (
      var.profile == "demo" ? "$80-120/month" : "$250-400/month"
    )
    breakdown = var.profile == "minimal" ? {
      "Cloud Run (Veil)"  = "$5-10"
      "Cloud Run (Node)"  = "$10-20"
      "Artifact Registry" = "$1-5"
      "Secret Manager"    = "$0.50"
      "Networking"        = "$5-10"
      "Cloud Build"       = "$0 (free tier)"
      } : (var.profile == "demo" ? {
        "Cloud Run (Veil)"     = "$10-20"
        "Cloud Run (Node)"     = "$20-40"
        "Cloud Run (Services)" = "$20-40"
        "Artifact Registry"    = "$5-10"
        "Secret Manager"       = "$1"
        "Networking"           = "$10-20"
        } : {
        "GKE Cluster"       = "$70-100"
        "GPU Node Pool"     = "$150-250"
        "Persistent Disks"  = "$10-20"
        "Load Balancer"     = "$20-30"
        "Artifact Registry" = "$10-20"
    })
  }
}

# -----------------------------------------------------------------------------
# Quick Start Info
# -----------------------------------------------------------------------------

output "quick_start" {
  description = "Quick start instructions"
  value       = <<-EOT
    
    ✅ AitherOS deployed to GCP!
    
    🌐 Dashboard: ${local.profile.enable_cloudrun ? module.cloudrun[0].veil_url : (local.profile.enable_gke ? module.gke[0].veil_url : "N/A")}
    🔌 API:       ${local.profile.enable_cloudrun ? module.cloudrun[0].node_url : (local.profile.enable_gke ? module.gke[0].node_url : "N/A")}
    
    📦 Push images:
       gcloud auth configure-docker ${var.region}-docker.pkg.dev
       docker-compose -f docker-compose.aitheros.yml build
       docker push ${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.aither.repository_id}/aither-veil:latest
    
    💰 Estimated cost: ${var.profile == "minimal" ? "$30-50" : (var.profile == "demo" ? "$80-120" : "$250-400")}/month
    
    🗑️ Teardown:
       tofu destroy -var-file="profiles/${var.profile}.tfvars" -auto-approve
    
  EOT
}
