# AitherOS Node — Hyper-V VM Module
#
# Provisions a Windows Server 2025 Core VM pre-configured for AitherOS.
# Uses a custom ISO (built by 3105_Build-WindowsISO.ps1) with Autounattend.xml
# for zero-touch installation, then waits for WinRM and triggers post-install.
#
# Usage:
#   module "aitheros_node" {
#     source       = "../../modules/aitheros-node"
#     node_name    = "aither-node-01"
#     iso_path     = "C:/ISOs/AitherOS-Server2025-Core.iso"
#     switch_name  = "AitherSwitch"
#   }

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    hyperv = {
      source  = "taliesins/hyperv"
      version = ">= 1.2.1"
    }
  }
}

# ─────────────────────────────────────────────
# VHD — System disk for the node
# ─────────────────────────────────────────────
resource "hyperv_vhd" "system" {
  path = "${var.vhd_path}/${var.node_name}-system.vhdx"
  size = var.disk_size_bytes
}

# Optional: Data disk for Docker volumes / Strata
resource "hyperv_vhd" "data" {
  count = var.enable_data_disk ? 1 : 0
  path  = "${var.vhd_path}/${var.node_name}-data.vhdx"
  size  = var.data_disk_size_bytes
}

# ─────────────────────────────────────────────
# VM Instance
# ─────────────────────────────────────────────
resource "hyperv_machine_instance" "node" {
  name                                    = var.node_name
  generation                              = 2
  processor_count                         = var.cpu_count
  memory_startup_bytes                    = var.memory_startup_bytes
  memory_maximum_bytes                    = var.memory_maximum_bytes
  memory_minimum_bytes                    = var.memory_minimum_bytes
  dynamic_memory                          = var.dynamic_memory
  state                                   = var.auto_start ? "Running" : "Off"

  automatic_critical_error_action         = "Pause"
  automatic_critical_error_action_timeout = 30
  automatic_start_action                  = var.auto_start ? "StartIfRunning" : "Nothing"
  automatic_start_delay                   = var.start_delay
  automatic_stop_action                   = "Save"
  checkpoint_type                         = "Production"

  smart_paging_file_path  = var.smart_paging_path
  snapshot_file_location  = var.snapshot_path

  # ── Firmware: Boot from ISO first, then HDD ──
  vm_firmware {
    enable_secure_boot              = var.secure_boot ? "On" : "Off"
    preferred_network_boot_protocol = "IPv4"
    console_mode                    = "None"
    pause_after_boot_failure        = "Off"

    boot_order {
      boot_type           = "DvdDrive"
      controller_number   = 0
      controller_location = 1
    }
  }

  # ── Processor ──
  vm_processor {
    compatibility_for_migration_enabled               = false
    compatibility_for_older_operating_systems_enabled  = false
    hw_thread_count_per_core                           = 0
    maximum                                            = 100
    reserve                                            = var.cpu_reserve_percent
    relative_weight                                    = var.cpu_weight
    maximum_count_per_numa_node                        = 0
    maximum_count_per_numa_socket                      = 0
    enable_host_resource_protection                    = false
    expose_virtualization_extensions                   = var.nested_virtualization
  }

  # ── Integration Services ──
  integration_services = {
    "Guest Service Interface" = true   # Needed for file copy
    "Heartbeat"               = true
    "Key-Value Pair Exchange" = true   # For metadata exchange
    "Shutdown"                = true
    "Time Synchronization"    = true
    "VSS"                     = true
  }

  # ── Network ──
  network_adaptors {
    name                = var.switch_name
    switch_name         = var.switch_name
    management_os       = false
    is_legacy           = false
    dynamic_mac_address = var.mac_address == "" ? true : false
    static_mac_address  = var.mac_address
  }

  # ── DVD Drive: Custom ISO ──
  dvd_drives {
    controller_number   = 0
    controller_location = 1
    path                = var.iso_path
  }

  # ── System Disk ──
  hard_disk_drives {
    controller_type     = "Scsi"
    controller_number   = 0
    controller_location = 0
    path                = hyperv_vhd.system.path
  }

  # ── Data Disk (optional) ──
  dynamic "hard_disk_drives" {
    for_each = var.enable_data_disk ? [1] : []
    content {
      controller_type     = "Scsi"
      controller_number   = 0
      controller_location = 2
      path                = hyperv_vhd.data[0].path
    }
  }

  # Wait for VHD creation
  depends_on = [hyperv_vhd.system]
}
