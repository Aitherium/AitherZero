# =============================================================================
# Cloud Run Module - Serverless AitherOS Deployment
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

variable "registry_url" {
  type = string
}

variable "veil_memory" {
  type    = string
  default = "512Mi"
}

variable "node_memory" {
  type    = string
  default = "1Gi"
}

variable "min_instances" {
  type    = number
  default = 0
}

variable "max_instances" {
  type    = number
  default = 3
}

variable "secret_ids" {
  type    = map(string)
  default = {}
}

variable "vpc_connector" {
  type = string
}

# -----------------------------------------------------------------------------
# Service Account
# -----------------------------------------------------------------------------

resource "google_service_account" "cloudrun" {
  account_id   = "aither-${var.environment}-cloudrun"
  display_name = "AitherOS Cloud Run Service Account"
  project      = var.project_id
}

# Grant access to secrets
resource "google_secret_manager_secret_iam_member" "cloudrun" {
  for_each = var.secret_ids

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloudrun.email}"
}

# -----------------------------------------------------------------------------
# AitherVeil (Dashboard) - Cloud Run Service
# -----------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "veil" {
  name     = "aither-veil-${var.environment}"
  location = var.region
  project  = var.project_id

  template {
    service_account = google_service_account.cloudrun.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      connector = var.vpc_connector
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      name  = "veil"
      image = "${var.registry_url}/aither-veil:latest"

      resources {
        limits = {
          cpu    = "1"
          memory = var.veil_memory
        }
        cpu_idle = true # Scale to zero
      }

      ports {
        container_port = 3000
      }

      env {
        name  = "NODE_ENV"
        value = var.environment == "production" ? "production" : "development"
      }

      env {
        name  = "NEXT_PUBLIC_API_URL"
        value = "https://aither-node-${var.environment}-${substr(md5(var.project_id), 0, 8)}-${var.region}.a.run.app"
      }

      startup_probe {
        http_get {
          path = "/api/health"
          port = 3000
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        failure_threshold     = 3
      }

      liveness_probe {
        http_get {
          path = "/api/health"
          port = 3000
        }
        period_seconds    = 30
        failure_threshold = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = var.labels
}

# -----------------------------------------------------------------------------
# AitherNode (MCP Server) - Cloud Run Service
# -----------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "node" {
  name     = "aither-node-${var.environment}"
  location = var.region
  project  = var.project_id

  template {
    service_account = google_service_account.cloudrun.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      connector = var.vpc_connector
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      name  = "node"
      image = "${var.registry_url}/aither-node:latest"

      resources {
        limits = {
          cpu    = "2"
          memory = var.node_memory
        }
        cpu_idle = true
      }

      ports {
        container_port = 8080
      }

      env {
        name  = "AITHER_ENV"
        value = var.environment
      }

      env {
        name  = "PYTHONUNBUFFERED"
        value = "1"
      }

      # Secret environment variables
      dynamic "env" {
        for_each = var.secret_ids
        content {
          name = upper(env.key)
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      startup_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 15
        period_seconds        = 10
        failure_threshold     = 5
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        period_seconds    = 30
        failure_threshold = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = var.labels
}

# -----------------------------------------------------------------------------
# IAM - Allow unauthenticated access (public demo)
# -----------------------------------------------------------------------------

resource "google_cloud_run_v2_service_iam_member" "veil_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.veil.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "node_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.node.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "veil_url" {
  value = google_cloud_run_v2_service.veil.uri
}

output "node_url" {
  value = google_cloud_run_v2_service.node.uri
}

output "api_url" {
  value = google_cloud_run_v2_service.node.uri
}

output "service_account" {
  value = google_service_account.cloudrun.email
}
