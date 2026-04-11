# =============================================================================
# Azure Module — Variables
# =============================================================================

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment name: dev, staging, prod"
  type        = string
  default     = "dev"
}

variable "deployment_profile" {
  description = "Sizing profile: minimal, demo, full"
  type        = string
  default     = "minimal"
  validation {
    condition     = contains(["minimal", "demo", "full"], var.deployment_profile)
    error_message = "Profile must be minimal, demo, or full."
  }
}

variable "vnet_cidr" {
  description = "Virtual network CIDR block"
  type        = string
  default     = "10.1.0.0/16"
}

variable "services" {
  description = "Map of services to deploy"
  type        = map(any)
  default     = {}
}

variable "common_env" {
  description = "Environment variables applied to all services"
  type        = map(string)
  default = {
    AITHER_DOCKER_MODE = "true"
    LOG_LEVEL          = "INFO"
  }
}

variable "create_acr" {
  description = "Create Azure Container Registry"
  type        = bool
  default     = false
}

variable "registry_credentials" {
  description = "Container registry credentials"
  type = object({
    server   = string
    username = string
    password = string
  })
  default   = null
  sensitive = true
}

variable "log_retention_days" {
  description = "Log retention in days"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
