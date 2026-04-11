# =============================================================================
# AitherOS Docker Host Module
# =============================================================================
# Deploy containers to a remote Docker host via SSH or local Docker socket.
# Supports single containers or compose stacks with health checks.
#
# Usage:
#   module "my_service" {
#     source         = "../../modules/docker-host"
#     container_name = "my-service"
#     image          = "ghcr.io/aitherium/my-service:latest"
#     host           = "ssh://deploy@10.0.1.50"
#     ports          = [{ internal = 8080, external = 8080 }]
#   }
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Provider — connects to local or remote Docker daemon
# ---------------------------------------------------------------------------
provider "docker" {
  host     = var.docker_host
  ssh_opts = var.ssh_opts

  dynamic "registry_auth" {
    for_each = var.registry_auth != null ? [var.registry_auth] : []
    content {
      address  = registry_auth.value.address
      username = registry_auth.value.username
      password = registry_auth.value.password
    }
  }
}

# ---------------------------------------------------------------------------
# Pull image
# ---------------------------------------------------------------------------
resource "docker_image" "service" {
  name         = var.image
  keep_locally = var.keep_image_locally

  dynamic "build" {
    for_each = var.build_context != null ? [var.build_context] : []
    content {
      context    = build.value.context
      dockerfile = lookup(build.value, "dockerfile", "Dockerfile")
    }
  }
}

# ---------------------------------------------------------------------------
# Network (optional — creates a dedicated bridge)
# ---------------------------------------------------------------------------
resource "docker_network" "service" {
  count  = var.create_network ? 1 : 0
  name   = var.network_name != "" ? var.network_name : "aither-${var.container_name}"
  driver = "bridge"

  labels {
    label = "managed_by"
    value = "opentofu"
  }
  labels {
    label = "aither.project"
    value = var.project_label
  }
}

# ---------------------------------------------------------------------------
# Volume mounts
# ---------------------------------------------------------------------------
resource "docker_volume" "data" {
  for_each = { for v in var.volumes : v.name => v }
  name     = each.value.name

  labels {
    label = "managed_by"
    value = "opentofu"
  }
}

# ---------------------------------------------------------------------------
# Container
# ---------------------------------------------------------------------------
resource "docker_container" "service" {
  name  = var.container_name
  image = docker_image.service.image_id

  restart = var.restart_policy

  # Port mappings
  dynamic "ports" {
    for_each = var.ports
    content {
      internal = ports.value.internal
      external = ports.value.external
      protocol = lookup(ports.value, "protocol", "tcp")
    }
  }

  # Environment variables
  env = concat(
    [for k, v in var.env_vars : "${k}=${v}"],
    var.extra_env,
  )

  # Volume mounts
  dynamic "volumes" {
    for_each = var.volumes
    content {
      volume_name    = volumes.value.name
      container_path = volumes.value.container_path
      read_only      = lookup(volumes.value, "read_only", false)
    }
  }

  # Bind mounts
  dynamic "volumes" {
    for_each = var.bind_mounts
    content {
      host_path      = volumes.value.host_path
      container_path = volumes.value.container_path
      read_only      = lookup(volumes.value, "read_only", false)
    }
  }

  # Network
  dynamic "networks_advanced" {
    for_each = var.create_network ? [docker_network.service[0].name] : (var.networks != null ? var.networks : [])
    content {
      name = networks_advanced.value
    }
  }

  # Resource limits
  memory      = var.memory_limit_mb > 0 ? var.memory_limit_mb : null
  memory_swap = var.memory_swap_mb > 0 ? var.memory_swap_mb : null
  cpu_shares  = var.cpu_shares > 0 ? var.cpu_shares : null

  # GPU passthrough
  dynamic "devices" {
    for_each = var.gpu_enabled ? ["/dev/nvidia0"] : []
    content {
      host_path = devices.value
    }
  }

  # Health check
  dynamic "healthcheck" {
    for_each = var.healthcheck != null ? [var.healthcheck] : []
    content {
      test     = healthcheck.value.test
      interval = lookup(healthcheck.value, "interval", "30s")
      timeout  = lookup(healthcheck.value, "timeout", "10s")
      retries  = lookup(healthcheck.value, "retries", 3)
    }
  }

  # Labels
  labels {
    label = "managed_by"
    value = "opentofu"
  }
  labels {
    label = "aither.project"
    value = var.project_label
  }
  labels {
    label = "aither.service"
    value = var.container_name
  }

  # Lifecycle
  lifecycle {
    create_before_destroy = var.rolling_update
  }

  # Wait for health
  wait         = var.wait_for_healthy
  wait_timeout = var.wait_timeout
}
