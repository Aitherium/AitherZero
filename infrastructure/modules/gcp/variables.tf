# =============================================================================
# AitherOS GCP Infrastructure - Variables
# =============================================================================

# -----------------------------------------------------------------------------
# Project Configuration
# -----------------------------------------------------------------------------

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region for resources"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be one of: dev, staging, production."
  }
}

variable "profile" {
  description = "Deployment profile: minimal (~$30/mo), demo (~$80/mo), full (~$300/mo)"
  type        = string
  default     = "demo"

  validation {
    condition     = contains(["minimal", "demo", "full"], var.profile)
    error_message = "Profile must be one of: minimal, demo, full."
  }
}

variable "labels" {
  description = "Additional labels for all resources"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Authentication
# -----------------------------------------------------------------------------

variable "billing_account" {
  description = "GCP Billing Account ID (for budget alerts)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Secrets (API Keys)
# -----------------------------------------------------------------------------

variable "secrets" {
  description = "Map of secret names to values (stored in Secret Manager)"
  type        = map(string)
  default     = {}
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Container Registry
# -----------------------------------------------------------------------------

variable "container_images" {
  description = "Container image tags to deploy"
  type = object({
    veil     = optional(string, "latest")
    node     = optional(string, "latest")
    services = optional(string, "latest")
  })
  default = {}
}

# -----------------------------------------------------------------------------
# CI/CD Configuration
# -----------------------------------------------------------------------------

variable "enable_cicd" {
  description = "Enable Cloud Build triggers for CI/CD"
  type        = bool
  default     = false
}

variable "github_owner" {
  description = "GitHub repository owner"
  type        = string
  default     = "Aitherium"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "AitherZero"
}

# -----------------------------------------------------------------------------
# Budget Configuration
# -----------------------------------------------------------------------------

variable "budget_amount" {
  description = "Monthly budget in USD (0 to disable budget alerts)"
  type        = number
  default     = 100
}

# -----------------------------------------------------------------------------
# Domain Configuration
# -----------------------------------------------------------------------------

variable "domain" {
  description = "Custom domain for the deployment (optional)"
  type        = string
  default     = ""
}

variable "enable_ssl" {
  description = "Enable managed SSL certificate"
  type        = bool
  default     = true
}
