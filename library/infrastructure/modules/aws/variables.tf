# =============================================================================
# AWS Module — Variables
# =============================================================================

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = "default"
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

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to deploy across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "allowed_ports" {
  description = "Ports to open in the security group"
  type        = list(number)
  default     = [443, 8001, 8080, 3000]
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to access services"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "services" {
  description = "Map of services to deploy. Each needs: image, ports, env (optional), health_path (optional), cpu/memory (optional), replicas (optional)"
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

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}
