# =============================================================================
# Docker Host Module — Variables
# =============================================================================

# ── Connection ────────────────────────────────────────────────────────────────

variable "docker_host" {
  description = "Docker daemon address. Use unix:///var/run/docker.sock for local, ssh://user@host for remote."
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "ssh_opts" {
  description = "SSH options for remote Docker connections (e.g. [\"-o\", \"StrictHostKeyChecking=no\"])"
  type        = list(string)
  default     = []
}

variable "registry_auth" {
  description = "Container registry authentication (address, username, password)"
  type = object({
    address  = string
    username = string
    password = string
  })
  default   = null
  sensitive = true
}

# ── Container ─────────────────────────────────────────────────────────────────

variable "container_name" {
  description = "Name for the Docker container"
  type        = string
}

variable "image" {
  description = "Docker image reference (e.g. ghcr.io/aitherium/genesis:latest)"
  type        = string
}

variable "restart_policy" {
  description = "Container restart policy: no, on-failure, always, unless-stopped"
  type        = string
  default     = "unless-stopped"
}

variable "ports" {
  description = "Port mappings: [{internal, external, protocol?}]"
  type = list(object({
    internal = number
    external = number
    protocol = optional(string, "tcp")
  }))
  default = []
}

variable "env_vars" {
  description = "Environment variables as key-value map"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "extra_env" {
  description = "Additional environment variables as KEY=VALUE strings"
  type        = list(string)
  default     = []
}

# ── Storage ───────────────────────────────────────────────────────────────────

variable "volumes" {
  description = "Named Docker volumes to mount"
  type = list(object({
    name           = string
    container_path = string
    read_only      = optional(bool, false)
  }))
  default = []
}

variable "bind_mounts" {
  description = "Bind mount host directories into the container"
  type = list(object({
    host_path      = string
    container_path = string
    read_only      = optional(bool, false)
  }))
  default = []
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "create_network" {
  description = "Create a dedicated bridge network for this container"
  type        = bool
  default     = false
}

variable "network_name" {
  description = "Override network name (default: aither-{container_name})"
  type        = string
  default     = ""
}

variable "networks" {
  description = "Existing network names to attach (used when create_network=false)"
  type        = list(string)
  default     = null
}

# ── Resources ─────────────────────────────────────────────────────────────────

variable "memory_limit_mb" {
  description = "Container memory limit in MB (0 = unlimited)"
  type        = number
  default     = 0
}

variable "memory_swap_mb" {
  description = "Container memory+swap limit in MB (0 = unlimited)"
  type        = number
  default     = 0
}

variable "cpu_shares" {
  description = "CPU shares (relative weight, 0 = default 1024)"
  type        = number
  default     = 0
}

variable "gpu_enabled" {
  description = "Pass GPU device into container"
  type        = bool
  default     = false
}

# ── Health ────────────────────────────────────────────────────────────────────

variable "healthcheck" {
  description = "Container health check config"
  type = object({
    test     = list(string)
    interval = optional(string, "30s")
    timeout  = optional(string, "10s")
    retries  = optional(number, 3)
  })
  default = null
}

variable "wait_for_healthy" {
  description = "Wait for the container to be healthy before marking as created"
  type        = bool
  default     = true
}

variable "wait_timeout" {
  description = "Timeout waiting for container health (seconds)"
  type        = number
  default     = 120
}

# ── Build ─────────────────────────────────────────────────────────────────────

variable "build_context" {
  description = "Build from source instead of pulling (context path + optional dockerfile)"
  type = object({
    context    = string
    dockerfile = optional(string, "Dockerfile")
  })
  default = null
}

variable "keep_image_locally" {
  description = "Keep the image on the host after destroy"
  type        = bool
  default     = true
}

# ── Lifecycle ─────────────────────────────────────────────────────────────────

variable "rolling_update" {
  description = "Create new container before destroying old (rolling update)"
  type        = bool
  default     = true
}

# ── Labels ────────────────────────────────────────────────────────────────────

variable "project_label" {
  description = "Project label for resource tracking"
  type        = string
  default     = "aitheros"
}
