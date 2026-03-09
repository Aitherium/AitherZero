# AitherOS Local Hyper-V — Variables

# ─── Hyper-V Provider ───────────────────────
variable "hyperv_host" {
  type        = string
  default     = "localhost"
  description = "Hyper-V host to connect to"
}

variable "hyperv_user" {
  type        = string
  default     = ""
  description = "WinRM username (empty for current user with localhost)"
}

variable "hyperv_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "WinRM password"
}

variable "hyperv_port" {
  type        = number
  default     = 5985
  description = "WinRM port (5985=HTTP, 5986=HTTPS)"
}

variable "hyperv_https" {
  type        = bool
  default     = false
  description = "Use HTTPS for WinRM (set true + port 5986 for production)"
}

variable "hyperv_insecure" {
  type        = bool
  default     = true
  description = "Skip TLS verification (true for self-signed certs)"
}

# ─── Network ────────────────────────────────
variable "switch_name" {
  type        = string
  default     = "AitherSwitch"
  description = "Name of the Hyper-V virtual switch"
}

variable "switch_type" {
  type        = string
  default     = "Internal"
  description = "Switch type: Internal (host-only), External (bridged to NIC), Private"
  validation {
    condition     = contains(["Internal", "External", "Private"], var.switch_type)
    error_message = "switch_type must be Internal, External, or Private"
  }
}

variable "physical_adapter" {
  type        = string
  default     = "Ethernet"
  description = "Physical NIC name for External switch (Get-NetAdapter to list)"
}

# ─── ISO ────────────────────────────────────
variable "iso_path" {
  type        = string
  description = "Path to the custom AitherOS ISO (built by 3105_Build-WindowsISO.ps1)"
}

# ─── Storage Defaults ───────────────────────
variable "vhd_path" {
  type        = string
  default     = "C:/VMs"
  description = "Base directory for VHD storage"
}

variable "default_disk_gb" {
  type        = number
  default     = 100
  description = "Default system disk size in GB"
}

# ─── Compute Defaults ───────────────────────
variable "default_cpu_count" {
  type        = number
  default     = 4
  description = "Default vCPU count per node"
}

variable "default_memory_gb" {
  type        = number
  default     = 4
  description = "Default startup memory in GB"
}

variable "default_memory_min_gb" {
  type        = number
  default     = 2
  description = "Default minimum dynamic memory in GB"
}

variable "default_memory_max_gb" {
  type        = number
  default     = 8
  description = "Default maximum dynamic memory in GB"
}

# ─── Node Definitions ──────────────────────
variable "nodes" {
  type = list(object({
    name               = string
    profile            = optional(string, "Core")
    cpu_count          = optional(number)
    memory_gb          = optional(number)
    memory_min_gb      = optional(number)
    memory_max_gb      = optional(number)
    disk_gb            = optional(number)
    data_disk          = optional(bool, false)
    data_disk_gb       = optional(number, 200)
    failover_priority  = optional(number, 10)
    mesh_role          = optional(string, "standby")
    nested_virt        = optional(bool, false)
    dynamic_memory     = optional(bool, true)
    auto_start         = optional(bool, true)
  }))
  description = "List of AitherOS nodes to provision"

  default = [
    {
      name              = "aither-node-01"
      profile           = "Core"
      failover_priority = 5
      mesh_role         = "standby"
    }
  ]
}
