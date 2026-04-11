# =============================================================================
# AitherOS Kubernetes Module
# =============================================================================
# Deploy AitherOS services to a Kubernetes cluster.
# Supports Deployments, StatefulSets, Services, ConfigMaps, PVCs, and Ingress.
#
# Usage:
#   module "aitheros_k8s" {
#     source      = "../../modules/kubernetes"
#     namespace   = "aitheros"
#     environment = "production"
#     services    = var.services
#   }
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "aither" {
  metadata {
    name = var.namespace

    labels = merge(var.labels, {
      managed_by  = "opentofu"
      environment = var.environment
      project     = "aitheros"
    })
  }
}

# ---------------------------------------------------------------------------
# ConfigMap — shared environment configuration
# ---------------------------------------------------------------------------
resource "kubernetes_config_map" "shared_env" {
  metadata {
    name      = "aitheros-shared-env"
    namespace = kubernetes_namespace.aither.metadata[0].name
  }

  data = merge(var.common_env, {
    AITHER_DOCKER_MODE = "true"
    ENVIRONMENT        = var.environment
  })
}

# ---------------------------------------------------------------------------
# Secrets — from AitherSecrets vault
# ---------------------------------------------------------------------------
resource "kubernetes_secret" "aither_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  metadata {
    name      = "aitheros-secrets"
    namespace = kubernetes_namespace.aither.metadata[0].name
  }

  data = var.secrets
  type = "Opaque"
}

