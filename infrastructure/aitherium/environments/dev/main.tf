# Aitherium Infrastructure - Development Environment
#
# Deploy AitherOS to local Hyper-V or Docker for development.
# This is the default target for headless automation.

terraform {
  required_version = ">= 1.6.0"
  
  required_providers {
    hyperv = {
      source  = "taliesins/hyperv"
      version = ">= 1.0.3"
    }
  }
}

# Variables from config.psd1 via terraform.tfvars
variable "environment" {
  type        = string
  default     = "dev"
  description = "Environment name"
}

variable "hyperv_host" {
  type        = string
  default     = "localhost"
  description = "Hyper-V host for VM deployment"
}

variable "vm_count" {
  type        = number
  default     = 1
  description = "Number of VMs to create"
}

variable "vm_memory_gb" {
  type        = number
  default     = 4
  description = "Memory per VM in GB"
}

variable "vm_cpus" {
  type        = number
  default     = 2
  description = "CPUs per VM"
}

variable "vm_path" {
  type        = string
  default     = "E:\\VMs"
  description = "Path for VM storage"
}

variable "iso_path" {
  type        = string
  default     = ""
  description = "Path to boot ISO (AgenticOS)"
}

# Provider configuration
provider "hyperv" {
  user     = "Administrator"
  password = var.hyperv_password
  host     = var.hyperv_host
  port     = 5986
  https    = true
  insecure = true
}

variable "hyperv_password" {
  type        = string
  sensitive   = true
  description = "Hyper-V admin password"
}

# Local values
locals {
  vm_name_prefix = "aitheros-${var.environment}"
}

# VM creation - use module for reusability
module "aitheros_vm" {
  source = "../../modules/hyperv-vm"
  count  = var.vm_count
  
  name       = "${local.vm_name_prefix}-${count.index + 1}"
  memory_gb  = var.vm_memory_gb
  cpus       = var.vm_cpus
  vm_path    = var.vm_path
  iso_path   = var.iso_path
}

# Outputs
output "vm_names" {
  value       = [for vm in module.aitheros_vm : vm.name]
  description = "Created VM names"
}

output "vm_ips" {
  value       = [for vm in module.aitheros_vm : vm.ip_address]
  description = "VM IP addresses (when available)"
}
