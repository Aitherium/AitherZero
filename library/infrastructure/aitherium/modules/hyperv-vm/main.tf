# Hyper-V VM Module
# Reusable module for creating Hyper-V virtual machines

terraform {
  required_providers {
    hyperv = {
      source = "taliesins/hyperv"
    }
  }
}

variable "name" {
  type        = string
  description = "VM name"
}

variable "memory_gb" {
  type        = number
  default     = 4
  description = "Memory in GB"
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Number of CPUs"
}

variable "vm_path" {
  type        = string
  description = "Path for VM files"
}

variable "iso_path" {
  type        = string
  default     = ""
  description = "Boot ISO path"
}

variable "vhd_size_gb" {
  type        = number
  default     = 60
  description = "VHD size in GB"
}

variable "switch_name" {
  type        = string
  default     = "Default Switch"
  description = "Virtual switch name"
}

variable "generation" {
  type        = number
  default     = 2
  description = "VM generation (1 or 2)"
}

# Create VM
resource "hyperv_machine_instance" "vm" {
  name       = var.name
  generation = var.generation
  
  processor {
    count = var.cpus
  }
  
  memory {
    startup_mb                 = var.memory_gb * 1024
    dynamic_memory_enabled     = true
    dynamic_memory_minimum_mb  = 512
    dynamic_memory_maximum_mb  = var.memory_gb * 1024 * 2
  }
  
  network_adapter {
    switch_name = var.switch_name
  }
  
  hard_disk_drive {
    controller_type     = "Scsi"
    controller_location = 0
    path                = "${var.vm_path}/${var.name}/${var.name}.vhdx"
    size                = var.vhd_size_gb * 1024 * 1024 * 1024
  }
  
  dynamic "dvd_drive" {
    for_each = var.iso_path != "" ? [1] : []
    content {
      controller_location = 1
      path                = var.iso_path
    }
  }
  
  state = "Running"
}

# Outputs
output "name" {
  value = hyperv_machine_instance.vm.name
}

output "id" {
  value = hyperv_machine_instance.vm.id
}

output "ip_address" {
  value       = try(hyperv_machine_instance.vm.network_adapter[0].ip_addresses[0], "pending")
  description = "Primary IP address"
}
