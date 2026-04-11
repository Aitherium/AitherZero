# AitherOS Node — Variables
# All sizes in bytes for Hyper-V provider compatibility.

# ─── Identity ────────────────────────────────
variable "node_name" {
  type        = string
  description = "VM name (also used as hostname). Example: aither-node-01"
}

variable "iso_path" {
  type        = string
  description = "Path to the custom AitherOS Server 2025 Core ISO (built by 3105_Build-WindowsISO.ps1)"
}

variable "switch_name" {
  type        = string
  description = "Hyper-V virtual switch name to attach the VM to"
}

# ─── Compute ─────────────────────────────────
variable "cpu_count" {
  type        = number
  default     = 4
  description = "Number of virtual processors"
}

variable "cpu_reserve_percent" {
  type        = number
  default     = 0
  description = "CPU reserve percentage (0-100)"
}

variable "cpu_weight" {
  type        = number
  default     = 100
  description = "Relative CPU weight for scheduling (1-10000)"
}

variable "memory_startup_bytes" {
  type        = number
  default     = 4294967296  # 4 GB
  description = "Startup memory in bytes"
}

variable "memory_minimum_bytes" {
  type        = number
  default     = 2147483648  # 2 GB
  description = "Minimum dynamic memory in bytes"
}

variable "memory_maximum_bytes" {
  type        = number
  default     = 8589934592  # 8 GB
  description = "Maximum dynamic memory in bytes"
}

variable "dynamic_memory" {
  type        = bool
  default     = true
  description = "Enable dynamic memory allocation"
}

# ─── Storage ─────────────────────────────────
variable "vhd_path" {
  type        = string
  default     = "C:/VMs"
  description = "Directory for VHD files"
}

variable "disk_size_bytes" {
  type        = number
  default     = 107374182400  # 100 GB
  description = "System disk size in bytes"
}

variable "enable_data_disk" {
  type        = bool
  default     = false
  description = "Attach a separate data disk for Docker volumes and Strata data"
}

variable "data_disk_size_bytes" {
  type        = number
  default     = 214748364800  # 200 GB
  description = "Data disk size in bytes"
}

# ─── Networking ──────────────────────────────
variable "mac_address" {
  type        = string
  default     = ""
  description = "Static MAC address (empty = dynamic)"
}

# ─── Boot & Lifecycle ───────────────────────
variable "auto_start" {
  type        = bool
  default     = true
  description = "Start VM immediately after creation and on host boot"
}

variable "start_delay" {
  type        = number
  default     = 0
  description = "Delay in seconds before auto-starting the VM"
}

variable "secure_boot" {
  type        = bool
  default     = false
  description = "Enable Secure Boot (may need to be off for custom ISOs)"
}

variable "nested_virtualization" {
  type        = bool
  default     = false
  description = "Expose virtualization extensions (for running Hyper-V/Docker inside the VM)"
}

# ─── Paths ───────────────────────────────────
variable "smart_paging_path" {
  type        = string
  default     = "C:/ProgramData/Microsoft/Windows/Hyper-V"
  description = "Path for smart paging files"
}

variable "snapshot_path" {
  type        = string
  default     = "C:/ProgramData/Microsoft/Windows/Hyper-V"
  description = "Path for snapshot/checkpoint files"
}

# ─── AitherOS Metadata ──────────────────────
variable "node_profile" {
  type        = string
  default     = "Core"
  description = "AitherOS deployment profile (Full, Core, Minimal, GPU, Edge)"
  validation {
    condition     = contains(["Full", "Core", "Minimal", "GPU", "Edge"], var.node_profile)
    error_message = "node_profile must be one of: Full, Core, Minimal, GPU, Edge"
  }
}

variable "failover_priority" {
  type        = number
  default     = 10
  description = "Failover priority in mesh (lower = promoted first)"
}

variable "mesh_role" {
  type        = string
  default     = "standby"
  description = "Initial mesh role: primary, standby, edge"
}