# ---------------------------------------------------------------------------
# PersistentVolumeClaims — per-service data volumes
# ---------------------------------------------------------------------------
resource "kubernetes_persistent_volume_claim" "service_data" {
  for_each = { for s in var.services : s.name => s if lookup(s, "persistent", false) }

  metadata {
    name      = "${each.key}-data"
    namespace = kubernetes_namespace.aither.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = each.key
      "app.kubernetes.io/part-of" = "aitheros"
    }
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class

    resources {
      requests = {
        storage = lookup(each.value, "storage_size", "5Gi")
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Deployments — one per AitherOS service
# ---------------------------------------------------------------------------
resource "kubernetes_deployment" "services" {
  for_each = { for s in var.services : s.name => s }

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.aither.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = each.key
      "app.kubernetes.io/part-of"    = "aitheros"
      "app.kubernetes.io/managed-by" = "opentofu"
      "aitheros/layer"               = tostring(lookup(each.value, "layer", 99))
    }
  }

  spec {
    replicas = lookup(each.value, "replicas", 1)

    selector {
      match_labels = {
        "app.kubernetes.io/name" = each.key
      }
    }

    strategy {
      type = lookup(each.value, "stateful", false) ? "Recreate" : "RollingUpdate"

      dynamic "rolling_update" {
        for_each = lookup(each.value, "stateful", false) ? [] : [1]
        content {
          max_surge       = "25%"
          max_unavailable = 0
        }
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = each.key
          "app.kubernetes.io/part-of" = "aitheros"
        }
      }

      spec {
        # Service account
        service_account_name = kubernetes_service_account.aither.metadata[0].name

        # Init container for boot ordering (optional)
        dynamic "init_container" {
          for_each = lookup(each.value, "depends_on", null) != null ? [each.value.depends_on] : []
          content {
            name    = "wait-for-${init_container.value}"
            image   = "busybox:1.36"
            command = ["sh", "-c", "until nc -z ${init_container.value} ${lookup({ for s in var.services : s.name => s }[init_container.value], "port", 80)}; do echo waiting for ${init_container.value}; sleep 2; done"]
          }
        }

        container {
          name  = each.key
          image = each.value.image

          # Ports
          dynamic "port" {
            for_each = lookup(each.value, "ports", [lookup(each.value, "port", null)])
            content {
              container_port = port.value
              protocol       = "TCP"
            }
          }

          # Environment from ConfigMap
          env_from {
            config_map_ref {
              name = kubernetes_config_map.shared_env.metadata[0].name
            }
          }

          # Environment from Secrets
          dynamic "env_from" {
            for_each = length(var.secrets) > 0 ? [1] : []
            content {
              secret_ref {
                name = kubernetes_secret.aither_secrets[0].metadata[0].name
              }
            }
          }

          # Per-service env overrides
          dynamic "env" {
            for_each = lookup(each.value, "env", {})
            content {
              name  = env.key
              value = env.value
            }
          }

          # Resource limits
          resources {
            requests = {
              cpu    = lookup(each.value, "cpu_request", var.default_cpu_request)
              memory = lookup(each.value, "memory_request", var.default_memory_request)
            }
            limits = {
              cpu    = lookup(each.value, "cpu_limit", var.default_cpu_limit)
              memory = lookup(each.value, "memory_limit", var.default_memory_limit)
            }
          }

          # GPU resources
          dynamic "resources" {
            for_each = lookup(each.value, "gpu", false) ? [1] : []
            content {
              limits = {
                "nvidia.com/gpu" = lookup(each.value, "gpu_count", 1)
              }
            }
          }

          # Health checks
          dynamic "liveness_probe" {
            for_each = lookup(each.value, "health_path", null) != null ? [each.value.health_path] : []
            content {
              http_get {
                path = liveness_probe.value
                port = lookup(each.value, "port", each.value.ports[0])
              }
              initial_delay_seconds = lookup(each.value, "startup_delay", 30)
              period_seconds        = 30
              timeout_seconds       = 10
              failure_threshold     = 3
            }
          }

          dynamic "readiness_probe" {
            for_each = lookup(each.value, "health_path", null) != null ? [each.value.health_path] : []
            content {
              http_get {
                path = readiness_probe.value
                port = lookup(each.value, "port", each.value.ports[0])
              }
              initial_delay_seconds = 10
              period_seconds        = 10
              timeout_seconds       = 5
              failure_threshold     = 3
            }
          }

          # Volume mounts
          dynamic "volume_mount" {
            for_each = lookup(each.value, "persistent", false) ? [1] : []
            content {
              name       = "${each.key}-data"
              mount_path = lookup(each.value, "data_path", "/data")
            }
          }
        }

        # Volumes
        dynamic "volume" {
          for_each = lookup(each.value, "persistent", false) ? [1] : []
          content {
            name = "${each.key}-data"
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim.service_data[each.key].metadata[0].name
            }
          }
        }

        # Node affinity for GPU workloads
        dynamic "affinity" {
          for_each = lookup(each.value, "gpu", false) ? [1] : []
          content {
            node_affinity {
              required_during_scheduling_ignored_during_execution {
                node_selector_term {
                  match_expressions {
                    key      = "nvidia.com/gpu.present"
                    operator = "In"
                    values   = ["true"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Services — ClusterIP for internal, LoadBalancer/NodePort for external
# ---------------------------------------------------------------------------
resource "kubernetes_service" "services" {
  for_each = { for s in var.services : s.name => s if lookup(s, "port", null) != null }

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.aither.metadata[0].name

    labels = {
      "app.kubernetes.io/name"    = each.key
      "app.kubernetes.io/part-of" = "aitheros"
    }
  }

  spec {
    type = lookup(each.value, "external", false) ? "LoadBalancer" : "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = each.key
    }

    port {
      port        = each.value.port
      target_port = each.value.port
      protocol    = "TCP"
    }
  }
}

# ---------------------------------------------------------------------------
# ServiceAccount
# ---------------------------------------------------------------------------
resource "kubernetes_service_account" "aither" {
  metadata {
    name      = "aitheros"
    namespace = kubernetes_namespace.aither.metadata[0].name

    labels = {
      "app.kubernetes.io/part-of"    = "aitheros"
      "app.kubernetes.io/managed-by" = "opentofu"
    }
  }
}

# ---------------------------------------------------------------------------
# RBAC — allow service account to manage pods (for agent operations)
# ---------------------------------------------------------------------------
resource "kubernetes_role" "aither_agent" {
  metadata {
    name      = "aitheros-agent"
    namespace = kubernetes_namespace.aither.metadata[0].name
  }

  rule {
    api_groups = ["", "apps"]
    resources  = ["pods", "deployments", "services", "configmaps", "secrets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log", "pods/exec"]
    verbs      = ["get", "create"]
  }
}

resource "kubernetes_role_binding" "aither_agent" {
  metadata {
    name      = "aitheros-agent"
    namespace = kubernetes_namespace.aither.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.aither_agent.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.aither.metadata[0].name
    namespace = kubernetes_namespace.aither.metadata[0].name
  }
}

# ---------------------------------------------------------------------------
# Ingress (optional — for external access via NGINX/Traefik)
# ---------------------------------------------------------------------------
resource "kubernetes_ingress_v1" "aither" {
  count = var.enable_ingress ? 1 : 0

  metadata {
    name      = "aitheros-ingress"
    namespace = kubernetes_namespace.aither.metadata[0].name

    annotations = merge(var.ingress_annotations, {
      "kubernetes.io/ingress.class" = var.ingress_class
    })
  }

  spec {
    dynamic "rule" {
      for_each = var.ingress_hosts
      content {
        host = rule.value.host
        http {
          dynamic "path" {
            for_each = rule.value.paths
            content {
              path      = path.value.path
              path_type = "Prefix"
              backend {
                service {
                  name = path.value.service
                  port {
                    number = path.value.port
                  }
                }
              }
            }
          }
        }
      }
    }

    dynamic "tls" {
      for_each = var.ingress_tls_secret != "" ? [1] : []
      content {
        hosts       = [for h in var.ingress_hosts : h.host]
        secret_name = var.ingress_tls_secret
      }
    }
  }
}

# ---------------------------------------------------------------------------
# NetworkPolicy — restrict inter-service traffic
# ---------------------------------------------------------------------------
resource "kubernetes_network_policy" "aither_default" {
  count = var.enable_network_policy ? 1 : 0

  metadata {
    name      = "aitheros-default"
    namespace = kubernetes_namespace.aither.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/part-of" = "aitheros"
      }
    }

    policy_types = ["Ingress"]

    # Allow traffic from within the namespace
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.namespace
          }
        }
      }
    }

    # Allow traffic from ingress controller
    dynamic "ingress" {
      for_each = var.enable_ingress ? [1] : []
      content {
        from {
          namespace_selector {
            match_labels = {
              "kubernetes.io/metadata.name" = var.ingress_namespace
            }
          }
        }
      }
    }
  }
}
