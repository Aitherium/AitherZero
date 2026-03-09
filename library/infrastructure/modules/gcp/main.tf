# =============================================================================
# AitherOS GCP Infrastructure Module
# =============================================================================
# This module deploys the complete Aither ecosystem to Google Cloud Platform.
# Supports three deployment profiles: minimal, demo, full
#
# Usage:
#   tofu init
#   tofu plan -var-file="profiles/demo.tfvars"
#   tofu apply -var-file="profiles/demo.tfvars"
#
# Teardown:
#   tofu destroy -var-file="profiles/demo.tfvars" -auto-approve
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }

  # Remote state in GCS (configured in backend.tf)
}

# =============================================================================
# Provider Configuration
# =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# =============================================================================
# Local Values
# =============================================================================

locals {
  # Common labels for all resources
  common_labels = merge(var.labels, {
    managed_by  = "opentofu"
    environment = var.environment
    project     = "aitheros"
  })

  # Service configurations based on profile
  services = {
    minimal = {
      enable_gpu      = false
      enable_cloudrun = true
      enable_gke      = false
      machine_type    = "e2-medium"
      veil_memory     = "512Mi"
      node_memory     = "1Gi"
      min_instances   = 0
      max_instances   = 1
    }
    demo = {
      enable_gpu      = false
      enable_cloudrun = true
      enable_gke      = false
      machine_type    = "e2-standard-2"
      veil_memory     = "512Mi"
      node_memory     = "2Gi"
      min_instances   = 0
      max_instances   = 3
    }
    full = {
      enable_gpu      = true
      enable_cloudrun = false
      enable_gke      = true
      machine_type    = "n1-standard-4"
      gpu_type        = "nvidia-tesla-t4"
      gpu_count       = 1
      veil_memory     = "1Gi"
      node_memory     = "4Gi"
      min_instances   = 1
      max_instances   = 10
    }
  }

  profile = local.services[var.profile]
}

# =============================================================================
# Enable Required APIs
# =============================================================================

resource "google_project_service" "required_apis" {
  for_each = toset([
    "run.googleapis.com",              # Cloud Run
    "artifactregistry.googleapis.com", # Artifact Registry
    "cloudbuild.googleapis.com",       # Cloud Build
    "secretmanager.googleapis.com",    # Secret Manager
    "compute.googleapis.com",          # Compute Engine
    "container.googleapis.com",        # GKE
    "iam.googleapis.com",              # IAM
    "logging.googleapis.com",          # Cloud Logging
    "monitoring.googleapis.com",       # Cloud Monitoring
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# =============================================================================
# Networking
# =============================================================================

module "network" {
  source = "./modules/network"

  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  labels      = local.common_labels

  depends_on = [google_project_service.required_apis]
}

# =============================================================================
# Artifact Registry (Container Images)
# =============================================================================

resource "google_artifact_registry_repository" "aither" {
  location      = var.region
  repository_id = "aither-${var.environment}"
  description   = "AitherOS container images"
  format        = "DOCKER"
  labels        = local.common_labels

  depends_on = [google_project_service.required_apis]
}

# =============================================================================
# Secret Manager (API Keys, Credentials)
# =============================================================================

# Use nonsensitive for keys only (values remain sensitive)
locals {
  secret_keys = nonsensitive(toset(keys(var.secrets)))
}

resource "google_secret_manager_secret" "api_keys" {
  for_each = local.secret_keys

  secret_id = "aither-${var.environment}-${each.key}"
  labels    = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required_apis]
}

resource "google_secret_manager_secret_version" "api_keys" {
  for_each = local.secret_keys

  secret      = google_secret_manager_secret.api_keys[each.key].id
  secret_data = var.secrets[each.key]
}

# =============================================================================
# Cloud Run Services (for minimal/demo profiles)
# =============================================================================

module "cloudrun" {
  source = "./modules/cloudrun"
  count  = local.profile.enable_cloudrun ? 1 : 0

  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  labels      = local.common_labels

  # Container configuration
  registry_url = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.aither.repository_id}"

  # Service configuration
  veil_memory   = local.profile.veil_memory
  node_memory   = local.profile.node_memory
  min_instances = local.profile.min_instances
  max_instances = local.profile.max_instances

  # Secrets
  secret_ids = { for k, v in google_secret_manager_secret.api_keys : k => v.id }

  # VPC Connector for internal communication
  vpc_connector = module.network.vpc_connector_id

  depends_on = [
    google_project_service.required_apis,
    google_artifact_registry_repository.aither,
    google_secret_manager_secret_version.api_keys
  ]
}

# =============================================================================
# GKE Cluster (for full profile with GPU)
# =============================================================================

module "gke" {
  source = "./modules/gke"
  count  = local.profile.enable_gke ? 1 : 0

  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  labels      = local.common_labels

  # Network
  network    = module.network.network_id
  subnetwork = module.network.subnetwork_id

  # Node configuration
  machine_type = local.profile.machine_type
  gpu_type     = lookup(local.profile, "gpu_type", null)
  gpu_count    = lookup(local.profile, "gpu_count", 0)

  # Secrets
  secret_ids = { for k, v in google_secret_manager_secret.api_keys : k => v.id }

  depends_on = [
    google_project_service.required_apis,
    module.network
  ]
}

# =============================================================================
# Cloud Build Triggers (CI/CD)
# =============================================================================

resource "google_cloudbuild_trigger" "deploy" {
  count = var.enable_cicd ? 1 : 0

  name        = "aither-${var.environment}-deploy"
  description = "Deploy AitherOS to ${var.environment}"

  github {
    owner = var.github_owner
    name  = var.github_repo

    push {
      branch = var.environment == "production" ? "^main$" : "^develop$"
    }
  }

  filename = "cloudbuild.yaml"

  substitutions = {
    _ENVIRONMENT = var.environment
    _REGION      = var.region
  }

  depends_on = [google_project_service.required_apis]
}

# =============================================================================
# Budget Alert (Cost Control)
# =============================================================================

resource "google_billing_budget" "aither" {
  count = var.budget_amount > 0 ? 1 : 0

  billing_account = var.billing_account
  display_name    = "AitherOS ${var.environment} Budget"

  budget_filter {
    projects = ["projects/${var.project_id}"]
    labels = {
      environment = var.environment
      project     = "aitheros"
    }
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }
}
