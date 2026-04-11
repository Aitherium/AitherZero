# =============================================================================
# AitherOS Kubernetes Module — Variables
# =============================================================================

variable "namespace" {
  description = "Kubernetes namespace for AitherOS services"
  type        = string
  default     = "aitheros"
}

variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string
  default     = "dev"
}

variable "labels" {
  description = "Additional labels to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "services" {
  description = "List of AitherOS services to deploy"
  type = list(object({
    name           = string
    image          = string
    port           = optional(number)
    ports          = optional(list(number))
    replicas       = optional(number, 1)
    layer          = optional(number, 99)
    health_path    = optional(string)
    env            = optional(map(string), {})
    cpu_request    = optional(string)
    cpu_limit      = optional(string)
    memory_request = optional(string)
    memory_limit   = optional(string)
    persistent     = optional(bool, false)
    storage_size   = optional(string, "5Gi")
    data_path      = optional(string, "/data")
    gpu            = optional(bool, false)
    gpu_count      = optional(number, 1)
    stateful       = optional(bool, false)
    external       = optional(bool, false)
    depends_on     = optional(string)
    startup_delay  = optional(number, 30)
  }))
  default = []
}

variable "common_env" {
  description = "Environment variables shared across all services"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secret key-value pairs to inject"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "storage_class" {
  description = "StorageClass for PersistentVolumeClaims"
  type        = string
  default     = "standard"
}

variable "default_cpu_request" {
  description = "Default CPU request per container"
  type        = string
  default     = "100m"
}

variable "default_cpu_limit" {
  description = "Default CPU limit per container"
  type        = string
  default     = "500m"
}

variable "default_memory_request" {
  description = "Default memory request per container"
  type        = string
  default     = "128Mi"
}

variable "default_memory_limit" {
  description = "Default memory limit per container"
  type        = string
  default     = "512Mi"
}

# Ingress
variable "enable_ingress" {
  description = "Create Ingress resource for external access"
  type        = bool
  default     = false
}

variable "ingress_class" {
  description = "Ingress controller class (nginx, traefik, etc.)"
  type        = string
  default     = "nginx"
}

variable "ingress_hosts" {
  description = "Ingress host rules"
  type = list(object({
    host = string
    paths = list(object({
      path    = string
      service = string
      port    = number
    }))
  }))
  default = []
}

variable "ingress_annotations" {
  description = "Additional ingress annotations"
  type        = map(string)
  default     = {}
}

variable "ingress_tls_secret" {
  description = "TLS secret name for HTTPS. Empty = no TLS."
  type        = string
  default     = ""
}

variable "ingress_namespace" {
  description = "Namespace of the ingress controller (for NetworkPolicy)"
  type        = string
  default     = "ingress-nginx"
}

# Network Policy
variable "enable_network_policy" {
  description = "Create NetworkPolicy to restrict inter-service traffic"
  type        = bool
  default     = true
}
