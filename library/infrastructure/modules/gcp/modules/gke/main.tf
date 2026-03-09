# =============================================================================
# GKE Module - Kubernetes Deployment with GPU Support
# =============================================================================

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "environment" {
  type = string
}

variable "labels" {
  type = map(string)
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "machine_type" {
  type    = string
  default = "n1-standard-4"
}

variable "gpu_type" {
  type    = string
  default = null
}

variable "gpu_count" {
  type    = number
  default = 0
}

variable "secret_ids" {
  type    = map(string)
  default = {}
}

# -----------------------------------------------------------------------------
# GKE Cluster
# -----------------------------------------------------------------------------

resource "google_container_cluster" "aither" {
  name     = "aither-${var.environment}"
  location = var.region
  project  = var.project_id

  # We manage node pools separately
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network
  subnetwork = var.subnetwork

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Enable Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Addons
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # Logging and monitoring
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  resource_labels = var.labels
}

# -----------------------------------------------------------------------------
# Default Node Pool (CPU)
# -----------------------------------------------------------------------------

resource "google_container_node_pool" "default" {
  name       = "default-pool"
  location   = var.region
  cluster    = google_container_cluster.aither.name
  project    = var.project_id
  node_count = 1

  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 100
    disk_type    = "pd-balanced"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = var.labels
    tags   = ["aither-node"]
  }
}

# -----------------------------------------------------------------------------
# GPU Node Pool (optional)
# -----------------------------------------------------------------------------

resource "google_container_node_pool" "gpu" {
  count = var.gpu_count > 0 ? 1 : 0

  name     = "gpu-pool"
  location = var.region
  cluster  = google_container_cluster.aither.name
  project  = var.project_id

  autoscaling {
    min_node_count = 0
    max_node_count = 3
  }

  node_config {
    machine_type = "n1-standard-4"
    disk_size_gb = 200
    disk_type    = "pd-balanced"

    guest_accelerator {
      type  = var.gpu_type
      count = var.gpu_count
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = merge(var.labels, {
      "gpu" = "true"
    })

    taint {
      key    = "nvidia.com/gpu"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    tags = ["aither-gpu-node"]
  }
}

# -----------------------------------------------------------------------------
# Service Account for Workload Identity
# -----------------------------------------------------------------------------

resource "google_service_account" "workload" {
  account_id   = "aither-${var.environment}-workload"
  display_name = "AitherOS GKE Workload Identity"
  project      = var.project_id
}

# Grant access to secrets
resource "google_secret_manager_secret_iam_member" "workload" {
  for_each = var.secret_ids

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.workload.email}"
}

# Bind Kubernetes service account to GCP service account
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.workload.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[aither/aither-workload]"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "cluster_name" {
  value = google_container_cluster.aither.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.aither.endpoint
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.aither.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "workload_service_account" {
  value = google_service_account.workload.email
}

output "veil_url" {
  description = "Will be populated after Kubernetes ingress is created"
  value       = null
}

output "node_url" {
  description = "Will be populated after Kubernetes ingress is created"
  value       = null
}

output "api_url" {
  description = "Will be populated after Kubernetes ingress is created"
  value       = null
}
